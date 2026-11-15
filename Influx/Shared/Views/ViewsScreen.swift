import SwiftUI
import InfluxKit

/// Saved views and filters: make a view over chosen sources, and hide rows
/// by keyword or regular expression in every view or in one.
struct ViewsScreen: View {
    let views: Views
    let feeds: Feeds
    @Environment(\.dismiss) private var dismiss
    @State private var isAddingView = false
    @State private var addingFilterFor: FilterTarget?

    var body: some View {
        NavigationStack {
            List {
                Section("Views") {
                    NavigationLink {
                        AllViewScreen(views: views)
                    } label: {
                        Label("All", systemImage: "tray.full")
                    }
                    ForEach(views.saved) { view in
                        NavigationLink {
                            ViewEditor(views: views, feeds: feeds, viewID: view.id)
                        } label: {
                            Label(view.name, systemImage: "line.3.horizontal.decrease")
                        }
                        .accessibilityIdentifier("view-\(view.name)")
                        // The Mac has no swipe to delete.
                        .contextMenu {
                            Button("Delete View", systemImage: "trash", role: .destructive) {
                                Task { await views.delete(view) }
                            }
                        }
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { views.saved[$0] }
                        Task { for view in doomed { await views.delete(view) } }
                    }
                    .onMove { from, to in
                        var reordered = views.saved
                        reordered.move(fromOffsets: from, toOffset: to)
                        Task { await views.reorder(reordered) }
                    }
                    Button("New View", systemImage: "plus") { isAddingView = true }
                        .accessibilityIdentifier("new-view")
                }
                FilterSection(title: "Filters in every view", views: views, viewID: nil) {
                    addingFilterFor = FilterTarget(viewID: nil)
                }
            }
            .navigationTitle("Views & Filters")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("views-done")
                }
            }
            .sheet(isPresented: $isAddingView) {
                NewViewSheet(views: views, feeds: feeds)
            }
            .sheet(item: $addingFilterFor) { target in
                AddFilterSheet(views: views, viewID: target.viewID)
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }
}

/// Which view a new filter starts out applying to; nil for every view.
private struct FilterTarget: Identifiable {
    var viewID: String?
    var id: String { viewID ?? "" }
}

/// The All view can't be changed, but can have filters of its own.
private struct AllViewScreen: View {
    let views: Views
    @State private var isAdding = false

    var body: some View {
        List {
            Section {
                Text("Every source, always. Filters here hide rows in All but not in your other views.")
                    .foregroundStyle(.secondary)
            }
            FilterSection(title: "Filters in All", views: views, viewID: SavedView.allID) { isAdding = true }
        }
        .navigationTitle("All")
        .sheet(isPresented: $isAdding) {
            AddFilterSheet(views: views, viewID: SavedView.allID)
        }
    }
}

/// A saved view's name, sources and own filters. Changes save as they're
/// made.
private struct ViewEditor: View {
    let views: Views
    let feeds: Feeds
    let viewID: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isAddingFilter = false

    private var view: SavedView? { views.saved.first { $0.id == viewID } }

    var body: some View {
        Form {
            if let view {
                Section("Name") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("view-name")
                        .onSubmit { rename(view) }
                }
                SourcePicker(sources: feeds.sources, selected: Set(view.sourceIDs)) { sourceID, shown in
                    Task { await views.set(source: sourceID, shown: shown, in: viewID) }
                } setAll: { sourceIDs in
                    Task { await views.set(sources: sourceIDs, in: viewID) }
                }
                FilterSection(title: "Filters in this view", views: views, viewID: viewID) { isAddingFilter = true }
                Section {
                    Button("Delete View", systemImage: "trash", role: .destructive) {
                        Task {
                            await views.delete(view)
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("delete-view")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(view?.name ?? "View")
        .onAppear { name = view?.name ?? "" }
        .onDisappear { if let view { rename(view) } }
        .sheet(isPresented: $isAddingFilter) {
            AddFilterSheet(views: views, viewID: viewID)
        }
    }

    private func rename(_ view: SavedView) {
        guard name != view.name else { return }
        let name = name
        Task { await views.rename(view.id, to: name) }
    }
}

/// The sources to show in a view, one switch each, accounts' sources first,
/// with Select All, or Select None once every source is on.
private struct SourcePicker: View {
    let sources: [Source]
    let selected: Set<String>
    let set: @MainActor @Sendable (_ sourceID: String, _ shown: Bool) -> Void
    let setAll: @MainActor @Sendable (_ sourceIDs: Set<String>) -> Void

    /// Every source is on. A source deleted since the view was made may
    /// still be in `selected`, so this counts only the sources listed.
    private var allSelected: Bool {
        !sources.isEmpty && sources.allSatisfy { selected.contains($0.id) }
    }

    var body: some View {
        Section {
            if sources.isEmpty {
                Text("Add feeds or accounts in Sources first.")
                    .foregroundStyle(.secondary)
            }
            ForEach(ordered) { source in
                Toggle(isOn: Binding(get: { selected.contains(source.id) }, set: { set(source.id, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.title)
                        Text(source.kindName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("source-\(source.id)")
            }
        } header: {
            HStack {
                Text("Sources")
                Spacer()
                if !sources.isEmpty {
                    Button(allSelected ? "Select None" : "Select All") {
                        setAll(allSelected ? [] : Set(sources.map(\.id)))
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote)
                    .textCase(nil)
                    .accessibilityIdentifier("select-all-sources")
                }
            }
        }
    }

    private var ordered: [Source] {
        sources.sorted { ($0.kind == .rss ? 1 : 0, $0.title.lowercased(), $0.id) < ($1.kind == .rss ? 1 : 0, $1.title.lowercased(), $1.id) }
    }
}

private struct NewViewSheet: View {
    let views: Views
    let feeds: Feeds
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selection: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("new-view-name")
                }
                SourcePicker(sources: feeds.sources, selected: selection) { sourceID, shown in
                    if shown { selection.insert(sourceID) } else { selection.remove(sourceID) }
                } setAll: { sourceIDs in
                    selection = sourceIDs
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New View")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            if let view = await views.add(name: name, sourceIDs: selection.sorted()) {
                                // A new view is one the reader wants to see.
                                views.selectedID = view.id
                            }
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("new-view-confirm")
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selection.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }
}

/// The filters that apply to one view, or with nil to every view.
private struct FilterSection: View {
    let title: String
    let views: Views
    let viewID: String?
    let add: () -> Void

    var body: some View {
        Section {
            ForEach(views.filters(for: viewID)) { filter in
                FilterRow(filter: filter) { enabled in
                    var changed = filter
                    changed.isEnabled = enabled
                    Task { await views.save(changed) }
                }
                .contextMenu {
                    Button("Delete Filter", systemImage: "trash", role: .destructive) {
                        Task { await views.delete(filter) }
                    }
                }
            }
            .onDelete { offsets in
                let doomed = offsets.map { views.filters(for: viewID)[$0] }
                Task { for filter in doomed { await views.delete(filter) } }
            }
            Button("Add Filter", systemImage: "plus", action: add)
                .accessibilityIdentifier("add-filter")
        } header: {
            Text(title)
        } footer: {
            Text("Rows whose text matches are hidden. Keywords match whole words, ignoring case and accents.")
        }
    }
}

private struct FilterRow: View {
    let filter: ContentFilter
    let setEnabled: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { filter.isEnabled }, set: setEnabled)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(filter.pattern)
                    .font(filter.match == .regex ? .body.monospaced() : .body)
                Text(filter.match == .regex ? "Regular expression" : "Keyword")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("filter-\(filter.pattern)")
    }
}

private struct AddFilterSheet: View {
    let views: Views
    @Environment(\.dismiss) private var dismiss
    @State private var pattern = ""
    @State private var match: ContentFilter.Match = .keyword
    @State private var viewID: String?

    init(views: Views, viewID: String?) {
        self.views = views
        _viewID = State(initialValue: viewID)
    }

    private var filter: ContentFilter { ContentFilter(pattern: pattern, match: match, viewID: viewID) }

    var body: some View {
        NavigationStack {
            Form {
                TextField(match == .regex ? "Regular expression" : "Word or phrase", text: $pattern)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("filter-pattern")
                Picker("Match", selection: $match) {
                    Text("Keyword").tag(ContentFilter.Match.keyword)
                    Text("Regular Expression").tag(ContentFilter.Match.regex)
                }
                .accessibilityIdentifier("filter-match")
                Picker("Hide in", selection: $viewID) {
                    Text("Every view").tag(String?.none)
                    Text("All").tag(String?.some(SavedView.allID))
                    ForEach(views.saved) { view in
                        Text(view.name).tag(String?.some(view.id))
                    }
                }
                if match == .regex, !pattern.isEmpty, !filter.isValid {
                    Text("That isn't a valid regular expression.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("filter-error")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Filter")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let filter = filter
                        Task {
                            await views.save(filter)
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("add-filter-confirm")
                    .disabled(!filter.isValid)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 260)
        #endif
    }
}

extension Source {
    /// What kind of source it is, under its name.
    var kindName: String {
        switch kind {
        case .rss: "RSS feed"
        case .mastodonHome: "Mastodon home"
        case .mastodonList: "Mastodon list"
        case .blueskyFollowing: "Bluesky following"
        case .blueskyFeed: "Bluesky feed"
        case .sammyFeed: "Sammy feed"
        }
    }
}

/// The view menu in the timeline's bar: switch views, or edit them.
struct ViewMenu: View {
    let views: Views
    let edit: () -> Void

    var body: some View {
        Menu {
            Picker("View", selection: Binding(get: { views.selectedID }, set: { views.selectedID = $0 })) {
                Text("All").tag(SavedView.allID)
                Text("Bookmarks").tag(SavedView.bookmarksID)
                    .accessibilityIdentifier("view-bookmarks")
                ForEach(views.saved) { view in
                    Text(view.name).tag(view.id)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Edit Views & Filters…", systemImage: "slider.horizontal.3", action: edit)
                .accessibilityIdentifier("edit-views")
        } label: {
            Label(views.selectedName, systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityIdentifier("views-menu")
    }
}
