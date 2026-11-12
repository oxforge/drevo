import Foundation

/// Runs `block` on the main thread through the main run loop (in order), so it also runs
/// while something spins a nested run loop (modal sessions, tests).
nonisolated func onMainRunLoop(_ block: @escaping @MainActor () -> Void) {
    let main = CFRunLoopGetMain()
    CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
        MainActor.assumeIsolated { block() }
    }
    CFRunLoopWakeUp(main)
}
