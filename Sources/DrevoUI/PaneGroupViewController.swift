import AppKit
import DrevoCore

/// The panes side by side, which one is active, and which one receives copies.
@MainActor
final class PaneGroupViewController: NSViewController, NSSplitViewDelegate {
    let env: AppEnvironment
    weak var dispatcher: CommandDispatching?
    var onActivePaneChange: ((PaneViewController) -> Void)?
    var onPaneChange: ((PaneViewController) -> Void)?

    private(set) var panes: [PaneViewController] = []
    private(set) var activeIndex = 0
    /// The pane that was active before the current one (D13).
    private var previousIndex: Int?
    private let splitView = NSSplitView()
    private var didInitialLayout = false

    init(directories: [URL], viewModes: [ViewMode], sorts: [FileSort] = [], env: AppEnvironment) {
        self.env = env
        super.init(nibName: nil, bundle: nil)
        for (i, dir) in directories.enumerated() {
            let mode = i < viewModes.count ? viewModes[i] : env.preferences.defaultViewMode
            panes.append(makePane(directory: dir, mode: mode, sort: i < sorts.count ? sorts[i] : FileSort()))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        for pane in panes {
            addChild(pane)
            splitView.addArrangedSubview(pane.view)
        }
        view = splitView
        updateActiveState()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didInitialLayout, splitView.bounds.width > 0 {
            didInitialLayout = true
            equalizeWidths()
        }
    }

    private func makePane(directory: URL, mode: ViewMode, sort: FileSort = FileSort()) -> PaneViewController {
        let pane = PaneViewController(directory: directory, viewMode: mode, sort: sort, env: env)
        pane.dispatcher = dispatcher
        pane.onActivate = { [weak self] p in self?.activate(p, focus: false) }
        pane.onChange = { [weak self] p in self?.onPaneChange?(p) }
        return pane
    }

    func setDispatcher(_ d: CommandDispatching) {
        dispatcher = d
        panes.forEach { $0.dispatcher = d }
    }

    // MARK: Active / target

    var activePane: PaneViewController { panes[activeIndex] }

    /// Where Copy/Move to Other Pane goes; nil with a single pane.
    var targetPane: PaneViewController? {
        guard panes.count > 1 else { return nil }
        if let p = previousIndex, p != activeIndex, p < panes.count { return panes[p] }
        return panes[(activeIndex + 1) % panes.count]
    }

    func activate(_ pane: PaneViewController, focus: Bool) {
        guard let i = panes.firstIndex(where: { $0 === pane }) else { return }
        if i != activeIndex {
            previousIndex = activeIndex
            activeIndex = i
            updateActiveState()
            onActivePaneChange?(pane)
        }
        if focus { pane.focus() }
    }

    func activate(index: Int) {
        guard panes.indices.contains(index) else { return }
        activate(panes[index], focus: true)
    }

    private func updateActiveState() {
        let target = targetPane
        for (i, p) in panes.enumerated() {
            p.isActive = i == activeIndex
            p.header.badgeText = panes.count > 2 && p === target ? "TARGET" : nil
        }
    }

    // MARK: Pane commands

    func perform(_ id: CommandID) -> Bool {
        switch id {
        case .nextPane:
            activate(index: (activeIndex + 1) % panes.count)
        case .previousPane:
            activate(index: (activeIndex - 1 + panes.count) % panes.count)
        case .swapPanes:
            swapWithTarget()
        case .openInOtherPane:
            openInOtherPane()
        case .addPane:
            addPane()
        case .removePane:
            removeActivePane()
        case .copyToOtherPane:
            transferToTarget(.copy)
        case .moveToOtherPane:
            transferToTarget(.move)
        default:
            return false
        }
        return true
    }

    /// Swap folders (and view modes) of the active pane and its target; focus stays put.
    private func swapWithTarget() {
        guard let target = targetPane else { return }
        let a = activePane
        let (aDir, bDir) = (a.currentDirectory, target.currentDirectory)
        let (aMode, bMode) = (a.viewMode, target.viewMode)
        a.setViewMode(bMode)
        target.setViewMode(aMode)
        a.navigate(to: bDir)
        target.navigate(to: aDir)
        a.focus()
    }

    /// The selected folder (or the current folder) opens in the target pane.
    private func openInOtherPane() {
        guard let target = targetPane else { return }
        let a = activePane
        let folder = a.selectedItems.count == 1 && a.selectedItems[0].isContainer ? a.selectedItems[0].url : a.currentDirectory
        target.navigate(to: folder)
    }

    /// F5/F6: the active pane's selection into the target pane's folder.
    func transferToTarget(_ kind: TransferKind) {
        let source = activePane
        let urls = source.selectedItems.map(\.url)
        guard !urls.isEmpty else { NSSound.beep(); return }
        let target = targetPane
        let proposed = target?.currentDirectory ?? source.currentDirectory
        let window = view.window
        let run: (URL) -> Void = { [weak self] dest in
            guard let self else { return }
            guard dest.isDirectoryOnDisk else {
                self.env.operations.prompts.showError("“\(dest.path)” isn’t a folder.", detail: nil, in: window)
                return
            }
            self.env.operations.transfer(kind, urls, to: dest, window: window) { result in
                // Show the results where they landed; keep focus where it was.
                for pane in self.panes where FileIdentity.sameItem(pane.currentDirectory, dest) {
                    pane.reload(selectingResults: result.outputs)
                }
                source.reload()
            }
        }
        if env.preferences.confirmTransfers || target == nil {
            env.operations.prompts.askDestination(kind: kind, count: urls.count, proposed: proposed, base: source.currentDirectory, in: window) { dest in
                if let dest { run(dest) }
                source.focus()
            }
        } else {
            run(proposed)
        }
    }

    func addPane() {
        guard panes.count < 4 else { return }
        let pane = makePane(directory: activePane.currentDirectory, mode: activePane.viewMode, sort: activePane.sort)
        panes.append(pane)
        addChild(pane)
        splitView.addArrangedSubview(pane.view)
        equalizeWidths()
        activate(pane, focus: true)
        env.preferences.paneCount = panes.count
    }

    func removeActivePane() {
        guard panes.count > 1 else { return }
        let pane = activePane
        pane.view.removeFromSuperview()
        pane.removeFromParent()
        panes.remove(at: activeIndex)
        previousIndex = nil
        activeIndex = min(activeIndex, panes.count - 1)
        equalizeWidths()
        updateActiveState()
        activePane.focus()
        onActivePaneChange?(activePane)
        env.preferences.paneCount = panes.count
    }

    func equalizeWidths() {
        splitView.layoutSubtreeIfNeeded()
        let total = splitView.bounds.width - splitView.dividerThickness * CGFloat(panes.count - 1)
        guard total > 0 else { return }
        let w = total / CGFloat(panes.count)
        for i in 0..<(panes.count - 1) {
            splitView.setPosition(w * CGFloat(i + 1) + splitView.dividerThickness * CGFloat(i), ofDividerAt: i)
        }
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMinimumPosition + 220
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMaximumPosition - 220
    }
}
