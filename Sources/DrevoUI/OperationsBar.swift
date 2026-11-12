import AppKit
import DrevoCore

/// Bottom bar listing running copies/moves with progress and Stop. Hidden when idle;
/// appears only for transfers that take longer than a moment.
@MainActor
final class OperationsBar: NSView {
    private let operations: OperationsCenter
    private let stack = NSStackView()
    private var rows: [UUID: Row] = [:]
    private var observer: NSObjectProtocol?
    private var heightConstraint: NSLayoutConstraint!
    static let showDelay: TimeInterval = 0.35

    init(operations: OperationsCenter) {
        self.operations = operations
        super.init(frame: .zero)
        let top = NSBox()
        top.boxType = .separator
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        for v in [top, stack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        isHidden = true
        observer = NotificationCenter.default.addObserver(forName: OperationsCenter.jobsDidChange, object: operations, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func refresh() {
        let jobs = operations.jobs
        let ids = Set(jobs.map(\.id))
        for (id, row) in rows where !ids.contains(id) {
            stack.removeView(row)
            rows[id] = nil
        }
        for job in jobs {
            let row = rows[job.id] ?? {
                let r = Row(job: job)
                rows[job.id] = r
                stack.addArrangedSubview(r)
                r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                return r
            }()
            row.update()
        }
        if jobs.isEmpty {
            isHidden = true
        } else if isHidden {
            // Quick operations finish before the bar would flash.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay) { [weak self] in
                guard let self, !self.operations.jobs.isEmpty else { return }
                self.isHidden = false
            }
        }
    }

    final class Row: NSView {
        let job: TransferJob
        private let title = NSTextField(labelWithString: "")
        private let detail = NSTextField(labelWithString: "")
        private let bar = NSProgressIndicator()
        private let stop = NSButton()

        init(job: TransferJob) {
            self.job = job
            super.init(frame: .zero)
            title.font = .systemFont(ofSize: 11, weight: .medium)
            title.lineBreakMode = .byTruncatingMiddle
            detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            detail.textColor = .secondaryLabelColor
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.controlSize = .small
            stop.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Stop")
            stop.isBordered = false
            stop.contentTintColor = .secondaryLabelColor
            stop.target = self
            stop.action = #selector(stopClicked)
            stop.toolTip = "Stop"
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            for v in [title, bar, detail, stop] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                addSubview(v)
            }
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 20),
                title.leadingAnchor.constraint(equalTo: leadingAnchor),
                title.centerYAnchor.constraint(equalTo: centerYAnchor),
                title.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.4),
                bar.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
                bar.centerYAnchor.constraint(equalTo: centerYAnchor),
                bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
                detail.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 10),
                detail.centerYAnchor.constraint(equalTo: centerYAnchor),
                detail.widthAnchor.constraint(equalToConstant: 170),
                stop.leadingAnchor.constraint(equalTo: detail.trailingAnchor, constant: 6),
                stop.trailingAnchor.constraint(equalTo: trailingAnchor),
                stop.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func update() {
            let p = job.progress
            title.stringValue = job.title
            bar.doubleValue = p.fraction
            if p.totalBytes > 0 {
                detail.stringValue = "\(Formatting.size(p.completedBytes)) of \(Formatting.size(p.totalBytes))"
            } else {
                detail.stringValue = "\(p.completedItems) of \(p.totalItems)"
            }
            toolTip = p.currentName
        }

        @objc private func stopClicked() {
            job.cancel()
        }
    }
}
