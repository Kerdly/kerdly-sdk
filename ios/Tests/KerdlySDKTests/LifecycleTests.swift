import XCTest
import UIKit
@testable import KerdlySDK

/// Opens, background flushes, ATT, consent, IDFA, context.
final class LifecycleTests: XCTestCase {
    func testForegroundAfterThirtyMinutesIsAnOpen() {
        let h = Harness()
        h.configure()
        h.lifecycle.send(.didEnterBackground)
        h.settle()
        h.clock.advance(29 * 60)
        h.lifecycle.send(.willEnterForeground)
        h.settle()
        XCTAssertEqual(h.queuedEvents.filter { $0.name == "$open" }.count, 1)
        h.lifecycle.send(.didEnterBackground)
        h.settle()
        h.clock.advance(30 * 60)
        h.lifecycle.send(.willEnterForeground)
        h.settle()
        let opens = h.queuedEvents.filter { $0.name == "$open" }
        XCTAssertEqual(opens.map { $0.props["reason"] }, [.string("launch"), .string("foreground")])
    }

    func testBackgroundFlushesUnderABackgroundTask() {
        let h = Harness()
        h.serveAcceptAll()
        h.configure()
        h.core.apiTrack("registration", properties: [:])
        h.settle()
        XCTAssertTrue(h.queuedEvents.contains { $0.name == "registration" }, "a custom event waits for a trigger")
        h.lifecycle.send(.didEnterBackground)
        h.settle()
        XCTAssertTrue(h.queuedEvents.isEmpty)
        XCTAssertEqual(h.lifecycle.begun.get(), 1)
        XCTAssertEqual(h.lifecycle.ended.get(), [1], "the background task ends once the flush is done")
    }

    func testTwentyQueuedEventsAndTheForegroundTimerFlush() {
        let h = Harness()
        h.serveAcceptAll()
        h.configure()
        let before = h.transport.requests(path: "/v1/sdk/batch").count
        for i in 0..<19 { h.core.apiTrack("e\(i)", properties: [:]) }
        h.settle()
        XCTAssertEqual(h.transport.requests(path: "/v1/sdk/batch").count, before)
        h.core.apiTrack("e19", properties: [:])
        h.settle()
        XCTAssertEqual(h.transport.requests(path: "/v1/sdk/batch").count, before + 1, "20 queued events flush")
        h.core.apiTrack("late", properties: [:])
        h.settle()
        h.scheduler.fire { $0 == 15 }
        h.settle()
        XCTAssertTrue(h.queuedEvents.isEmpty, "the 15 s foreground timer flushed it")
    }

    func testAttChangesEmitConsentAndAnAuthorizedIdfa() throws {
        let h = Harness()
        h.serveAcceptAll()
        h.configure()
        XCTAssertFalse(h.transport.sentEvents.contains { $0["name"] == .string("$consent") }, "the first status is silent")
        XCTAssertEqual(h.advertisingId.calls.get(), 0, "no IDFA without ATT")
        h.tracking.current.set(.authorized)
        h.lifecycle.send(.didBecomeActive)
        h.settle()
        let consent = try XCTUnwrap(h.transport.sentEvents.last { $0["name"] == .string("$consent") })
        XCTAssertEqual(consent["props"], .object(["att": .string("authorized"), "analytics": .bool(true), "ads": .bool(true)]))
        let ids = h.transport.sentEvents.filter { $0["props"]?["kind"] == .string("advertising_ids") }
        XCTAssertEqual(ids.first?["props"], .object(["kind": .string("advertising_ids"),
                                                    "idfa": .string("6D92078A-8246-4BA4-AE5B-76104861E7DC")]))
        // The same IDFA is not sent twice; consent ads=false stops reading it.
        h.lifecycle.send(.didBecomeActive)
        h.core.apiSetConsent(analytics: nil, ads: false)
        h.settle()
        XCTAssertEqual(h.transport.sentEvents.filter { $0["props"]?["kind"] == .string("advertising_ids") }.count, 1)
        let reads = h.advertisingId.calls.get()
        h.advertisingId.idfa.set("11111111-2222-4333-8444-555555555555")
        h.tracking.current.set(.denied)
        h.lifecycle.send(.didBecomeActive)
        h.tracking.current.set(.authorized)
        h.lifecycle.send(.didBecomeActive)
        h.settle()
        XCTAssertEqual(h.advertisingId.calls.get(), reads, "ads consent off: never read")
        XCTAssertEqual(h.batchesContext(att: "authorized"), true)
    }

    func testContextIsResentOnlyWhenItChanges() {
        let h = Harness()
        h.serveAcceptAll()
        h.configure()
        h.core.apiSetUserId("u1")
        h.core.apiFlush()
        h.settle()
        let batches = h.transport.batches
        XCTAssertNotNil(batches.first?["context"])
        XCTAssertNil(batches.last?["context"], "unchanged since the last acked batch")
        h.core.apiSetConsent(analytics: true, ads: false)
        h.settle()
        XCTAssertEqual(h.transport.batches.last?["context"]?["consent"]?["ads"], .bool(false))
    }

    func testContextHelpers() {
        XCTAssertEqual(ContextBuilder.localeIdentifier("en_US@calendar=japanese"), "en_US")
        XCTAssertEqual(ContextBuilder.localeIdentifier("es_MX"), "es_MX")
        XCTAssertEqual(ContextBuilder.osVersion(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 1)), "26.0.1")
        XCTAssertEqual(ContextBuilder.osVersion(OperatingSystemVersion(majorVersion: 18, minorVersion: 5, patchVersion: 0)), "18.5")
        let facts = DeviceFacts(os: "26.0", model: "iPhone17,1", locale: "en_US",
                                languages: ["a", "b", "c", "d", "e", "f"], timeZone: "UTC")
        let context = ContextBuilder.context(facts: facts, snapshot: nil, att: .denied, analytics: true, ads: true,
                                             app: AppInfo(bundle: "b", version: "1", build: "2"))
        XCTAssertNil(context["idfv"])
        XCTAssertNil(context["screen"])
        XCTAssertNil(context["lat"], "Android only")
        XCTAssertEqual(context["languages"]?.arrayValue?.count, 5)
    }

    func testAttributionIsPolledAtMostThreeTimesAfterAnInstall() throws {
        let h = Harness()
        h.serveAcceptAll()
        h.configure()
        h.scheduler.fire { [10, 30, 55].contains($0) }
        h.settle()
        h.scheduler.fire { [10, 30, 55].contains($0) }
        h.settle()
        let polls = h.transport.requests(path: "/v1/sdk/attribution")
        XCTAssertEqual(polls.count, 3)
        let id = try XCTUnwrap(h.core.installIdBox.get())
        XCTAssertEqual(polls.first?.url.query, "install_id=\(id)")

        let known = Harness()
        let attribution = try Fixtures.json("batch.response.json")["attribution"]!
        known.transport.respond = { request in
            if request.url.path.hasSuffix("/v1/sdk/attribution") {
                return .response(status: 200, headers: [:], body: KerdlyJSON.encode(JSONValue.object(["attribution": attribution]))!)
            }
            return Harness.batchResponse(accepted: request.body.flatMap(JSONValue.parse)?["events"]?.arrayValue?
                .compactMap { $0["id"]?.stringValue } ?? [])
        }
        known.configure()
        for offset in [10.0, 30.0, 55.0] {   // 10, 30 and 55 s after configure, one at a time
            known.scheduler.fire { $0 == offset }
            known.settle()
        }
        XCTAssertEqual(known.transport.requests(path: "/v1/sdk/attribution").count, 1, "polling stops once known")
        XCTAssertEqual(known.core.apiAttribution?.network, "meta")
    }

    // MARK: ATT prompter

    @MainActor
    func testThePrompterWaitsUntilTheAppIsActive() {
        let tracking = FakeTracking()
        let center = NotificationCenter()
        var active = false
        let decided = expectation(description: "decision")
        let prompter = TrackingPrompter(tracking: tracking, center: center, isActive: { active },
                                        log: KerdlyLogger(), releaseAfter: 30, onDecision: { status in
            XCTAssertEqual(status, .authorized)
            decided.fulfill()
        })
        var results: [KerdlyAttStatus] = []
        prompter.request { results.append($0) }
        XCTAssertEqual(tracking.requests.get(), 0, "not active: no request yet")
        XCTAssertTrue(prompter.isArmed)
        active = true
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        wait(for: [decided], timeout: 2)
        XCTAssertEqual(tracking.requests.get(), 1)
        XCTAssertEqual(results, [.authorized])
    }

    @MainActor
    func testThePrompterReleasesAWaitingCallerButStaysArmed() {
        let tracking = FakeTracking()
        let center = NotificationCenter()
        let prompter = TrackingPrompter(tracking: tracking, center: center, isActive: { false },
                                        log: KerdlyLogger(), releaseAfter: 0.05, onDecision: { _ in })
        let released = expectation(description: "released")
        prompter.request { status in
            XCTAssertEqual(status, .notDetermined)
            released.fulfill()
        }
        wait(for: [released], timeout: 2)
        XCTAssertTrue(prompter.isArmed, "the dialog still appears once the app is active")
        XCTAssertEqual(tracking.requests.get(), 0)
    }

    @MainActor
    func testThePrompterNeverAsksWithoutAUsageDescriptionOrADecisionOnFile() {
        let tracking = FakeTracking()
        tracking.promptable.set(false)
        let prompter = TrackingPrompter(tracking: tracking, isActive: { true }, log: KerdlyLogger(), onDecision: { _ in })
        var results: [KerdlyAttStatus] = []
        prompter.request { results.append($0) }
        tracking.promptable.set(true)
        tracking.current.set(.denied)
        prompter.request { results.append($0) }
        XCTAssertEqual(results, [.notDetermined, .denied])
        XCTAssertEqual(tracking.requests.get(), 0)
    }
}

extension Harness {
    /// Whether the last batch with a context carried this ATT status.
    func batchesContext(att: String) -> Bool {
        transport.batches.last { $0["context"] != nil }?["context"]?["att"] == .string(att)
    }
}
