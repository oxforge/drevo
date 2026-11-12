import Foundation
import FmanCore

/// A running background operation (copy, move, expand), observed by the operations bar.
@MainActor
final class TransferJob: Identifiable {
    let id = UUID()
    let title: String
    private let cancelHandler: () -> Void
    /// Set by `OperationsCenter` as the work goes on.
    var progress = TransferProgress()

    init(transfer: Transfer) {
        self.title = transfer.title
        self.cancelHandler = { transfer.cancel() }
    }

    init(title: String, cancel: @escaping () -> Void) {
        self.title = title
        self.cancelHandler = cancel
    }

    func cancel() { cancelHandler() }
}
