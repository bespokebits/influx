// The timeline on iOS: a UICollectionView fed diffable snapshots of merge
// keys, with every row's geometry and bitmap made off the main thread
//. TimelineController decides what to show and where; this class
// only puts it on screen.
import SwiftUI
import UIKit
import InfluxKit

final class TimelineViewController: UIViewController, UICollectionViewDelegate, UIGestureRecognizerDelegate, TimelineSurface, ItemMenuTarget {
    private let app: AppModel
    private let timeline: TimelineController
    private let interactions: RowInteractions
    /// A short line about an action that failed.
    private let notice = UILabel()
    private var noticeHide: Task<Void, Never>?
    private let jumps: TimelineJumps
    private let items: TimelineItems
    private let layout = PrecomputedLayout()
    private var collectionView: TimelineCollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private let unreadPill = UIButton(configuration: .filled())
    private let pullRefresh = PullRefreshMark.Refresh()
    /// The mark below the last row, made on the first pull.
    private var pullMarkView: PullRingView?
    private var isPullRefreshing = false
    private var hud: UILabel?
    /// Perf runs: whether the launch time to the first rows is recorded.
    private var launchTimed = false
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

    override func viewDidLoad() {
        super.viewDidLoad()
        LaunchClock.mark("view")
        view.backgroundColor = Broadsheet.paper

        layout.model = timeline.model
        collectionView = TimelineCollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = Broadsheet.paper
        collectionView.accessibilityIdentifier = "timeline"
        collectionView.delegate = self
        // Cell setup is a bitmap swap, so there's nothing to gain from UIKit
        // configuring cells early, and a late bitmap must find its cell visible.
        collectionView.isPrefetchingEnabled = false
        view.addSubview(collectionView)
        // Rows are bitmaps, so one recognizer serves every row: the
        // controller finds what the tap reached from the row's geometry.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        collectionView.addGestureRecognizer(tap)

        let registration = UICollectionView.CellRegistration<TimelineCell, String> { [weak self] cell, indexPath, _ in
            guard let self else { return }
            self.show(cell, row: indexPath.item)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, key in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: key)
        }

        setUpUnreadPill()
        setUpNotice()
        setUpPullToRefresh()
        if AppSettings.showScrollDiagnostics { setUpDiagnostics() }

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self, UITraitDisplayScale.self]) {
            (self: Self, _: UITraitCollection) in
            self.updateEnvironment()
        }

        timeline.surface = self
        jumps.attach(timeline)
        items.attach(self)
        startLaunchTiming()
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

    /// Back from the full-screen player: stop the video, which would
    /// otherwise keep playing sound behind the timeline.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if presentedViewController == nil {
            VideoPlayback.stop()
        }
        if let request = waitingRequest {
            waitingRequest = nil
            take(request)
        }
    }

    /// The first point where the view is in its window with real traits.
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        updateEnvironment()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateEnvironment()
        placeRefreshIndicator()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        timeline.scrolled()
        showPullProgress()
    }

    /// The status bar goes to the marker or the newest rows, not the oldest.
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        // The jump itself is refused under the syncing screen too.
        guard !SyncingGate.holdsTimeline else { return false }
        timeline.statusBarTapped()
        return false
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard pastNewestEdge >= Self.pullDistance, !isPullRefreshing else { return }
        refreshFromPull()
        // Settle with the indicator's space showing, not back on the last row.
        let insets = collectionView.adjustedContentInset
        targetContentOffset.pointee.y = max(-insets.top, collectionView.contentSize.height - collectionView.bounds.height + insets.bottom)
    }

    /// The environment last kept for the next launch.
    private var remembered: RowEnvironment?

    private func updateEnvironment() {
        // Before the view is in a window its traits are placeholders, and
        // laying out for them would be thrown away a moment later.
        guard collectionView != nil, let window = view.window else { return }
        let environment = RowEnvironment(
            width: collectionView.bounds.width,
            scale: traitCollection.displayScale,
            dark: traitCollection.userInterfaceStyle == .dark,
            typography: Typography(traits: traitCollection)
        )
        timeline.use(environment)
        // Layout passes come often; the next launch's guess changes rarely.
        if environment != remembered, environment.width > 0, let screen = window.windowScene?.screen {
            remembered = environment
            TimelineOpening.remember(environment, screenHeight: screen.bounds.height)
        }
    }

    // MARK: - TimelineSurface

    var viewportTop: CGFloat {
        collectionView.contentOffset.y + collectionView.adjustedContentInset.top
    }

    var viewportHeight: CGFloat {
        collectionView.bounds.height - collectionView.adjustedContentInset.top - collectionView.adjustedContentInset.bottom
    }

    var isScrolling: Bool {
        collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
    }

    /// A touch scroll, or a VoiceOver, Switch Control or keyboard scroll,
    /// which move the view without a touch.
    var isReaderInput: Bool { isScrolling || collectionView.handledReaderInputRecently }

    func setViewportTop(_ y: CGFloat, animated: Bool) {
        let insets = collectionView.adjustedContentInset
        let maxOffset = collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
        let offset = max(-insets.top, min(y - insets.top, maxOffset))
        collectionView.setContentOffset(CGPoint(x: 0, y: offset), animated: animated)
    }

    func show(_ keys: [String], reload: Bool, reconfigure: [String]) async {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(keys)
        // The completion-handler forms apply at once on the main thread;
        // awaiting the async forms would wait a turn of the main thread.
        if reload {
            dataSource.applySnapshotUsingReloadData(snapshot, completion: nil)
        } else {
            let existing = Set(dataSource.snapshot().itemIdentifiers)
            let refresh = reconfigure.filter { existing.contains($0) }
            if !refresh.isEmpty { snapshot.reconfigureItems(refresh) }
            dataSource.apply(snapshot, animatingDifferences: false, completion: nil)
        }
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        placeRefreshIndicator()
        timeLaunchIfDrawn()
    }

    /// Perf runs: once every visible row has its bitmap, waits for the next
    /// frame, the one that puts them on screen, and records the time since
    /// launch in the timeline's accessibility value for the launch test.
    /// Media inside a row may still be paper; its text is drawn.
    private func timeLaunchIfDrawn() {
        guard AppSettings.perfStore, !launchTimed else { return }
        let cells = collectionView.visibleCells
        guard !cells.isEmpty, cells.allSatisfy({ ($0 as? TimelineCell)?.contentView.layer.contents != nil }) else { return }
        launchTimed = true
        LaunchClock.mark("drawn")
    }

    /// Perf runs: checks every frame until the first rows are drawn (they
    /// can go in during a layout pass, before their cells exist), then
    /// records the frame after, the one that shows them.
    private func startLaunchTiming() {
        guard AppSettings.perfStore else { return }
        let link = CADisplayLink(target: self, selector: #selector(launchFrame(_:)))
        link.add(to: .main, forMode: .common)
    }

    @objc private func launchFrame(_ link: CADisplayLink) {
        guard launchTimed else {
            timeLaunchIfDrawn()
            return
        }
        link.invalidate()
        guard let ms = LaunchClock.millisecondsSinceAppStart() else { return }
        collectionView.accessibilityValue = String(format: "first rows %.0f ms · ", ms) + LaunchClock.breakdown
    }

    func refreshCell(_ key: String) {
        guard let index = timeline.model.index(of: key),
              let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? TimelineCell
        else { return }
        show(cell, row: index)
        timeLaunchIfDrawn()
    }

    private func show(_ cell: TimelineCell, row index: Int) {
        let actions = timeline.accessibilityActionsSource(forRow: index)
        cell.show(timeline.image(forRow: index), scale: traitCollection.displayScale,
                  label: timeline.accessibilityLabelSource(forRow: index),
                  actions: { [weak self] in
                      actions().map { action in
                          UIAccessibilityCustomAction(name: action.name) { _ in
                              self?.perform(action.hit)
                              return true
                          }
                      }
                  })
    }

    func showUnread(_ count: Int) {
        unreadPill.configuration?.title = "\(count) unread"
        unreadPill.isHidden = count == 0
    }

    /// A wash over a Find result that fades, in the collection view's own
    /// coordinates so it scrolls with the row. It takes no touches.
    func flash(_ frame: CGRect) {
        let mark = UIView(frame: frame)
        mark.isUserInteractionEnabled = false
        mark.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.25)
        mark.accessibilityIdentifier = "find-highlight"
        mark.layer.zPosition = 10
        collectionView.addSubview(mark)
        UIView.animate(withDuration: 1.2, delay: 0.6, options: [.allowUserInteraction]) {
            mark.alpha = 0
        } completion: { _ in
            mark.removeFromSuperview()
        }
    }

    // MARK: - Taps

    /// A tap that stops a fling only stops it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !collectionView.isDecelerating
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard presentedViewController == nil else { return }
        let point = tap.location(in: collectionView)
        timeline.choose(at: point)
        guard let hit = timeline.hit(at: point) else { return }
        perform(hit)
    }

    private func perform(_ hit: RowHit) {
        guard presentedViewController == nil else { return }
        switch hit {
        case .action(.thread, let row), .thread(let row):
            openThread(row)
        case .action(let action, let row):
            guard let toggle = action.toggle else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task {
                if let message = await interactions.toggle(toggle, on: row) { showNotice(message) }
            }
        case .video(let media):
            VideoPlayback.play(media, from: self)
        case .image(let media):
            let viewer = UIHostingController(rootView: ImageViewer(media: media) { [weak self] in self?.dismiss(animated: true) })
            viewer.modalPresentationStyle = .fullScreen
            present(viewer, animated: true)
        case .link(let url):
            UIApplication.shared.open(url)
        case .article(let row, let url):
            interactions.markRead(row)
            UIApplication.shared.open(url)
        }
    }

    private func openThread(_ row: TimelineRow) {
        Task { [weak self] in
            guard let self else { return }
            guard let (post, _) = await interactions.thread(for: row) else {
                showNotice("Sign in to this account on this device to see the thread.")
                return
            }
            guard presentedViewController == nil else { return }
            let screen = ThreadScreen(post: post, interactions: interactions) { [weak self] in self?.dismiss(animated: true) }
            let host = UIHostingController(rootView: screen)
            host.modalPresentationStyle = .pageSheet
            present(host, animated: true)
        }
    }

    // MARK: - Item menu

    /// A long press on a row shows its menu.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard presentedViewController == nil, let row = timeline.choose(at: point) else { return nil }
        let actions = ItemAction.available(for: row)
        guard !actions.isEmpty else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            return UIMenu(children: ItemAction.grouped(actions).map { group in
                UIMenu(options: .displayInline, children: group.map { action in
                    UIAction(title: action.title(for: row), image: UIImage(systemName: action.symbol(for: row))) { _ in
                        self?.perform(action, on: row)
                    }
                })
            })
        })
    }

    func performOnCurrentRow(_ action: ItemAction) {
        guard presentedViewController == nil, let row = timeline.currentRow else { return }
        guard action.applies(to: row) else {
            showNotice(ItemMenu.unavailable(action))
            return
        }
        perform(action, on: row)
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
            guard let hit = RowHit.opening(row) else { return }
            if presentedViewController != nil {
                dismiss(animated: false) { [weak self] in self?.perform(hit) }
            } else {
                perform(hit)
            }
        case .reveal(let key):
            // A sheet from before would hide the row.
            if presentedViewController != nil {
                dismiss(animated: false) { [weak self] in self?.timeline.reveal(key) }
            } else {
                timeline.reveal(key)
            }
        case .notice(let message):
            // Shown over the timeline, so a sheet from before closes first.
            if presentedViewController != nil {
                dismiss(animated: false) { [weak self] in self?.showNotice(message) }
            } else {
                showNotice(message)
            }
        }
    }

    private func perform(_ action: ItemAction, on row: TimelineRow) {
        switch action {
        case .openOriginal:
            if let hit = ItemMenu.original(of: row) { perform(hit) }
        case .openThread:
            openThread(row)
        case .openAuthor:
            if let url = RowText.profileURL(row) { UIApplication.shared.open(url) }
        case .bookmark:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task {
                if let message = await interactions.toggle(.bookmark, on: row) { showNotice(message) }
            }
        case .copyLink:
            guard let url = ItemMenu.originalURL(row) else { return }
            UIPasteboard.general.url = url
        case .copyText:
            UIPasteboard.general.string = ItemMenu.text(of: row)
        case .share:
            guard presentedViewController == nil, let url = ItemMenu.originalURL(row) else { return }
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let frame = timeline.visibleFrame(of: row) {
                sheet.popoverPresentationController?.sourceView = collectionView
                sheet.popoverPresentationController?.sourceRect = frame
            }
            present(sheet, animated: true)
        }
    }

    private func setUpNotice() {
        notice.font = .preferredFont(forTextStyle: .footnote)
        notice.adjustsFontForContentSizeCategory = true
        notice.numberOfLines = 0
        notice.textAlignment = .center
        notice.textColor = Broadsheet.paper
        notice.backgroundColor = Broadsheet.ink
        notice.layer.cornerRadius = 12
        notice.layer.masksToBounds = true
        notice.isHidden = true
        notice.accessibilityIdentifier = "action-notice"
        notice.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            notice.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
            notice.bottomAnchor.constraint(equalTo: unreadPill.topAnchor, constant: -12),
        ])
    }

    /// Shows `message` over the timeline for a few seconds; it never
    /// blocks the timeline.
    private func showNotice(_ message: String) {
        notice.text = "  \(message)  "
        notice.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
        noticeHide?.cancel()
        noticeHide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice.isHidden = true
        }
    }

    // MARK: - Pull to refresh

    // The newest rows are at the bottom, so refreshing is a pull
    // up past the last row, where UIRefreshControl can't go. The sync mark
    // sits in the space below the last row, never over a row, and while a
    // refresh runs a bottom inset holds that space open, as
    // UIRefreshControl's does at the top. It draws itself in as the reader
    // pulls, circles while the refresh and sync run, and then rests.

    /// How far past the newest row a drag must end to refresh.
    private static let pullDistance: CGFloat = 72
    /// The space below the last row the mark sits in.
    private static let indicatorSpace: CGFloat = 56
    private static let markSize: CGFloat = 32

    private func setUpPullToRefresh() {
        // An empty or short timeline must still bounce to be pulled.
        collectionView.alwaysBounceVertical = true
        // VoiceOver can't pull past the end, so Refresh is also an action,
        // as are the Timeline menu's jumps for anyone without a keyboard.
        collectionView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Refresh") { [weak self] _ in
                self?.refreshFromPull()
                return true
            },
            UIAccessibilityCustomAction(name: "Jump to Newest") { [weak self] _ in
                self?.timeline.jumpToNewest()
                return true
            },
            UIAccessibilityCustomAction(name: "Jump to Marker") { [weak self] _ in
                self?.timeline.jumpToMarker()
                return true
            },
            UIAccessibilityCustomAction(name: "Jump Back") { [weak self] _ in
                guard let self, self.timeline.canJumpBack else { return false }
                self.timeline.jumpBack()
                return true
            },
        ]
    }

    /// How far the reader has dragged past the newest row.
    private var pastNewestEdge: CGFloat {
        let insets = collectionView.adjustedContentInset
        // A timeline shorter than the screen ends where the screen does.
        let end = max(collectionView.contentSize.height + insets.bottom, collectionView.bounds.height - insets.top)
        return collectionView.contentOffset.y + collectionView.bounds.height - end
    }

    /// The mark, made the first time it's needed: most launches never pull.
    private func makePullMark() -> PullRingView {
        if let pullMarkView { return pullMarkView }
        let host = UIHostingController(rootView: PullRefreshMark(state: pullRefresh))
        host.sizingOptions = []
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        addChild(host)
        let mark = PullRingView(size: Self.markSize, refreshView: host.view)
        mark.accessibilityIdentifier = "refresh-indicator"
        // In the collection view, so it scrolls with the rows it sits below.
        collectionView.addSubview(mark)
        host.didMove(toParent: self)
        pullMarkView = mark
        placeRefreshIndicator()
        return mark
    }

    /// Centres the mark in the space just below the last row.
    private func placeRefreshIndicator() {
        guard collectionView != nil, let pullMarkView else { return }
        let center = CGPoint(x: collectionView.bounds.midX, y: collectionView.contentSize.height + Self.indicatorSpace / 2)
        if pullMarkView.center != center { pullMarkView.center = center }
    }

    /// Fills the ring as the reader pulls, whole (and in ink) once letting
    /// go would refresh.
    private func showPullProgress() {
        guard !isPullRefreshing else { return }
        let past = collectionView.isTracking ? pastNewestEdge : 0
        let pull = min(1, max(0, past / Self.pullDistance))
        guard pull > 0 || pullMarkView != nil else { return }
        let mark = makePullMark()
        // Visible as soon as the pull starts; the drawing shows how far.
        let alpha: CGFloat = pull > 0 ? 1 : 0
        if alpha != mark.alpha { mark.alpha = alpha }
        mark.setPull(pull)
    }

    private func refreshFromPull() {
        guard !isPullRefreshing else { return }
        isPullRefreshing = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let mark = makePullMark()
        mark.alpha = 1
        mark.setPull(1)
        pullRefresh.phase = .syncing
        mark.showsRefresh = true
        collectionView.contentInset.bottom += Self.indicatorSpace
        let sync = app.sync
        // A pull syncs too, so the ring shows iCloud as well as the feeds.
        sync?.tapped()
        Task { [weak self, app] in
            let began = ContinuousClock.now
            await app.refreshNow()
            // Chasing until the sync lands, for a little while at most.
            while let sync, sync.status.isCatchingUp, ContinuousClock.now - began < .seconds(10) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            // At least one turn of the chase, so a quick refresh isn't a flicker.
            let shown = ContinuousClock.now - began
            if shown < .milliseconds(1_200) { try? await Task.sleep(for: .milliseconds(1_200) - shown) }
            guard let self else { return }
            // A sync still going after the wait isn't shown as done: the
            // space closes on the chasing arcs, and the bar's mark goes on.
            if sync?.status.isCatchingUp != true {
                let failed: Bool
                if case .failed? = sync?.status.phase { failed = true } else { failed = false }
                let end: RingMark.Phase = failed ? .failed : .synced
                pullRefresh.phase = end
                // The ring settles, and stays a moment before the space closes.
                let settle = RingMark.settleTime(end, reduceMotion: UIAccessibility.isReduceMotionEnabled) ?? 1
                try? await Task.sleep(for: .seconds(settle + (failed ? 1.2 : 0.4)))
            }
            isPullRefreshing = false
            UIView.animate(withDuration: 0.2) {
                mark.alpha = 0
                self.collectionView.contentInset.bottom -= Self.indicatorSpace
                // A reader still in the space comes back to the last row.
                // Mid-fling the scroll view settles itself, and setting the
                // offset would stop the fling.
                guard !self.isScrolling else { return }
                let insets = self.collectionView.adjustedContentInset
                let maxOffset = max(-insets.top, self.collectionView.contentSize.height - self.collectionView.bounds.height + insets.bottom)
                if self.collectionView.contentOffset.y > maxOffset {
                    self.collectionView.contentOffset.y = maxOffset
                }
            } completion: { _ in
                // Ready to draw in again on the next pull, unless one began.
                guard !self.isPullRefreshing else { return }
                self.pullRefresh.phase = nil
                mark.showsRefresh = false
            }
        }
    }

    // MARK: - Unread pill

    private func setUpUnreadPill() {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = Broadsheet.ink
        configuration.baseForegroundColor = Broadsheet.paper
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        unreadPill.configuration = configuration
        unreadPill.isHidden = true
        unreadPill.accessibilityIdentifier = "unread-pill"
        unreadPill.accessibilityHint = "Jumps to the newest posts."
        unreadPill.addAction(UIAction { [weak self] _ in self?.timeline.jumpToNewest() }, for: .primaryActionTriggered)
        unreadPill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(unreadPill)
        NSLayoutConstraint.activate([
            unreadPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            unreadPill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Scroll diagnostics

    private func setUpDiagnostics() {
        let hud = UILabel()
        hud.numberOfLines = 0
        hud.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        hud.textColor = .white
        hud.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        hud.layer.cornerRadius = 8
        hud.layer.masksToBounds = true
        hud.isUserInteractionEnabled = true
        hud.accessibilityIdentifier = "hitch-hud"
        hud.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(resetDiagnostics)))
        hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud)
        self.hud = hud
        var constraints = [
            hud.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            // Top left, clear of the Sources button at the top right.
            hud.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
        ]

        if let addSampleRows = app.addSampleRows {
            var configuration = UIButton.Configuration.filled()
            configuration.title = "+20"
            configuration.cornerStyle = .capsule
            configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.72)
            let add = UIButton(configuration: configuration)
            add.accessibilityIdentifier = "add-newer"
            add.addAction(UIAction { _ in Task { await addSampleRows() } }, for: .primaryActionTriggered)
            add.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(add)
            constraints += [
                add.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
                add.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            ]
        }
        NSLayoutConstraint.activate(constraints)

        let monitor = HitchMonitor { [weak self] text in self?.hud?.text = text }
        timeline.monitor = monitor
        monitor.start()
    }

    @objc private func resetDiagnostics() {
        timeline.resetDiagnostics()
    }
}

/// The timeline's collection view. It notes when an assistive technology
/// or a hardware keyboard scrolls it, since those scrolls are the reader's
/// but involve no touch.
final class TimelineCollectionView: UICollectionView {
    private var readerInputUntil = ContinuousClock.now

    var handledReaderInputRecently: Bool { ContinuousClock.now < readerInputUntil }

    /// Long enough for the animated page scroll that follows.
    private func noteReaderInput() {
        readerInputUntil = .now + .milliseconds(700)
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        // Not under the "Syncing in Progress" screen.
        guard !SyncingGate.holdsTimeline else { return false }
        noteReaderInput()
        return super.accessibilityScroll(direction)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key.map { Self.scrollingKeys.contains($0.keyCode) } ?? false }) {
            guard !SyncingGate.holdsTimeline else { return }
            noteReaderInput()
        }
        super.pressesBegan(presses, with: event)
    }

    private static let scrollingKeys: Set<UIKeyboardHIDUsage> = [
        .keyboardUpArrow, .keyboardDownArrow, .keyboardPageUp, .keyboardPageDown,
        .keyboardHome, .keyboardEnd, .keyboardSpacebar,
    ]
}
