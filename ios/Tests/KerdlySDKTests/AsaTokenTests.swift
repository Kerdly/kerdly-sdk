import XCTest
@testable import KerdlySDK

/// The AdServices token: a round of tries on each launch and foreground until one is sent, while
/// the install's attribution can still change.
final class AsaTokenTests: XCTestCase {
    private func tokens(_ h: Harness) -> [Int64] {
        h.transport.sentEvents
            .filter { $0["props"]?["kind"] == .string("asa_token") }
            .compactMap { $0["props"]?["attempt"]?.int64Value }
    }

    /// Runs the round's two scheduled retries.
    private func finishRound(_ h: Harness) {
        for _ in 0..<2 {
            h.scheduler.fire { $0 == KerdlyCore.asaRetryDelay }
            h.settle()
        }
    }

    func testARoundThatFailsLeavesTheTokenWantedAndAForegroundTriesAgain() {
        let h = Harness()
        h.serveAcceptAll()
        h.adServices.token.set(nil)
        h.configure()
        finishRound(h)
        XCTAssertEqual(h.adServices.calls.get(), 3, "three tries, 15 s apart")
        XCTAssertTrue(h.state.asaDue, "a failed round no longer gives up for good")

        h.adServices.token.set("eyJ0b2tlbiI6Imxhc3QifQ==")
        h.lifecycle.send(.willEnterForeground)
        h.settle()
        XCTAssertEqual(h.adServices.calls.get(), 4)
        XCTAssertEqual(tokens(h), [1])
        XCTAssertFalse(h.state.asaDue)

        h.lifecycle.send(.willEnterForeground)
        h.settle()
        XCTAssertEqual(h.adServices.calls.get(), 4, "nothing more once a token is sent")
    }

    func testAForegroundDuringARoundDoesNotStartAnother() {
        let h = Harness()
        h.serveAcceptAll()
        h.adServices.token.set(nil)
        h.configure()
        XCTAssertEqual(h.adServices.calls.get(), 1)
        h.lifecycle.send(.willEnterForeground)
        h.settle()
        XCTAssertEqual(h.adServices.calls.get(), 2, "the foreground adds one try to the round")
        finishRound(h)
        XCTAssertEqual(h.adServices.calls.get(), 3, "and the round still stops at three failures")
    }

    func testALaterLaunchTriesAgainWithin48HoursAndNotAfter() {
        let keychain = FakeKeychain(), defaults = FakeDefaults(), files = InMemoryFiles()
        let first = Harness(keychain: keychain, defaults: defaults, files: files)
        first.serveAcceptAll()
        first.adServices.token.set(nil)
        first.configure()
        finishRound(first)
        XCTAssertEqual(first.adServices.calls.get(), 3)

        let next = Harness(keychain: keychain, defaults: defaults, files: files)
        next.serveAcceptAll()
        next.adServices.token.set(nil)
        next.clock.advance(3_600)
        next.configure()
        finishRound(next)
        XCTAssertEqual(next.adServices.calls.get(), 3, "a fresh round on the next launch")
        XCTAssertTrue(next.state.asaDue)

        let late = Harness(keychain: keychain, defaults: defaults, files: files)
        late.serveAcceptAll()
        late.clock.advance(49 * 3_600)
        late.configure()
        XCTAssertEqual(late.adServices.calls.get(), 0, "past 48 h a token can't change the attribution")
        XCTAssertFalse(late.state.asaDue)
        XCTAssertEqual(tokens(late), [])
    }
}
