import Foundation
import Observation
import InfluxKit

/// The reader's saved views and filters, and which view the timeline shows
///. The store holds them; this mirrors them for the shell, once per
/// change. Filtering itself happens in the store, before rows reach the
/// timeline.
@MainActor
@Observable
final class Views {
    private(set) var saved: [SavedView] = []
    private(set) var filters: [ContentFilter] = []
    /// The view the timeline shows, remembered on this device only: each
    /// device can sit on a different view.
    var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: Self.selectionKey) }
    }

    @ObservationIgnored private let store: InfluxStore
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var watching: [Task<Void, Never>] = []

    private static let selectionKey = "InfluxSelectedView"

    init(store: InfluxStore) {
        self.store = store
        // Builds from before the rename kept the choice as FluxSelectedView.
        selectedID = UserDefaults.standard.string(forKey: Self.selectionKey)
            ?? UserDefaults.standard.string(forKey: "FluxSelectedView")
            ?? SavedView.allID
    }

    /// Starts watching the store. Calling it again does nothing.
    func start() {
        guard watching.isEmpty else { return }
        let store = store
        watching.append(Task { [weak self] in
            do {
                for try await saved in store.observeSavedViews() {
                    guard let self else { return }
                    self.update(saved: saved)
                }
            } catch {}
        })
        watching.append(Task { [weak self] in
            do {
                for try await filters in store.observeFilters() {
                    guard let self else { return }
                    self.filters = filters
                }
            } catch {}
        })
    }

    private func update(saved: [SavedView]) {
        // A view deleted on another device, or gone before launch, falls
        // back to All. One just made here may not have reached this list
        // yet, so only a view the list held, or the first list, counts.
        let wasListed = !hasLoaded || self.saved.contains { $0.id == selectedID }
        hasLoaded = true
        self.saved = saved
        if !SavedView.isBuiltIn(selectedID), wasListed, !saved.contains(where: { $0.id == selectedID }) {
            selectedID = SavedView.allID
        }
    }

    /// The name shown for a view.
    func name(of viewID: String) -> String {
        switch viewID {
        case SavedView.allID: "All"
        case SavedView.bookmarksID: "Bookmarks"
        default: saved.first { $0.id == viewID }?.name ?? "All"
        }
    }

    var selectedName: String { name(of: selectedID) }

    /// The filters that belong to `viewID` alone, or with nil those for
    /// every view.
    func filters(for viewID: String?) -> [ContentFilter] {
        filters.filter { $0.viewID == viewID }
    }

    // MARK: Changes

    /// Makes a view at the end of the list and returns it.
    @discardableResult
    func add(name: String, sourceIDs: [String]) async -> SavedView? {
        let view = SavedView(name: Self.clean(name), sourceIDs: sourceIDs, sortIndex: (saved.map(\.sortIndex).max() ?? -1) + 1)
        do {
            try await store.save(view: view)
            return view
        } catch {
            return nil
        }
    }

    /// Renames a view, against the view as stored now.
    func rename(_ viewID: String, to name: String) async {
        let name = Self.clean(name)
        try? await store.updateView(id: viewID) { $0.name = name }
    }

    /// Shows or hides one source in a view, against the view as stored
    /// now, so quick toggles never undo each other.
    func set(source sourceID: String, shown: Bool, in viewID: String) async {
        try? await store.updateView(id: viewID) { view in
            var ids = Set(view.sourceIDs)
            if shown { ids.insert(sourceID) } else { ids.remove(sourceID) }
            view.sourceIDs = ids.sorted()
        }
    }

    /// Shows exactly these sources in a view, for Select All and Select
    /// None, in one change against the view as stored now.
    func set(sources sourceIDs: Set<String>, in viewID: String) async {
        try? await store.updateView(id: viewID) { $0.sourceIDs = sourceIDs.sorted() }
    }

    func delete(_ view: SavedView) async {
        if selectedID == view.id { selectedID = SavedView.allID }
        try? await store.deleteView(id: view.id)
    }

    /// Saves the views in this order.
    func reorder(_ views: [SavedView]) async {
        for (index, view) in views.enumerated() where view.sortIndex != index {
            try? await store.updateView(id: view.id) { $0.sortIndex = index }
        }
    }

    func save(_ filter: ContentFilter) async {
        var filter = filter
        filter.updatedAt = Date()
        try? await store.save(filter: filter)
    }

    func delete(_ filter: ContentFilter) async {
        try? await store.deleteFilter(id: filter.id)
    }

    private static func clean(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled View" : trimmed
    }
}
