import SwiftUI
import InfluxKit

/// The shell. The timeline is a UICollectionView on iOS and an
/// NSCollectionView on macOS, hosted here.
struct RootView: View {
    let app: AppModel
    /// Opens the library again, after it failed to open.
    var retry: () -> Void = {}
    @State private var showsSources = false
    @State private var showsViews = false
    @State private var jumps: TimelineJumps
    @State private var find: TimelineFind
    @State private var items = TimelineItems()
    @FocusState private var findFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    /// When the app last went to the background, for how long it was away.
    @State private var wentAwayAt: ContinuousClock.Instant?
    #if os(macOS)
    @Environment(\.controlActiveState) private var activeState
    #endif

    init(app: AppModel, retry: @escaping () -> Void = {}) {
        self.app = app
        self.retry = retry
        let jumps = TimelineJumps()
        _jumps = State(initialValue: jumps)
        _find = State(initialValue: TimelineFind(jumps: jumps))
    }

    var body: some View {
        if let error = app.storeError {
            StoreErrorView(error: error, retry: retry)
        } else {
            // The sign-in alert pushes the timeline down rather than
            // covering its first row.
            VStack(spacing: 0) {
                SignInAlert(accounts: app.accounts, states: app.feeds.states)
                timeline
            }
            // Under the "Syncing in Progress" screen the timeline can't be
            // reached by VoiceOver either, which could scroll it.
            .accessibilityHidden(app.syncingGate?.isShowing == true)
            .onChange(of: SignInWatch(accounts: app.accounts.accounts, states: app.feeds.states), initial: true) { _, watch in
                SignInNotices.update(accounts: watch.accounts, states: watch.states)
            }
            // Until the place from other devices is in, the timeline can't
            // be scrolled from a stale one.
            .overlay {
                if let gate = app.syncingGate {
                    SyncingOverlay(gate: gate)
                }
            }
        }
    }

    private var timeline: some View {
        // Leaving a view saves its place; the next one opens at its own.
        TimelineScreen(app: app, viewID: app.views.selectedID, jumps: jumps, items: items)
            .id(app.views.selectedID)
            .ignoresSafeArea()
            .focusedSceneValue(\.timelineJumps, jumps)
            .focusedSceneValue(\.timelineItems, items)
            .focusedSceneValue(\.timelineFind, find)
            // Typing in Find stands a list of matches in for the timeline,
            // which stays underneath, where it was.
            .overlay {
                if find.showsResults {
                    FindResults(find: find)
                        #if os(iOS)
                        .safeAreaPadding(.top, 56)
                        #endif
                }
            }
            .overlay(alignment: .top) {
                ReturnFromResultButton(jumps: jumps)
                    #if os(iOS)
                    .padding(.top, 52)
                    #else
                    .padding(.top, 8)
                    #endif
            }
            .animation(.default, value: jumps.offersReturn)
            #if os(iOS)
            .overlay(alignment: .top) {
                if find.isPresented {
                    findBar
                }
            }
            .overlay(alignment: .topTrailing) {
                if !find.isPresented {
                    buttons
                }
            }
            .overlay(alignment: .topLeading) {
                // Clear of the buttons on the right, on the narrowest phone.
                if !find.isPresented {
                    FailingFeedsNotice(feeds: app.feeds) { showsSources = true }
                        .frame(maxWidth: 160, alignment: .leading)
                        .padding(.leading, 16)
                }
            }
            #else
            .searchable(text: $find.query, isPresented: $find.isPresented, placement: .toolbar, prompt: "Find in Timeline")
            .searchFocused($findFocused)
            .navigationTitle(app.views.selectedName)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ViewMenu(views: app.views) { showsViews = true }
                }
                if let sync = app.sync {
                    ToolbarItem {
                        SyncButton(sync: sync)
                    }
                }
                ToolbarItem {
                    Button("Sources", systemImage: "list.bullet") { showsSources = true }
                        .accessibilityIdentifier("sources-button")
                }
            }
            .overlay(alignment: .top) {
                FailingFeedsNotice(feeds: app.feeds) { showsSources = true }
                    .padding(.top, 8)
            }
            #endif
            // A link back to an item, from Sammy: also the one that
            // launched the app. Everything else on the scheme is ignored.
            .onOpenURL { url in
                // The link is what the reader asked for now: a Sources or
                // Views sheet would hide the item or notice it leads to.
                if ItemLink(url, scheme: ItemLinkRoute.scheme) != nil {
                    showsSources = false
                    showsViews = false
                }
                Task { await ItemLinkRoute.open(url, store: app.store, views: app.views, items: items) }
            }
            .onChange(of: find.focusRequest) { findFocused = true }
            .onChange(of: jumps.rowsChanged) { find.rowsChanged() }
            .sheet(isPresented: $showsSources) {
                SourcesScreen(feeds: app.feeds, accounts: app.accounts, requests: app.sourcesRequests, inbox: app.sammyInbox)
            }
            .sheet(isPresented: $showsViews) {
                ViewsScreen(views: app.views, feeds: app.feeds)
            }
            // Initial too, for a window the File menu opened to take a request.
            .onChange(of: app.sourcesRequests.pending, initial: true) { showSourcesIfAsked() }
            #if os(macOS)
            // Only the key window takes a request, so it may arrive just after.
            .onChange(of: activeState) { showSourcesIfAsked() }
            #endif
            .onAppear {
                app.sourcesRequests.openWindows += 1
                #if os(macOS)
                app.syncReturns?.windowOpened()
                #endif
            }
            .onDisappear { app.sourcesRequests.openWindows -= 1 }
            .task {
                app.views.start()
                app.feeds.start()
                app.accounts.start()
                app.sammyInbox.start()
                // Sources synced from another device are fetched right away.
                app.sync?.onSourcesChanged = { [app] in
                    Task { await app.feeds.refresh() }
                    Task { await app.accounts.refresh() }
                }
                #if os(macOS)
                app.syncReturns?.start()
                app.screenPresence.start()
                #endif
                // After the first screen, so MetricKit and StoreKit don't
                // load during launch.
                app.startFieldPerformance()
                // After the first screen, so CloudKit's frameworks don't
                // load during launch.
                await app.sync?.start()
            }
            // Bookmarks made on another device or in another app show up
            // when the view opens, not at the next pass. A search was of
            // the view left behind, so it closes.
            .onChange(of: app.views.selectedID) { _, viewID in
                find.cancel()
                if viewID == SavedView.bookmarksID {
                    Task { await app.accounts.refresh() }
                }
            }
            #if os(iOS)
            .onChange(of: scenePhase, initial: true) { _, phase in
                app.setOnScreen(phase == .active)
            }
            #endif
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    wentAwayAt = .now
                    #if os(iOS)
                    // The Mac's leavings are watched by SyncReturns.
                    app.putAwayInBackground()
                    #endif
                }
                if phase == .active {
                    // Coming on screen fetches what is older than its
                    // on-screen interval (`AppModel.setOnScreen`), not
                    // every source again.
                    app.sammyInbox.send()
                    #if os(iOS)
                    // The phone stops syncing while away, so a long absence
                    // waits for the place again before it can be scrolled.
                    let away = wentAwayAt.map { ContinuousClock.now - $0 } ?? .zero
                    wentAwayAt = nil
                    app.sync?.cameBack(after: away)
                    #endif
                    // The Mac's returns (switching back, waking, reopening
                    // the window) are watched by SyncReturns, from AppKit:
                    // a scene phase doesn't change for most of them.
                }
            }
    }

    #if os(iOS)
    /// The sync, view, find and sources buttons at the top right.
    private var buttons: some View {
        HStack(spacing: 8) {
            if let sync = app.sync {
                SyncButton(sync: sync)
                    .buttonStyle(.glass)
            }
            ViewMenu(views: app.views) { showsViews = true }
                .buttonStyle(.glass)
            Button("Find in Timeline", systemImage: "magnifyingglass") { find.begin() }
                .accessibilityIdentifier("find-button")
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
            Button("Sources", systemImage: "list.bullet") { showsSources = true }
                .accessibilityIdentifier("sources-button")
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
        }
        .padding(.trailing, 16)
    }

    /// The search field that comes down over the top of the timeline.
    private var findBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in Timeline", text: $find.query)
                    .focused($findFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("find-field")
                    .onAppear { findFocused = true }
                    .onKeyPress(.escape) {
                        find.cancel()
                        return .handled
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassEffect(in: .capsule)
            Button("Cancel") { find.cancel() }
                .accessibilityIdentifier("find-cancel")
        }
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
    #endif
}

extension RootView {
    /// Opens Sources for a File menu request, in the key window only.
    private func showSourcesIfAsked() {
        guard app.sourcesRequests.pending != nil else { return }
        #if os(macOS)
        guard activeState == .key else { return }
        #endif
        showsSources = true
    }
}

/// Shown instead of the timeline when the library file can't be opened.
private struct StoreErrorView: View {
    let error: any Error
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Influx can't open its library", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Nothing can be saved until it opens. If this keeps happening, check that your disk has free space.\n\n\(error.localizedDescription)")
        } actions: {
            Button("Try Again", action: retry)
                .accessibilityIdentifier("store-retry")
        }
        .accessibilityIdentifier("store-error")
    }
}

/// What the sign-in notices follow: the accounts, and whether each needs
/// signing in again, not every fetch's state change.
private struct SignInWatch: Equatable {
    let accounts: [Accounts.Account]
    let states: [String: SourceFetchState]

    static func == (a: Self, b: Self) -> Bool {
        a.accounts == b.accounts && a.needing == b.needing && a.states.isEmpty == b.states.isEmpty
    }

    private var needing: [String] { accounts.filter { $0.needsSignIn(states) }.map(\.id) }
}
