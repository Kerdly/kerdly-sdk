import XCTest
@testable import KerdlySDK

/// Exponential back-off with full jitter, 1 s to 5 min.
final class BackoffTests: XCTestCase {
    let policy = BackoffPolicy()

    func testCeilingDoublesUpToFiveMinutes() {
        XCTAssertEqual(policy.ceiling(attempt: 0), 1)
        XCTAssertEqual(policy.ceiling(attempt: 1), 2)
        XCTAssertEqual(policy.ceiling(attempt: 5), 32)
        XCTAssertEqual(policy.ceiling(attempt: 8), 256)
        XCTAssertEqual(policy.ceiling(attempt: 9), 300)
        XCTAssertEqual(policy.ceiling(attempt: 1_000), 300)
        XCTAssertEqual(policy.ceiling(attempt: -3), 1)
    }

    func testEveryDelayLiesBetweenOneSecondAndFiveMinutes() {
        for attempt in 0...40 {
            for r in stride(from: 0.0, through: 1.0, by: 0.05) {
                let delay = policy.delay(attempt: attempt, unitRandom: r)
                XCTAssertGreaterThanOrEqual(delay, 1, "attempt \(attempt), r \(r)")
                XCTAssertLessThanOrEqual(delay, 300, "attempt \(attempt), r \(r)")
                XCTAssertLessThanOrEqual(delay, max(1, policy.ceiling(attempt: attempt)))
            }
        }
    }

    func testFullJitterSpansTheWholeRange() {
        XCTAssertEqual(policy.delay(attempt: 9, unitRandom: 0), 1, "the floor")
        XCTAssertEqual(policy.delay(attempt: 9, unitRandom: 1), 300, "the cap")
        XCTAssertEqual(policy.delay(attempt: 9, unitRandom: 0.5), 150)
        XCTAssertEqual(policy.delay(attempt: 3, unitRandom: 0.5), 4)
        XCTAssertEqual(policy.delay(attempt: 3, unitRandom: 7), 8, "out-of-range randomness is clamped")
    }

    func testRetriesGrowAcrossConsecutiveFailures() {
        let h = Harness()
        h.configure()
        var deadlines: [Int64] = []
        for _ in 0..<4 {
            h.transport.completeNext(Harness.status(500))
            h.settle()
            deadlines.append((h.state.retryAt ?? 0) - Clocks.ms(Harness.start))
            h.core.apiFlush()   // explicit: skips the client back-off
            h.settle()
        }
        XCTAssertEqual(h.state.backoffAttempt, 4)
        XCTAssertEqual(deadlines, [1_000, 1_000, 2_000, 4_000], "r = 0.5: max(1, 0.5·2^n) s")
    }
}
