import SwiftUI
import UniformTypeIdentifiers
import InfluxKit

/// The reader's sources: add a feed by address, import an OPML file, and
/// see which sources are having trouble. Problems show as a quiet line
/// under the source, never an alert.
struct SourcesScreen: View {
    /// What the File menu can ask the screen to start.
    enum Action: Equatable {
        case addFeed
        case importOPML
    }

    let feeds: Feeds
    let accounts: Accounts
    let requests: SourcesRequests
    /// Bookmarks to Sammy Inbox, for each Sammy account's screen.
    var inbox: SammyInbox? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var isAdding = false
    @State private var isAddingMastodon = false
    @State private var isAddingBluesky = false
    @State private var isAddingSammy = false
    @State private var isImporting = false
    @State private var importMessage: String?
    #if os(macOS)
    @Environment(\.controlActiveState) private var activeState
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    header
                    Section {
                        SectionLabel(title: "Accounts")
                            .modifier(LabelRow(rule: rule))
                        ForEach(accounts.accounts) { account in
                            NavigationLink {
                                AccountScreen(account: account, accounts: accounts, states: feeds.states, inbox: inbox)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 14) {
                                    SourceDot(color: account.service.dotColor)
                                    AccountRow(account: account, states: feeds.states)
                                }
                            }
                            .listRowSeparatorTint(rule)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        }
                        addAccounts
                    }
                    .listSectionSeparator(.hidden)
                    .listRowBackground(paper)
                    Section {
                        feedsHeader
                            .modifier(LabelRow(rule: rule))
                        #if os(iOS)
                        AddRow(title: "Add Feed…") { isAdding = true }
                            .accessibilityIdentifier("add-feed")
                            .listRowSeparatorTint(rule)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        #endif
                        if rssSources.isEmpty {
                            Text("Add a feed by its address, or import an OPML file from another reader.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .listRowSeparator(.hidden)
                        }
                        ForEach(rssSources) { source in
                            SourceRow(source: source, state: feeds.states[source.id], isFailingLong: failing.contains(source.id))
                                .listRowSeparatorTint(rule)
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                                // The Mac has no swipe to delete.
                                .contextMenu {
                                    Button("Remove Feed", systemImage: "trash", role: .destructive) {
                                        Task { await feeds.delete(source) }
                                    }
                                }
                        }
                        .onDelete { offsets in
                            let doomed = offsets.map { rssSources[$0] }
                            Task {
                                for source in doomed { await feeds.delete(source) }
                            }
                        }
                        if let importMessage {
                            Text(importMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .listRowSeparator(.hidden)
                        }
                        // Which build this is, so the reader can tell an update arrived.
                        Text("Influx \(BuildInfo.versionLine)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 18)
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier("version-line")
                    }
                    .listSectionSeparator(.hidden)
                    .listRowBackground(paper)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                #if os(macOS)
                // The sheet's own toolbar bar draws white whatever is behind
                // it, so the Mac's Done lives in a paper footer instead.
                Rectangle()
                    .fill(rule)
                    .frame(height: 1)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(InkButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                #endif
            }
            .background(paper)
            .tint(Color.paint(Broadsheet.ink))
            // Kept for the back button; the serif heading in the list
            // stands in for it on screen.
            .navigationTitle("Sources")
            .toolbar(removing: .title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.paint(Broadsheet.paper), for: .navigationBar)
            #endif
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
            .onChange(of: requests.pending, initial: true) { takeRequest() }
            #if os(macOS)
            // Only the key window takes a request, so it may arrive just after.
            .onChange(of: activeState) { takeRequest() }
            #endif
            .sheet(isPresented: $isAdding) {
                AddFeedSheet(feeds: feeds)
            }
            .sheet(isPresented: $isAddingMastodon) {
                AddMastodonSheet(accounts: accounts)
            }
            .sheet(isPresented: $isAddingBluesky) {
                AddBlueskySheet(accounts: accounts)
            }
            .sheet(isPresented: $isAddingSammy) {
                // Its feeds are chosen in the sheet, so nothing opens after.
                AddSammySheet(accounts: accounts)
            }
            .task { await accounts.load() }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.opmlTypes) { result in
                guard case .success(let url) = result else { return }
                Task {
                    do {
                        let count = try await feeds.importOPML(at: url)
                        importMessage = count == 1 ? "Imported 1 feed." : "Imported \(count) feeds."
                    } catch {
                        importMessage = "That file isn't an OPML subscription list."
                    }
                }
            }
        }
        // Paper under the sheet's own bars too, so the Mac's Done bar
        // isn't a white strip below the list.
        .presentationBackground(Color.paint(Broadsheet.paper))
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 560, idealHeight: 720)
        #endif
    }

    /// The serif heading and what syncs, in place of a navigation title.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources")
                .font(.system(size: titleSize, weight: .medium, design: .serif))
                .accessibilityAddTraits(.isHeader)
            Text("Accounts sign in on each device. Feeds and your reading place sync through iCloud.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .listRowSeparator(.hidden)
        .listRowBackground(paper)
    }

    /// Adding an account: a pill per service on the Mac, one menu on a
    /// phone, where three pills would wrap.
    @ViewBuilder private var addAccounts: some View {
        #if os(macOS)
        HStack(spacing: 8) {
            Text("Add an account")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
            addAccountButton(.mastodon) { isAddingMastodon = true }
                .accessibilityIdentifier("add-mastodon")
            addAccountButton(.bluesky) { isAddingBluesky = true }
                .accessibilityIdentifier("add-bluesky")
            Button { isAddingSammy = true } label: {
                HStack(spacing: 7) {
                    SourceDot(color: Accounts.Account.Service.sammy.dotColor, size: 7)
                    Text("Connect Sammy")
                }
            }
            .buttonStyle(PillButtonStyle())
            .accessibilityIdentifier("add-sammy")
        }
        .padding(.vertical, 6)
        .listRowSeparator(.hidden)
        #else
        Menu {
            Button("Mastodon") { isAddingMastodon = true }
                .accessibilityIdentifier("add-mastodon")
            Button("Bluesky") { isAddingBluesky = true }
                .accessibilityIdentifier("add-bluesky")
            Button("Connect Sammy") { isAddingSammy = true }
                .accessibilityIdentifier("add-sammy")
        } label: {
            AddRowLabel(title: "Add Account…", detail: "Mastodon, Bluesky, Sammy")
        }
        .accessibilityIdentifier("add-account")
        .listRowSeparatorTint(rule)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        #endif
    }

    #if os(macOS)
    private func addAccountButton(_ service: Accounts.Account.Service, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                SourceDot(color: service.dotColor, size: 7)
                Text(service.name)
            }
        }
        .buttonStyle(PillButtonStyle())
        .accessibilityLabel("Add \(service.name) Account")
    }
    #endif

    /// "Feeds" and its count, with adding and importing beside it.
    private var feedsHeader: some View {
        HStack(alignment: .center) {
            SectionLabel(title: "Feeds", count: rssSources.count)
            Spacer()
            #if os(macOS)
            Button("Import OPML…") { isImporting = true }
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("import-opml")
            Button { isAdding = true } label: {
                Label("Add Feed…", systemImage: "plus")
            }
            .buttonStyle(PillButtonStyle(filled: true))
            .accessibilityIdentifier("add-feed")
            #else
            Button("Import OPML") { isImporting = true }
                // Only the words take the tap, not the whole row.
                .buttonStyle(.borderless)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("import-opml")
            #endif
        }
    }

    // Sized for the design, and scaled with the reader's text size.
    #if os(iOS)
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 36
    #else
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 30
    #endif

    private var rule: Color { .paint(Broadsheet.rule) }
    private var paper: Color { .paint(Broadsheet.paper) }

    /// Starts what the File menu asked for, in the key window only, so
    /// other windows leave it alone.
    private func takeRequest() {
        #if os(macOS)
        guard activeState == .key else { return }
        #endif
        switch requests.pending {
        case .addFeed?: isAdding = true
        case .importOPML?: isImporting = true
        case nil: return
        }
        requests.pending = nil
    }

    /// Account sources are listed under their account instead.
    private var rssSources: [Source] { feeds.sources.filter { $0.kind == .rss } }
    private var failing: Set<String> { Set(feeds.failing.map(\.id)) }

    /// Declared in Info.plist (UTImportedTypeDeclarations), so the picker
    /// knows .opml files as XML with a proper icon.
    private static let opmlTypes: [UTType] = [UTType(importedAs: "org.opml.opml", conformingTo: .xml), .xml]
}

/// Asks for the Sources screen to open and start an action, from the File
/// menu.
@MainActor @Observable
final class SourcesRequests {
    var pending: SourcesScreen.Action?
    /// Windows showing the timeline, which act on `pending`. On the Mac
    /// the menu stays after the last one closes.
    var openWindows = 0
}

/// File > Add Feed… and Import OPML…, which open Sources, and a window
/// for it when none is open.
struct SourcesCommands: Commands {
    let requests: SourcesRequests
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Feed…") { request(.addFeed) }
                .keyboardShortcut("n")
            Button("Import OPML…") { request(.importOPML) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }

    private func request(_ action: SourcesScreen.Action) {
        requests.pending = action
        if requests.openWindows == 0 {
            openWindow(id: InfluxApp.windowID)
        }
    }
}

struct SourceRow: View {
    let source: Source
    let state: SourceFetchState?
    /// Whether its problem has lasted over a day, which the row says
    /// plainly instead of quietly.
    var isFailingLong = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            SourceDot(color: Color.paint(Broadsheet.sourceColor(source.colorIndex)))
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(.system(size: titleSize, design: .serif))
                    .lineLimit(1)
                if let problem = state?.problem, isFailingLong, let since = state?.problemSince {
                    Label("\(problem.message), since \(since.formatted(.dateTime.month(.abbreviated).day().hour().minute()))", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Color.paint(Broadsheet.alarm))
                } else if let problem = state?.problem {
                    Text(problem.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let address = source.url {
                    Text(Self.site(of: address))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    // Sized for the design, and scaled with the reader's text size.
    #if os(iOS)
    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 18
    #else
    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 16
    #endif

    /// The site a feed comes from, "avclub.com", which says more at a
    /// glance than the whole address.
    static func site(of address: String) -> String {
        guard let host = URL(string: address)?.host(), !host.isEmpty else { return address }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// A source's coloured dot.
struct SourceDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A small-capitals section label, with a count when it has one.
private struct SectionLabel: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .foregroundStyle(.secondary)
            if let count {
                Text("\(count)")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption.weight(.semibold))
        .tracking(0.9)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A section label as a row of its own, so its hairline is drawn and
/// placed like the rows' own: from the dots to the edge.
private struct LabelRow: ViewModifier {
    let rule: Color

    func body(content: Content) -> some View {
        content
            .padding(.top, 14)
            .padding(.bottom, 2)
            .listRowSeparator(.visible, edges: .bottom)
            .listRowSeparator(.hidden, edges: .top)
            .listRowSeparatorTint(rule)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }
}

#if os(macOS)
/// The Mac sheet's Done: ink on paper.
private struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color.paint(Broadsheet.paper))
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.paint(Broadsheet.ink)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
#endif

/// A quiet capsule button: a hairline outline, or a wash fill for the
/// one that adds.
private struct PillButtonStyle: ButtonStyle {
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(Color.paint(Broadsheet.ink))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(filled ? Color.paint(Broadsheet.wash) : .clear))
            .overlay(Capsule().strokeBorder(Color.paint(Broadsheet.rule)))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

/// A row that starts something: a plus in a hairline circle and a title.
private struct AddRowLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Color.paint(Broadsheet.rule)))
                .padding(.leading, -7)
                .accessibilityHidden(true)
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.paint(Broadsheet.ink))
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct AddRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AddRowLabel(title: title)
        }
        .buttonStyle(.plain)
    }
}

extension Accounts.Account.Service {
    /// The dot an account and its add button carry.
    var dotColor: Color {
        switch self {
        case .bluesky: .paint(Broadsheet.sourceColor(0))
        case .mastodon: .paint(Broadsheet.sourceColor(1))
        case .sammy: .paint(Broadsheet.sourceColor(5))
        }
    }
}

private struct AddFeedSheet: View {
    let feeds: Feeds
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var error: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Feed or site address", text: $address)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("feed-address")
                    .onSubmit(add)
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("add-feed-error")
                }
            }
            .navigationTitle("Add Feed")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Add", action: add)
                            .accessibilityIdentifier("add-feed-confirm")
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 160)
        #endif
    }

    private func add() {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                try await feeds.add(address)
                dismiss()
            } catch {
                self.error = addFeedMessage(for: error)
            }
        }
    }
}
