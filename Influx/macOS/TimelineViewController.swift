// The timeline on macOS: an NSCollectionView fed diffable snapshots of merge
// keys, with every row's geometry and bitmap made off the main thread
//. TimelineController decides what to show and where; this class
// only puts it on screen.
import AppKit
import SwiftUI
import InfluxKit

final class TimelineViewController: NSViewController, TimelineSurface, ItemMenuTarget {
    private let app: AppModel
    private let timeline: TimelineController
    private let interactions: RowInteractions
    /// A short line about an action that failed.
    /// The note a refused action shows; open to tests.
    let notice = NSTextField(labelWithString: "")
    private var noticeHide: Task<Void, Never>?
    private let jumps: TimelineJumps
    private let items: TimelineItems
    private let layout = PrecomputedLayout()
    let scrollView = TimelineScrollView()
    private let collectionView = TimelineCollectionView()
    private var dataSource: NSCollectionViewDiffableDataSource<Int, String>!
    private let unreadPill = NSButton(title: "", target: nil, action: nil)
    private var hud: NSTextField?
    private var liveScrolling = false
    /// A link's request that came before the timeline was on screen.
    private var waitingRequest: TimelineItems.Request?

    init(app: AppModel, viewID: String, jumps: TimelineJumps, items: TimelineItems) {
        self.app = app
        self.jumps = jumps
        self.items = items
        timeline = TimelineController(store: app.store, viewID: viewID, opening: app.takeOpening(for: viewID))
        interactions = RowInteractions(app: app)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = AppearanceView(frame: NSRect(x: 0, y: 0, width: 720, height: 900))
        container.onAppearanceChange = { [weak self] in self?.updateEnvironment() }

        layout.model = timeline.model
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [Broadsheet.paper]
        collectionView.isSelectable = false
        collectionView.setAccessibilityIdentifier("timeline")
        collectionView.register(TimelineItem.self, forItemWithIdentifier: TimelineItem.identifier)
        // Rows are bitmaps, so one recognizer serves every row: the
        // controller finds what the click reached from the row's geometry.
        collectionView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked(_:))))
        collectionView.menuAt = { [weak self] point in self?.itemMenu(at: point) }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Broadsheet.paper
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.contentView.postsBoundsChangedNotifications = true
        container.addSubview(scrollView)

        unreadPill.bezelStyle = .glass
        unreadPill.target = self
        unreadPill.action = #selector(showNewest)
        unreadPill.toolTip = "Jump to the newest posts"
        unreadPill.isHidden = true
        unreadPill.setAccessibilityIdentifier("unread-pill")
        unreadPill.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(unreadPill)
        NSLayoutConstraint.activate([
            unreadPill.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            unreadPill.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])

        // Body-sized and rounded, so a refused action is seen: the
        // footnote-sized one went unnoticed.
        notice.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold)
        notice.textColor = Broadsheet.paper
        notice.drawsBackground = true
        notice.backgroundColor = Broadsheet.ink
        notice.wantsLayer = true
        notice.layer?.cornerRadius = 8
        notice.layer?.masksToBounds = true
        notice.lineBreakMode = .byWordWrapping
        notice.maximumNumberOfLines = 3
        notice.preferredMaxLayoutWidth = 520
        notice.isHidden = true
        notice.setAccessibilityIdentifier("action-notice")
        notice.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            notice.bottomAnchor.constraint(equalTo: unreadPill.topAnchor, constant: -12),
        ])

        view = container
        if AppSettings.showScrollDiagnostics { setUpDiagnostics(in: container) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        dataSource = NSCollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, _ in
            let item = collectionView.makeItem(withIdentifier: TimelineItem.identifier, for: indexPath)
            if let self, let row = item as? TimelineItem {
                self.show(row, row: indexPath.item)
            }
            return item
        }
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewMoved),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollStarted),
                                               name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollEnded),
                                               name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveResizeStarted),
                                               name: NSWindow.willStartLiveResizeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(liveResizeEnded),
                                               name: NSWindow.didEndLiveResizeNotification, object: nil)

        timeline.surface = self
        jumps.attach(timeline)
        items.attach(self)
        timeline.start()
    }

    /// Stops watching the store and, with diagnostics on, the display link,
    /// which the run loop would otherwise keep alive.
    func tearDown() {
        jumps.detach(timeline)
        items.detach(self)
        timeline.stop()
        VideoPlayback.stop()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateEnvironment()
        if let request = waitingRequest {
            waitingRequest = nil
            take(request)
        }
    }

    func take(_ request: TimelineItems.Request) {
        // A sheet can only be shown from a view in its window.
        guard viewIfLoaded?.window != nil else {
            waitingRequest = request
            return
        }
        switch request {
        case .open(let row):
            // The link is what the reader asked for now: a sheet still
            // open from before closes first.
            closeSheet()
            if let hit = RowHit.opening(row) { perform(hit) }
        case .reveal(let key):
            // A sheet from before would hide the row.
            closeSheet()
            timeline.reveal(key)
        case .notice(let message):
            // Shown over the timeline, so a sheet from before closes first.
            closeSheet()
            showNotice(message)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Lay out again when the width settles, not on every frame of a live resize.
        guard view.window?.inLiveResize != true else { return }
        updateEnvironment()
    }

    @objc private func liveResizeStarted(_ notification: Notification) {
        guard notification.object as? NSWindow === view.window else { return }
        timeline.monitor?.isResizing = true
    }

    @objc private func liveResizeEnded(_ notification: Notification) {
        guard notification.object as? NSWindow === view.window else { return }
        timeline.monitor?.isResizing = false
        timeline.monitor?.exclude()
        updateEnvironment()
    }

    @objc private func liveScrollStarted() {
        liveScrolling = true
    }

    @objc private func liveScrollEnded() {
        liveScrolling = false
    }

    @objc private func clipViewMoved() {
        timeline.scrolled()
    }

    @objc private func showNewest() {
        timeline.jumpToNewest()
    }

    private func updateEnvironment() {
        guard let window = view.window else { return }
        timeline.use(RowEnvironment(
            width: scrollView.contentSize.width,
            scale: window.backingScaleFactor,
            dark: view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
            typography: Typography(),
            colorSpace: (window.colorSpace?.cgColorSpace?.name as String?) ?? CGColorSpace.sRGB as String
        ))
    }

    // MARK: - TimelineSurface

    var viewportTop: CGFloat {
        scrollView.contentView.bounds.minY + scrollView.contentInsets.top
    }

    var viewportHeight: CGFloat {
        scrollView.contentView.bounds.height - scrollView.contentInsets.top - scrollView.contentInsets.bottom
    }

    /// Trackpad and Magic Mouse scrolls, momentum included. A wheel scroll
    /// moves in steps between which nothing is in motion.
    var isScrolling: Bool { liveScrolling }

    /// Trackpad scrolls are live scrolls; a wheel notch, a scrolling key
    /// or the scroller is marked by the view that handles it. A click, or
    /// any other key, that leads to a relayout is not the reader moving.
    var isReaderInput: Bool { liveScrolling || scrollView.handledReaderInputRecently }

    func setViewportTop(_ y: CGFloat, animated: Bool) {
        let insets = scrollView.contentInsets
        let clip = scrollView.contentView
        let maxOrigin = timeline.model.totalHeight - clip.bounds.height + insets.bottom
        let origin = NSPoint(x: 0, y: max(-insets.top, min(y - insets.top, maxOrigin)))
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                clip.animator().setBoundsOrigin(origin)
            }
        } else {
            clip.scroll(to: origin)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    func show(_ keys: [String], reload: Bool, reconfigure: [String]) async {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(keys)
        // AppKit has no reload-data variant; a full relayout keeps the same
        // keys, so this diff is cheap, and visible items are refreshed below.
        dataSource.apply(snapshot, animatingDifferences: false)
        layout.invalidateLayout()
        collectionView.layoutSubtreeIfNeeded()
        let refresh = reload ? nil : Set(reconfigure)
        for indexPath in collectionView.indexPathsForVisibleItems() where indexPath.item < timeline.model.count {
            guard refresh?.contains(timeline.model.rows[indexPath.item].mergeKey) ?? true else { continue }
            if let item = collectionView.item(at: indexPath) as? TimelineItem { show(item, row: indexPath.item) }
        }
    }

    private func show(_ item: TimelineItem, row index: Int) {
        let actions = timeline.accessibilityActionsSource(forRow: index)
        item.show(timeline.image(forRow: index), label: timeline.accessibilityLabel(forRow: index), actions: { [weak self] in
            actions().map { action in
                NSAccessibilityCustomAction(name: action.name) {
                    self?.perform(action.hit)
                    return true
                }
            }
        })
    }

    func refreshCell(_ key: String) {
        guard let index = timeline.model.index(of: key),
              let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? TimelineItem
        else { return }
        show(item, row: index)
    }

    /// The hitch counter's text, when scroll diagnostics are on.
    var diagnosticsText: String? { hud?.stringValue }

    func showUnread(_ count: Int) {
        unreadPill.title = "\(count) unread"
        unreadPill.isHidden = count == 0
    }

    /// A wash over a Find result that fades, in the collection view's own
    /// coordinates so it scrolls with the row. It takes no clicks.
    func flash(_ frame: CGRect) {
        let mark = FindHighlight(frame: frame)
        collectionView.addSubview(mark)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1.8
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.7, 0, 1, 1)
            mark.animator().alphaValue = 0
        } completionHandler: {
            mark.removeFromSuperview()
        }
    }

    // MARK: - Clicks

    @objc private func clicked(_ click: NSClickGestureRecognizer) {
        guard presentedViewControllers?.isEmpty ?? true else { return }
        let point = click.location(in: collectionView)
        timeline.choose(at: point)
        guard let hit = timeline.hit(at: point) else { return }
        perform(hit)
    }

    private func perform(_ hit: RowHit) {
        switch hit {
        case .action(.thread, let row), .thread(let row):
            openThread(row)
        case .action(let action, let row):
            guard let toggle = action.toggle else { return }
            Task {
                if let message = await interactions.toggle(toggle, on: row) { showNotice(message) }
            }
        case .video(let media):
            VideoPlayback.play(media, from: nil)
        case .image(let media):
            presentSheet(ImageViewer(media: media) { [weak self] in self?.closeSheet() })
        case .link(let url):
            NSWorkspace.shared.open(url)
        case .article(let row, let url):
            interactions.markRead(row)
            NSWorkspace.shared.open(url)
        }
    }

    private func openThread(_ row: TimelineRow) {
        Task { [weak self] in
            guard let self else { return }
            guard let (post, _) = await interactions.thread(for: row) else {
                showNotice("Sign in to this account on this device to see the thread.")
                return
            }
            presentSheet(ThreadScreen(post: post, interactions: interactions) { [weak self] in self?.closeSheet() })
        }
    }

    private func presentSheet(_ content: some View) {
        guard presentedViewControllers?.isEmpty ?? true else { return }
        presentAsSheet(NSHostingController(rootView: content))
    }

    private func closeSheet() {
        presentedViewControllers?.forEach { dismiss($0) }
    }

    /// Shows `message` over the timeline for a few seconds.
    func showNotice(_ message: String) {
        notice.stringValue = "  \(message)  "
        notice.isHidden = false
        NSAccessibility.post(element: notice, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        noticeHide?.cancel()
        noticeHide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice.isHidden = true
        }
    }

    // MARK: - Item menu

    /// The row menu for a right-click at `point`.
    private func itemMenu(at point: NSPoint) -> NSMenu? {
        guard presentedViewControllers?.isEmpty ?? true, let row = timeline.choose(at: point) else { return nil }
        let menu = NSMenu()
        let actions = ItemAction.available(for: row)
        for group in ItemAction.grouped(actions) {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for action in group {
                if action == .share, let url = ItemMenu.originalURL(row) {
                    // The system's Share submenu, listing the services.
                    menu.addItem(NSSharingServicePicker(items: [url]).standardShareMenuItem)
                    continue
                }
                let item = ActionMenuItem(title: action.title(for: row)) { [weak self] in self?.perform(action, on: row) }
                item.image = NSImage(systemSymbolName: action.symbol(for: row), accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
        return menu.items.isEmpty ? nil : menu
    }

    func performOnCurrentRow(_ action: ItemAction) {
        guard presentedViewControllers?.isEmpty ?? true, let row = timeline.currentRow else { return }
        guard action.applies(to: row) else {
            showNotice(ItemMenu.unavailable(action))
            return
        }
        perform(action, on: row)
    }

    private func perform(_ action: ItemAction, on row: TimelineRow) {
        switch action {
        case .openOriginal:
            if let hit = ItemMenu.original(of: row) { perform(hit) }
        case .openThread:
            openThread(row)
        case .openAuthor:
            if let url = RowText.profileURL(row) { NSWorkspace.shared.open(url) }
        case .bookmark:
            Task {
                if let message = await interactions.toggle(.bookmark, on: row) { showNotice(message) }
            }
        case .copyLink:
            guard let url = ItemMenu.originalURL(row) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.absoluteString, forType: .URL)
            pasteboard.setString(url.absoluteString, forType: .string)
        case .copyText:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ItemMenu.text(of: row), forType: .string)
        case .share:
            guard let url = ItemMenu.originalURL(row), let frame = timeline.visibleFrame(of: row) else { return }
            NSSharingServicePicker(items: [url]).show(relativeTo: frame, of: collectionView, preferredEdge: .minY)
        }
    }

    // MARK: - Scroll diagnostics

    private func setUpDiagnostics(in container: NSView) {
        let hud = NSTextField(wrappingLabelWithString: "")
        hud.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        hud.textColor = .white
        hud.drawsBackground = true
        hud.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        hud.isSelectable = false
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.setAccessibilityIdentifier("hitch-hud")
        hud.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(resetDiagnostics)))
        container.addSubview(hud)
        self.hud = hud
        var constraints = [
            hud.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            hud.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
        ]

        if app.addSampleRows != nil {
            let add = NSButton(title: "+20", target: self, action: #selector(addSampleRows))
            add.bezelStyle = .glass
            add.setAccessibilityIdentifier("add-newer")
            add.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(add)
            constraints += [
                add.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
                add.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            ]
        }
        NSLayoutConstraint.activate(constraints)

        let monitor = HitchMonitor { [weak self] text in self?.hud?.stringValue = text }
        timeline.monitor = monitor
        monitor.start(in: container)
    }

    @objc private func addSampleRows() {
        guard let add = app.addSampleRows else { return }
        Task { await add() }
    }

    @objc func resetDiagnostics() {
        timeline.resetDiagnostics()
    }
}

/// The timeline's collection view, which asks for a row's menu on a
/// right-click or Control-click, and marks a scrolling key as the reader's.
private final class TimelineCollectionView: NSCollectionView {
    var menuAt: ((NSPoint) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuAt?(convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        if let key = event.charactersIgnoringModifiers?.unicodeScalars.first, Self.scrollingKeys.contains(Int(key.value)) {
            // Not under the "Syncing in Progress" screen.
            guard !SyncingGate.holdsTimeline else { return }
            (enclosingScrollView as? TimelineScrollView)?.noteReaderInput()
        }
        super.keyDown(with: event)
    }

    private static let scrollingKeys: Set<Int> = [
        NSUpArrowFunctionKey, NSDownArrowFunctionKey, NSPageUpFunctionKey, NSPageDownFunctionKey,
        NSHomeFunctionKey, NSEndFunctionKey, 0x20,
    ]
}

/// A menu item that runs a closure.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() {
        handler()
    }
}

/// The timeline's scroll view. A notched mouse wheel moves as far per notch
/// as it does in Safari: AppKit's default line scroll is a quarter of that,
/// which makes a long timeline a slog to wheel through. Trackpads and the
/// Magic Mouse send precise pixel deltas, which ignore the line scroll, so
/// they feel the same as before.
final class TimelineScrollView: NSScrollView {
    /// Points per wheel line, WebKit's pixelsPerLineStep. The system's
    /// scrolling-speed setting and wheel acceleration still apply on top.
    static let wheelLineScroll: CGFloat = 40

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        verticalLineScroll = Self.wheelLineScroll
        let scroller = TimelineScroller()
        scroller.onReaderInput = { [weak self] in self?.noteReaderInput() }
        verticalScroller = scroller
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Until when a scroll counts as the reader's: a moment after a wheel
    /// notch or a scrolling key, so the scroll it starts, animated or not,
    /// is theirs, and a relayout at any other time isn't.
    private var readerInputUntil = ContinuousClock.now

    var handledReaderInputRecently: Bool {
        (verticalScroller as? TimelineScroller)?.isTracking == true || ContinuousClock.now < readerInputUntil
    }

    func noteReaderInput() {
        readerInputUntil = .now + .milliseconds(500)
    }

    override func scrollWheel(with event: NSEvent) {
        // The "Syncing in Progress" screen covers the timeline: a scroll
        // now would start from a place another device may have moved on from.
        guard !SyncingGate.holdsTimeline else { return }
        noteReaderInput()
        super.scrollWheel(with: event)
    }
}

/// The timeline's scroller. A click in its track or a drag of its knob is
/// the reader moving, for as long as the mouse is down and a moment after.
final class TimelineScroller: NSScroller {
    var onReaderInput: (() -> Void)?
    private(set) var isTracking = false

    override func mouseDown(with event: NSEvent) {
        guard !SyncingGate.holdsTimeline else { return }
        isTracking = true
        onReaderInput?()
        // Tracks the click or drag until the mouse goes up.
        super.mouseDown(with: event)
        isTracking = false
        onReaderInput?()
    }
}

/// The controller's root view; it reports light and dark mode changes so the
/// rows can be drawn again.
private final class AppearanceView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// The fading wash over a Find result.
private final class FindHighlight: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.25).cgColor
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
