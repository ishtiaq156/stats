import Foundation

/// Retry Bonjour after a first-run permission change or transient network failure.
struct BonjourRetryBackoff {
    private(set) var nextDelay: TimeInterval = 5

    mutating func afterFailure() -> TimeInterval {
        let delay = nextDelay
        nextDelay = min(nextDelay * 2, 60)
        return delay
    }

    mutating func reset() {
        nextDelay = 5
    }
}
