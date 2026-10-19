import Foundation

/// Tests that launch and drive a real Mac app take turns. They activate apps, watch which app is
/// frontmost and which windows appear, and quit fixture copies, so two at once disturb each other;
/// Swift Testing runs suites in parallel. Take a turn for the whole test:
///
///     await MacAppFixtureTurn.shared.acquire()
///     defer { MacAppFixtureTurn.shared.release() }
final class MacAppFixtureTurn: @unchecked Sendable {
    static let shared = MacAppFixtureTurn()

    private let lock = NSLock()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Waits until no other test holds the turn, then holds it.
    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if busy { waiting.append(continuation); return false }
                busy = true
                return true
            }
            if now { continuation.resume() }
        }
    }

    /// Hands the turn to the next waiting test.
    func release() {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if waiting.isEmpty { busy = false; return nil }
            return waiting.removeFirst()
        }
        next?.resume()
    }
}
