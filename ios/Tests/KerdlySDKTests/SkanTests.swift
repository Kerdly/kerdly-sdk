import XCTest
@testable import KerdlySDK

/// The ladder, rung selection, the monotonic floor and the writer.
final class SkanTests: XCTestCase {
    let firstLaunch = Date(timeIntervalSince1970: 1_760_400_000)
    var timeline: SkanTimeline { SkanTimeline(firstLaunchAt: firstLaunch, installedAt: firstLaunch.addingTimeInterval(-20)) }

    func schema(_ mutate: (inout [String: JSONValue]) -> Void = { _ in }) throws -> SkanSchema {
        var skan = try XCTUnwrap(try Fixtures.json("config.response.json")["skan"]?.objectValue)
        skan["enabled"] = .bool(true)
        mutate(&skan)
        return try XCTUnwrap(SkanSchema.parse(.object(skan)))
    }

    func facts(trial: Bool, purchased: TimeInterval, original: TimeInterval, renewal: Bool? = nil,
               revoked: Bool = false) -> PurchaseFacts {
        PurchaseFacts(isFreeTrial: trial, purchaseDate: firstLaunch.addingTimeInterval(purchased),
                      originalPurchaseDate: firstLaunch.addingTimeInterval(original), isRenewal: renewal, revoked: revoked)
    }

    // MARK: Schema

    func testTheFixtureLadderParses() throws {
        let s = try schema()
        XCTAssertEqual(s.version, 1)
        XCTAssertEqual(s.rungs.map(\.fine), [0, 8, 32, 63])
        XCTAssertEqual(s.rungs.map(\.coarse), [.low, .low, .medium, .high])
        XCTAssertEqual(s.rungs.last?.on, ["purchase", "sweep"])
        XCTAssertFalse(s.lockWindow)
        XCTAssertTrue(s.aakMirror)
    }

    func testInvalidLaddersAreRefused() {
        func ladder(_ rungs: [(String, Int, String)]) -> JSONValue {
            .object(["version": .int(2), "enabled": .bool(true), "rungs": .array(rungs.map {
                .object(["event": .string($0.0), "fine": .int(Int64($0.1)), "coarse": .string($0.2), "on": .array([.string("event")])])
            })])
        }
        XCTAssertNotNil(SkanSchema.parse(ladder([("a", 0, "low"), ("b", 8, "medium")])))
        XCTAssertNil(SkanSchema.parse(ladder([("a", 8, "low"), ("b", 8, "low")])), "fine must increase")
        XCTAssertNil(SkanSchema.parse(ladder([("a", 8, "high"), ("b", 9, "low")])), "coarse must not go down")
        XCTAssertNil(SkanSchema.parse(ladder([("a", 0, "low"), ("b", 64, "low")])), "fine is 0–63")
        XCTAssertNil(SkanSchema.parse(ladder([("a", 0, "low"), ("a", 8, "low")])), "events are unique")
        XCTAssertNil(SkanSchema.parse(ladder([("a", 0, "huge")])), "coarse is low|medium|high")
        XCTAssertNil(SkanSchema.parse(.null))
    }

    // MARK: Rung selection

    func testLaunchWritesTheBaselineOnlyFirstAndEarly() throws {
        let s = try schema()
        XCTAssertEqual(SkanPlanner.rung(for: .launch, schema: s, timeline: timeline, now: firstLaunch, floor: nil)?.fine, 0)
        XCTAssertNil(SkanPlanner.rung(for: .launch, schema: s, timeline: timeline, now: firstLaunch, floor: 0))
        XCTAssertNil(SkanPlanner.rung(for: .launch, schema: s, timeline: timeline,
                                      now: firstLaunch.addingTimeInterval(49 * 3_600), floor: nil),
                     "an app update that brings the SDK to an old install does not write a baseline")
    }

    func testEventRungs() throws {
        let s = try schema()
        XCTAssertEqual(SkanPlanner.rung(for: .event("registration"), schema: s, timeline: timeline, now: firstLaunch, floor: nil)?.fine, 8)
        XCTAssertNil(SkanPlanner.rung(for: .event("$install"), schema: s, timeline: timeline, now: firstLaunch, floor: nil),
                     "the baseline rung fires on launch, not on the event")
        XCTAssertNil(SkanPlanner.rung(for: .event("paywall_view"), schema: s, timeline: timeline, now: firstLaunch, floor: nil))
    }

    func testPurchaseRungs() throws {
        let s = try schema()
        func rung(_ trigger: SkanTrigger) -> Int? {
            SkanPlanner.rung(for: trigger, schema: s, timeline: timeline, now: firstLaunch, floor: nil)?.fine
        }
        XCTAssertEqual(rung(.purchase(facts(trial: true, purchased: 600, original: 600))), 32, "free trial → trial_start")
        XCTAssertEqual(rung(.purchase(facts(trial: false, purchased: 600, original: 600, renewal: false))), 63, "paid → subscribe")
        XCTAssertEqual(rung(.purchase(facts(trial: false, purchased: 259_200, original: 600, renewal: true))), 63,
                       "the trial converting (a renewal of a subscription begun in this install)")
        XCTAssertNil(rung(.purchase(facts(trial: false, purchased: 600, original: -86_400 * 90, renewal: true))),
                     "the renewal of a subscription from before this install is not this install's conversion")
        XCTAssertEqual(rung(.purchase(facts(trial: false, purchased: 600, original: -86_400 * 90, renewal: false))), 63,
                       "a lapsed subscriber buying again in this install")
        XCTAssertNil(rung(.purchase(facts(trial: true, purchased: -86_400, original: -86_400))), "before this install")
        XCTAssertNil(rung(.purchase(facts(trial: false, purchased: 600, original: 600, revoked: true))), "refunded")
    }

    func testSweepOnlyCountsEntitlementsThatBeganAfterThisInstall() throws {
        let s = try schema()
        func rung(_ facts: PurchaseFacts) -> Int? {
            SkanPlanner.rung(for: .sweep(facts), schema: s, timeline: timeline, now: firstLaunch, floor: nil)?.fine
        }
        XCTAssertEqual(rung(facts(trial: false, purchased: 259_200, original: 600)), 63)
        XCTAssertNil(rung(facts(trial: false, purchased: 600, original: -86_400 * 200)),
                     "a returning subscriber's reinstall must not write subscribe (the old app's misfire)")
        XCTAssertNil(rung(facts(trial: true, purchased: 600, original: 600)), "trial_start does not fire on sweep in this ladder")
    }

    func testFloorIsMonotonic() {
        XCTAssertTrue(SkanPlanner.shouldWrite(fine: 0, floor: nil))
        XCTAssertFalse(SkanPlanner.shouldWrite(fine: 8, floor: 8))
        XCTAssertFalse(SkanPlanner.shouldWrite(fine: 8, floor: 32))
        XCTAssertTrue(SkanPlanner.shouldWrite(fine: 63, floor: 32))
    }

    func testWindowsAndTimeline() {
        let start = firstLaunch
        XCTAssertEqual(SkanPlanner.window(since: start, now: start.addingTimeInterval(3_600)), 0)
        XCTAssertEqual(SkanPlanner.window(since: start, now: start.addingTimeInterval(48 * 3_600)), 1)
        XCTAssertEqual(SkanPlanner.window(since: start, now: start.addingTimeInterval(7 * 86_400)), 2)
        XCTAssertNil(SkanPlanner.window(since: start, now: start.addingTimeInterval(35 * 86_400)))
        XCTAssertEqual(SkanTimeline(firstLaunchAt: start, installedAt: start.addingTimeInterval(-60)).start,
                       start.addingTimeInterval(-60))
        XCTAssertEqual(SkanTimeline(firstLaunchAt: start, installedAt: nil).start, start)
    }

    // MARK: Coordinator with a fake writer

    final class Recorder: @unchecked Sendable {
        let audits = Locked<[[String: JSONValue]]>([])
        let floors = Locked<[Int]>([])
    }

    func makeCoordinator(_ writer: FakeSkanWriter, floor: Int? = nil, timeout: TimeInterval = 10)
        -> (SkanCoordinator, DispatchQueue, Recorder) {
        let queue = DispatchQueue(label: "test.skan")
        let recorder = Recorder()
        let now = firstLaunch.addingTimeInterval(60)
        let coordinator = SkanCoordinator(writer: writer, queue: queue, floor: floor, timeout: timeout, now: { now })
        coordinator.onAudit = { props in recorder.audits.update { $0.append(props) } }
        coordinator.onFloorChange = { floor in recorder.floors.update { $0.append(floor) } }
        return (coordinator, queue, recorder)
    }

    func drain(_ queue: DispatchQueue) {
        for _ in 0..<5 { queue.sync {} }
    }

    func testASuccessfulWriteRaisesTheFloorAndIsAudited() throws {
        let writer = FakeSkanWriter()
        let (coordinator, queue, recorder) = makeCoordinator(writer)
        let s = try schema()
        queue.sync { coordinator.submit(.init(trigger: .launch, schema: s, timeline: timeline)) }
        drain(queue)
        XCTAssertEqual(writer.writes.get(), [.init(api: "skan4", fine: 0, coarse: .low, lock: false),
                                             .init(api: "aak", fine: 0, coarse: nil, lock: false)])
        XCTAssertEqual(queue.sync { coordinator.floor }, 0)
        XCTAssertEqual(recorder.floors.get(), [0])
        XCTAssertEqual(recorder.audits.get(), [
            ["fine": .int(0), "coarse": .string("low"), "rung": .string("$install"), "previous": .null,
             "schema_version": .int(1), "window": .int(0), "api": .string("skan4"), "error": .null],
            ["fine": .int(0), "coarse": .null, "rung": .string("$install"), "previous": .null,
             "schema_version": .int(1), "window": .int(0), "api": .string("aak"), "error": .null],
        ])
    }

    func testAnErrorKeepsTheFloorAndIsAuditedWithTheError() throws {
        let writer = FakeSkanWriter()
        writer.skanError.set("SKANErrorDomain 10")
        let (coordinator, queue, recorder) = makeCoordinator(writer, floor: 0)
        let s = try schema()
        queue.sync { coordinator.submit(.init(trigger: .event("registration"), schema: s, timeline: timeline)) }
        drain(queue)
        XCTAssertEqual(queue.sync { coordinator.floor }, 0, "Apple refused: the floor stays")
        XCTAssertTrue(recorder.floors.get().isEmpty)
        XCTAssertEqual(recorder.audits.get().first?["error"], .string("SKANErrorDomain 10"))
        XCTAssertEqual(recorder.audits.get().first?["previous"], .int(0))
        // The refused rung is tried again on its next trigger; once Apple accepts, the floor rises.
        writer.skanError.set(nil)
        queue.sync { coordinator.submit(.init(trigger: .event("registration"), schema: s, timeline: timeline)) }
        drain(queue)
        XCTAssertEqual(queue.sync { coordinator.floor }, 8)
        XCTAssertEqual(writer.writes.get().filter { $0.api == "skan4" }.map(\.fine), [8, 8])
    }

    func testValuesAtOrBelowTheFloorAreNotWritten() throws {
        let writer = FakeSkanWriter()
        let (coordinator, queue, recorder) = makeCoordinator(writer, floor: 32)
        let s = try schema()
        queue.sync {
            coordinator.submit(.init(trigger: .event("registration"), schema: s, timeline: timeline))
            coordinator.submit(.init(trigger: .purchase(facts(trial: true, purchased: 60, original: 60)), schema: s, timeline: timeline))
        }
        drain(queue)
        XCTAssertTrue(writer.writes.get().isEmpty)
        XCTAssertTrue(recorder.audits.get().isEmpty)
    }

    func testWritesAreSerialisedAgainstTheFloor() throws {
        let writer = FakeSkanWriter()
        writer.holdSkan.set(true)
        let (coordinator, queue, _) = makeCoordinator(writer)
        let s = try schema()
        queue.sync {
            coordinator.submit(.init(trigger: .purchase(facts(trial: true, purchased: 60, original: 60)), schema: s, timeline: timeline))
            coordinator.submit(.init(trigger: .event("registration"), schema: s, timeline: timeline))
        }
        drain(queue)
        XCTAssertEqual(writer.writes.get().map(\.fine), [32], "the second waits for the first")
        writer.releaseHeld()
        drain(queue)
        XCTAssertEqual(queue.sync { coordinator.floor }, 32)
        XCTAssertEqual(writer.writes.get().map(\.fine), [32, 32], "skan4 + aak; registration (8) is now below the floor")
        XCTAssertTrue(queue.sync { coordinator.isIdle })
    }

    func testOlderApisAndAMissingMirror() throws {
        let writer = FakeSkanWriter()
        writer.api.set("skan3")
        writer.aakAvailable.set(false)
        let (coordinator, queue, recorder) = makeCoordinator(writer)
        let s = try schema { $0["lock_window"] = .bool(true) }
        queue.sync { coordinator.submit(.init(trigger: .event("registration"), schema: s, timeline: timeline)) }
        drain(queue)
        XCTAssertEqual(writer.writes.get(), [.init(api: "skan3", fine: 8, coarse: nil, lock: true)])
        XCTAssertEqual(recorder.audits.get().count, 1)
        XCTAssertEqual(recorder.audits.get().first?["coarse"], .null, "SKAN 3 has no coarse value")

        let old = FakeSkanWriter()
        old.api.set(nil)
        old.aakAvailable.set(false)
        let (c2, q2, r2) = makeCoordinator(old)
        q2.sync { c2.submit(.init(trigger: .event("registration"), schema: s, timeline: timeline)) }
        drain(q2)
        XCTAssertTrue(r2.audits.get().isEmpty, "below iOS 15.4 nothing is written or audited")
        XCTAssertNil(q2.sync { c2.floor })
    }

    func testAWriteThatNeverCompletesTimesOut() throws {
        let writer = FakeSkanWriter()
        writer.holdSkan.set(true)
        let (coordinator, queue, recorder) = makeCoordinator(writer, timeout: 0.05)
        let s = try schema { $0["aak_mirror"] = .bool(false) }
        queue.sync { coordinator.submit(.init(trigger: .launch, schema: s, timeline: timeline)) }
        Thread.sleep(forTimeInterval: 0.2)
        drain(queue)
        XCTAssertEqual(recorder.audits.get().first?["error"], .string("timeout"))
        XCTAssertNil(queue.sync { coordinator.floor })
        XCTAssertTrue(queue.sync { coordinator.isIdle })
        writer.releaseHeld()   // a late completion is ignored
        drain(queue)
        XCTAssertNil(queue.sync { coordinator.floor })
        XCTAssertEqual(recorder.audits.get().count, 1)
    }

    // MARK: Through the core

    private func skanHarness(enabled: Bool = true, writer: Bool = true) throws -> Harness {
        let h = Harness()
        var config = try Fixtures.json("config.response.json").objectValue!
        var skan = config["skan"]!.objectValue!
        skan["enabled"] = .bool(enabled)
        config["skan"] = .object(skan)
        h.serveAcceptAll(config: .object(config))
        h.configure { $0.skanWriter = writer }
        return h
    }

    func testTheBaselineIsWrittenBeforeTheAdServicesToken() throws {
        let h = Harness()
        var config = try Fixtures.json("config.response.json").objectValue!
        var skan = config["skan"]!.objectValue!
        skan["enabled"] = .bool(true)
        config["skan"] = .object(skan)
        h.serveAcceptAll(config: .object(config))
        h.skanWriter.holdSkan.set(true)
        h.configure { $0.skanWriter = true }
        XCTAssertEqual(h.skanWriter.writes.get().map(\.fine), [0])
        XCTAssertEqual(h.adServices.calls.get(), 0, "the token waits for the baseline write")
        h.skanWriter.releaseHeld()
        h.settle()
        XCTAssertEqual(h.adServices.calls.get(), 1)
        XCTAssertEqual(h.state.skanFloor, 0)
        let audits = h.transport.sentEvents.filter { $0["name"] == .string("$skan") }
        XCTAssertEqual(audits.compactMap { $0["props"]?["api"]?.stringValue }, ["skan4", "aak"])
    }

    func testEventsAndPurchasesDriveTheLadder() throws {
        let h = try skanHarness()
        h.core.apiTrack("registration", properties: [:])
        h.settle()
        XCTAssertEqual(h.state.skanFloor, 8)
        h.storeKit.found.set(PurchaseInfo(
            originalTransactionId: "2000001", transactionId: "2000001", productId: "car_weekly_pro", appAccountToken: nil,
            appTransactionId: nil, purchaseDate: Harness.start.addingTimeInterval(300),
            originalPurchaseDate: Harness.start.addingTimeInterval(300), offerType: "introductory", isFreeTrial: true,
            environment: "Production", isRenewal: false, revoked: false))
        h.core.apiNotifyPurchase(KerdlyPurchase(originalTransactionId: "2000001", transactionId: "2000001"))
        h.settle()
        XCTAssertEqual(h.state.skanFloor, 32)
        // A returning subscriber's old entitlement in the sweep does not write subscribe.
        h.storeKit.entitlements.set([PurchaseInfo(
            originalTransactionId: "1000001", transactionId: "1000009", productId: "car_monthly", appAccountToken: nil,
            appTransactionId: nil, purchaseDate: Harness.start.addingTimeInterval(-86_400),
            originalPurchaseDate: Harness.start.addingTimeInterval(-86_400 * 120), offerType: nil, isFreeTrial: false,
            environment: "Production", isRenewal: true, revoked: false)])
        h.core.apiNotifyPurchase(nil)
        h.settle()
        XCTAssertEqual(h.state.skanFloor, 32)
        // The trial converting (seen by the sweep on a later foreground) does.
        h.storeKit.entitlements.set([PurchaseInfo(
            originalTransactionId: "2000001", transactionId: "2000002", productId: "car_weekly_pro", appAccountToken: nil,
            appTransactionId: nil, purchaseDate: Harness.start.addingTimeInterval(259_200),
            originalPurchaseDate: Harness.start.addingTimeInterval(300), offerType: nil, isFreeTrial: false,
            environment: "Production", isRenewal: true, revoked: false)])
        h.lifecycle.send(.willEnterForeground)
        h.settle()
        XCTAssertEqual(h.state.skanFloor, 63)
    }

    func testNoSkanCallsUnlessBothSwitchesAreOn() throws {
        let off = try skanHarness(enabled: true, writer: false)
        off.core.apiTrack("registration", properties: [:])
        off.settle()
        XCTAssertTrue(off.skanWriter.writes.get().isEmpty, "skanWriter option off")

        let disabled = try skanHarness(enabled: false, writer: true)
        disabled.core.apiTrack("registration", properties: [:])
        disabled.settle()
        XCTAssertTrue(disabled.skanWriter.writes.get().isEmpty, "config skan.enabled off")
        XCTAssertFalse(disabled.transport.sentEvents.contains { $0["name"] == .string("$skan") })
    }
}
