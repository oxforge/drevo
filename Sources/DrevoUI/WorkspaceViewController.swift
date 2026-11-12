import AppKit
import DrevoCore

/// Content area right of the sidebar: panes over a collapsible console, then the bars
/// (operations, command line, key hints).
@MainActor
final class WorkspaceViewController: NSViewController, NSSplitViewDelegate {
    let paneGroup: PaneGroupViewController
    let console = ConsoleViewController()
    let bottomStack = NSStackView()
    private let split = NSSplitView()
    private var consoleHeight: CGFloat = 220

    init(paneGroup: PaneGroupViewController) {
        self.paneGroup = paneGroup
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        addChild(paneGroup)
        addChild(console)
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(paneGroup.view)
        split.addArrangedSubview(console.view)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 260), forSubviewAt: 1)
        console.view.isHidden = true
        bottomStack.orientation = .vertical
        bottomStack.spacing = 0
        bottomStack.alignment = .leading
        bottomStack.distribution = .fill
        for v in [split, bottomStack] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomStack.topAnchor),
            bottomStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    /// Adds a full-width bar at the bottom (in order of calls, top to bottom).
    func addBottomBar(_ bar: NSView) {
        bottomStack.addArrangedSubview(bar)
        bar.widthAnchor.constraint(equalTo: bottomStack.widthAnchor).isActive = true
    }

    var isConsoleVisible: Bool { !console.view.isHidden }

    func setConsoleVisible(_ visible: Bool) {
        guard visible != isConsoleVisible else { return }
        if !visible { consoleHeight = max(120, console.view.frame.height) }
        console.view.isHidden = !visible
        split.adjustSubviews()
        if visible {
            split.layoutSubtreeIfNeeded()
            split.setPosition(max(160, split.bounds.height - consoleHeight), ofDividerAt: 0)
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 160)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.height - 80)
    }
}
