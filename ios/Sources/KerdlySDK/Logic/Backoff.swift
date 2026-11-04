import Foundation

/// Exponential back-off with full jitter, 1 s to 5 min. A server `Retry-After` wins
/// over it (see `DeliveryPolicy.retryAfter`).
struct BackoffPolicy: Equatable, Sendable {
    var base: TimeInterval = 1
    var cap: TimeInterval = 300

    /// The ceiling for a 0-based attempt: `min(cap, base × 2^attempt)`.
    func ceiling(attempt: Int) -> TimeInterval {
        let exponent = Double(min(max(attempt, 0), 30))
        return min(cap, base * pow(2, exponent))
    }

    /// A delay drawn uniformly from `[0, ceiling]`, floored at `base`, so it always lies in
    /// `[base, cap]`.
    /// - Parameter unitRandom: a value in `[0, 1]`.
    func delay(attempt: Int, unitRandom: Double) -> TimeInterval {
        let r = min(max(unitRandom, 0), 1)
        return min(cap, max(base, ceiling(attempt: attempt) * r))
    }
}
