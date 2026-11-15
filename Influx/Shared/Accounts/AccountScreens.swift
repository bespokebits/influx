import SwiftUI
import InfluxKit

/// An account in the Sources list: its handle, and a quiet line when it
/// needs signing in again.
struct AccountRow: View {
    let account: Accounts.Account
    let states: [String: SourceFetchState]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.name)
                .font(.system(.body, design: .serif))
            if needsSignIn {
                Text(SourceProblem.signedOut.message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SignInAlert.red)
            } else {
                Text(account.sources.count == 1 ? "\(account.service.name) · 1 source" : "\(account.service.name) · \(account.sources.count) sources")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var needsSignIn: Bool { account.needsSignIn(states) }
}

extension Accounts.Account.Service {
    var name: String {
        switch self {
        case .mastodon: "Mastodon"
        case .bluesky: "Bluesky"
        case .sammy: "Sammy"
        }
    }

    /// Whether the account offers feeds or lists to add as sources:
    /// Bluesky saved feeds and Sammy feeds. Mastodon lists aren't offered
    /// in v1.
    var offersFeeds: Bool {
        switch self {
        case .bluesky, .sammy: true
        case .mastodon: false
        }
    }
}

/// One account: its home timeline (Following, on Bluesky), the feeds a
/// Bluesky or Sammy account offers (each one a source to add or remove),
/// and signing out. Mastodon lists aren't offered in v1, so a Mastodon
/// account is just its home timeline; a Sammy account has no home, only
/// its feeds.
struct AccountScreen: View {
    let account: Accounts.Account
    let accounts: Accounts
    let states: [String: SourceFetchState]
    /// Bookmarks to Sammy Inbox, shown on a Sammy account's screen.
    var inbox: SammyInbox? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var lists: [(source: Source, isAdded: Bool)] = []
    @State private var listsError: String?
    @State private var confirmsSignOut = false
    @State private var confirmsDisconnect = false

    var body: some View {
        List {
            if account.needsSignIn(states) {
                Section {
                    HStack {
                        Text(SourceProblem.signedOut.message)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SignInAlert.red)
                        Spacer()
                        if accounts.signingInAgain.contains(account.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            SignInAgainButton(account: account, accounts: accounts)
                        }
                    }
                    if let error = accounts.signInAgainErrors[account.id] {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Signing in again keeps this account's sources, bookmarks and your place.")
                }
            }
            if account.service != .sammy {
                Section {
                    ForEach(account.sources.filter { $0.kind == .mastodonHome || $0.kind == .blueskyFollowing }) { source in
                        SourceRow(source: source, state: states[source.id])
                    }
                }
            }
            if offersFeeds {
                Section {
                    ForEach(lists, id: \.source.id) { list in
                        Toggle(isOn: Binding(
                            get: { list.isAdded },
                            set: { added in setList(list.source, added: added) }
                        )) {
                            SourceRow(source: list.source, state: states[list.source.id])
                        }
                    }
                    if let listsError {
                        Text(listsError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if lists.isEmpty {
                        Text(account.service == .sammy ? "This account has no feeds." : "This account has no saved feeds.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Feeds")
                } footer: {
                    if account.service == .sammy {
                        Text("Feeds on your Sammy account. Feeds added there later show here switched off.")
                    } else {
                        Text("Feeds you've saved in Bluesky. An added feed shows in the timeline as its own source.")
                    }
                }
            }
            if account.service == .sammy, let inbox {
                SammyInboxSection(account: account, inbox: inbox, needsSignIn: account.needsSignIn(states))
            }
            Section {
                Button("Sign Out", role: .destructive) { confirmsSignOut = true }
                    .accessibilityIdentifier("sign-out")
            } footer: {
                Text("Signing out removes this account's posts from Influx on this device.")
            }
        }
        .navigationTitle(account.name)
        .task { await loadLists() }
        // A list that failed while signed out loads again once signed in.
        .onChange(of: account.needsSignIn(states) || accounts.signingInAgain.contains(account.id)) { _, waiting in
            if !waiting { Task { await loadLists() } }
        }
        // Switching off a Sammy account's last feed would leave a connection
        // with nothing to show, so it offers to end the connection instead.
        .confirmationDialog("Disconnect Sammy?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                Task {
                    await accounts.signOut(account)
                    dismiss()
                }
            }
            .accessibilityIdentifier("sammy-disconnect")
        } message: {
            Text("That's the last feed from \(account.name). Disconnecting ends Influx's connection to your Sammy account and removes its posts from Influx.")
        }
        .confirmationDialog("Sign out of \(account.name)?", isPresented: $confirmsSignOut) {
            Button("Sign Out", role: .destructive) {
                Task {
                    await accounts.signOut(account)
                    dismiss()
                }
            }
        }
    }

    /// Bluesky saved feeds and Sammy feeds are sources to add or remove.
    private var offersFeeds: Bool { account.service.offersFeeds }

    private func loadLists() async {
        guard offersFeeds else { return }
        // A Sammy account has no home row, so until the server answers, or
        // if it can't, the screen shows the feeds already added.
        if account.service == .sammy, lists.isEmpty {
            lists = account.sources.map { (source: $0, isAdded: true) }
        }
        do {
            let loaded = try await accounts.lists(for: account)
            // The reader may have switched a feed on or off while the list
            // loaded, so the rows already shown say which are on.
            lists = Self.feedRows(
                listed: loaded.map(\.source), added: account.sources, shown: lists,
                keepsUnlisted: account.service == .sammy
            )
            listsError = nil
        } catch ConnectorError.unauthorized {
            // The sign-in has ended, so nothing of this account updates.
            listsError = "\(SourceProblem.signedOut.message). Sign in again above to choose its feeds."
        } catch {
            listsError = account.service == .sammy
                ? "Couldn't load this account's feeds. The feeds already added still update."
                : "Couldn't load this account's feeds."
        }
    }

    /// The feed rows once the server has listed the account's feeds, in its
    /// order and each once: a feed is on as the row already `shown` for it
    /// says, else if it is `added`, so a feed the account gains later shows
    /// switched off. With `keepsUnlisted`, feeds still in the timeline that
    /// the server no longer lists follow, so the reader can still take
    /// them out.
    static func feedRows(listed: [Source], added: [Source], shown: [(source: Source, isAdded: Bool)], keepsUnlisted: Bool) -> [(source: Source, isAdded: Bool)] {
        var shownAdded: [String: Bool] = [:]
        for row in shown { shownAdded[row.source.id] = row.isAdded }
        let addedIDs = Set(added.map(\.id))
        var seen: Set<String> = []
        var rows: [(source: Source, isAdded: Bool)] = []
        for source in listed where seen.insert(source.id).inserted {
            rows.append((source, shownAdded[source.id] ?? addedIDs.contains(source.id)))
        }
        if keepsUnlisted {
            for source in added where source.kind == .sammyFeed && seen.insert(source.id).inserted {
                rows.append((source, shownAdded[source.id] ?? true))
            }
        }
        return rows
    }

    private func setList(_ list: Source, added: Bool) {
        if !added, account.service == .sammy,
           Accounts.offersDisconnect(removing: list, added: lists.filter(\.isAdded).map(\.source)) {
            // The toggle stays on unless the reader disconnects.
            confirmsDisconnect = true
            return
        }
        if let index = lists.firstIndex(where: { $0.source.id == list.id }) {
            lists[index].isAdded = added
        }
        Task { await accounts.setList(list, added: added) }
    }
}

/// Asks which Mastodon server to sign in to, then hands over to the browser.
struct AddMastodonSheet: View {
    let accounts: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var instance = ""
    @State private var error: String?
    @State private var isWorking = false
    @State private var step: Accounts.SignInStep?
    @State private var signingIn: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Server, e.g. mastodon.social", text: $instance)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("mastodon-instance")
                    .onSubmit(signIn)
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("mastodon-error")
                } else if isWorking, let step {
                    Text(step.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("mastodon-step")
                }
            }
            .navigationTitle("Add Mastodon Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        signingIn?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Sign In", action: signIn)
                            .accessibilityIdentifier("mastodon-sign-in")
                            .disabled(instance.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 160)
        #endif
        // Closing the sheet any other way also stops the sign-in.
        .onDisappear { signingIn?.cancel() }
    }

    private func signIn() {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        signingIn = Task {
            defer { isWorking = false; step = nil }
            do {
                try await accounts.signInToMastodon(instance: instance) { step = $0 }
                dismiss()
            } catch is WebSignIn.Cancelled, is CancellationError {
                // The reader closed the browser or the sheet.
            } catch {
                self.error = signInMessage(for: error)
            }
        }
    }
}

extension Accounts.SignInStep {
    /// What a sign-in sheet says while signing in, so a slow server and a
    /// browser window that didn't come forward look different.
    var message: String {
        switch self {
        case .contactingServer: "Contacting the server…"
        case .inBrowser: "Finish signing in in the browser window. If none opened, cancel and try again."
        case .finishing: "Finishing sign-in…"
        }
    }
}

/// Asks for the Bluesky handle to sign in with, then hands over to the
/// browser. Another account can be added the same way.
struct AddBlueskySheet: View {
    let accounts: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var handle = ""
    @State private var error: String?
    @State private var isWorking = false
    @State private var signingIn: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Handle, e.g. name.bsky.social", text: $handle)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textContentType(.username)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("bluesky-handle")
                    .onSubmit(signIn)
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("bluesky-error")
                }
            }
            .navigationTitle("Add Bluesky Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        signingIn?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Sign In", action: signIn)
                            .accessibilityIdentifier("bluesky-sign-in")
                            .disabled(handle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 160)
        #endif
        .onDisappear { signingIn?.cancel() }
    }

    private func signIn() {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        signingIn = Task {
            defer { isWorking = false }
            do {
                try await accounts.signInToBluesky(handle: handle)
                dismiss()
            } catch is WebSignIn.Cancelled, is CancellationError {
                // The reader closed the browser or the sheet.
            } catch {
                self.error = signInMessage(for: error)
            }
        }
    }
}

/// Connect Sammy: the server address (the public service's, which the
/// reader can change), approval in the Sammy app, then the account's feeds
/// to tick, all in one sheet. Only wiring: `SammyConnectFlow` decides what
/// is saved and revokes whatever isn't.
struct AddSammySheet: View {
    let accounts: Accounts
    /// Given the account's ID once it is saved.
    var connected: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var flow: SammyConnectFlow?
    @State private var server = SammyConnectFlow.defaultServer
    @State private var error: String?
    @State private var isWorking = false
    @State private var step: Accounts.SignInStep?
    @State private var offer: SammyConnectFlow.Offer?
    @State private var ticked: Set<String> = []
    @State private var isSaved = false
    @State private var signingIn: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if let offer, offer.isEmpty {
                    empty
                } else if let offer {
                    picker(offer)
                } else {
                    address
                }
            }
            .navigationTitle(offer.map { $0.isEmpty ? "Connect Sammy" : "Choose Feeds" } ?? "Connect Sammy")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: close)
                        .accessibilityIdentifier("sammy-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else if let offer, !offer.isEmpty {
                        Button("Save", action: save)
                            .accessibilityIdentifier("sammy-save")
                            .disabled(ticked.isEmpty)
                    } else if offer == nil {
                        Button("Sign In", action: signIn)
                            .accessibilityIdentifier("sammy-sign-in")
                            .disabled(server.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 260)
        #endif
        // Closing the sheet any other way ends the connection too.
        .onDisappear {
            signingIn?.cancel()
            if !isSaved, let flow { Task { await flow.cancel() } }
        }
    }

    private var address: some View {
        Form {
            Section {
                TextField("Server, e.g. \(SammyConnectFlow.defaultServer)", text: $server)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("sammy-server")
                    .onSubmit(signIn)
                    .disabled(isWorking)
            } header: {
                Text("Sammy server address")
            } footer: {
                if let error {
                    Text(error)
                        .accessibilityIdentifier("sammy-error")
                } else if isWorking, let step {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(Self.message(for: step))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("sammy-step")
                } else {
                    Text("Your Sammy server. Leave it as it is unless you run your own.")
                }
            }
        }
    }

    private func picker(_ offer: SammyConnectFlow.Offer) -> some View {
        Form {
            Section {
                ForEach(offer.feeds) { feed in
                    Toggle(isOn: Binding(
                        get: { ticked.contains(feed.id) },
                        set: { on in if on { ticked.insert(feed.id) } else { ticked.remove(feed.id) } }
                    )) {
                        Text(feed.title)
                    }
                    .accessibilityIdentifier("sammy-feed")
                }
            } header: {
                Text("Feeds on \(Self.server(of: offer.accountID))")
            } footer: {
                if let error {
                    Text(error)
                        .accessibilityIdentifier("sammy-error")
                } else {
                    Text("Each feed you tick becomes its own source in your timeline. You can change this later in Sources.")
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No Sammy feeds yet")
                .font(.headline)
            Text("Turn on Release watch in Sammy, then connect again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("sammy-empty")
            Button(action: closeEmpty) {
                Text("Close").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("sammy-close")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// What the sheet says while signing in: approving happens in the
    /// Sammy app, with the code the server's page shows.
    static func message(for step: Accounts.SignInStep) -> String {
        step == .inBrowser ? "Approve in the Sammy app with the code shown." : step.message
    }

    /// The server's host, from an account ID (`<subject>@<host>`).
    static func server(of accountID: String) -> String {
        String(accountID.split(separator: "@").last ?? Substring(accountID))
    }

    private func signIn() {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        let flow = flow ?? accounts.makeSammyFlow()
        self.flow = flow
        signingIn = Task {
            defer { isWorking = false; step = nil }
            do {
                let offer = try await accounts.signInToSammy(flow, server: server) { step = $0 }
                guard !Task.isCancelled else { return }
                ticked = offer.ticked
                self.offer = offer
            } catch is WebSignIn.Cancelled, is CancellationError {
                // The reader closed the browser or the sheet.
            } catch {
                self.error = signInMessage(for: error)
            }
        }
    }

    private func save() {
        guard let flow, !isWorking, !ticked.isEmpty else { return }
        isWorking = true
        error = nil
        let selected = ticked
        Task {
            defer { isWorking = false }
            do {
                let accountID = try await accounts.saveSammy(flow, selected: selected)
                isSaved = true
                connected(accountID)
                dismiss()
            } catch {
                self.error = signInMessage(for: error)
                // A save that failed has ended the connection; start again.
                offer = nil
            }
        }
    }

    private func close() {
        signingIn?.cancel()
        if let flow { Task { await flow.cancel() } }
        dismiss()
    }

    private func closeEmpty() {
        if let flow { Task { await flow.closeEmpty() } }
        dismiss()
    }
}
