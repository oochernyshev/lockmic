import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "AudioHAL")

/// Core Audio Start/Stop/Destroy must not run on main, an IO-proc queue, or the
/// recording state queue — HAL can `dispatch_sync` onto those and deadlock.
/// Each tap/capture has its own serial halt queue so one hung Destroy cannot
/// block Start on a different device.
enum AudioHAL {
    static let startSeconds: TimeInterval = 8
    static let haltSeconds: TimeInterval = 4

    /// Run `body` on `queue`. Returns `nil` if `body` has not finished by `timeout`.
    /// A timed-out `body` is left running; the object should be abandoned.
    static func run<T>(
        on queue: DispatchQueue,
        timeout: TimeInterval,
        _ body: @escaping () -> T
    ) async -> T? {
        await withCheckedContinuation { continuation in
            let gate = ResumeOnce<T?>()
            queue.async {
                let value = body()
                gate.resume(value, continuation)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if gate.resume(nil, continuation) {
                    log.error("HAL call timed out after \(Int(timeout), privacy: .public)s")
                }
            }
        }
    }

    /// Fire-and-forget HAL teardown. Safe from main, IO, and the recording queue.
    static func haltAsync(on queue: DispatchQueue, _ body: @escaping () -> Void) {
        queue.async(execute: body)
    }
}

/// Resumes a continuation at most once.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    @discardableResult
    func resume(_ value: T, _ continuation: CheckedContinuation<T, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        continuation.resume(returning: value)
        return true
    }
}
