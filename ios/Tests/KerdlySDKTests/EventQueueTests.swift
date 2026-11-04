import XCTest
@testable import KerdlySDK

/// The persistent queue, its bounds and its file.
final class EventQueueTests: XCTestCase {
    private func event(_ seq: Int64, _ name: String = "custom_event", payload: Int = 0) -> QueuedEvent {
        QueuedEvent(id: "id-\(seq)", name: name, ts: 1_760_400_000_000 + seq, seq: seq, userId: nil,
                    props: payload > 0 ? ["blob": .string(String(repeating: "x", count: payload))] : [:])
    }

    func testAppendKeepsSeqOrderAndReplaysInPlace() {
        var queue = EventQueue()
        queue.append(event(1))
        queue.append(event(3))
        queue.append(event(2, "$deeplink"))
        XCTAssertEqual(queue.events.map(\.seq), [1, 2, 3])
        XCTAssertTrue(queue.contains(id: "id-2"))
    }

    func testAThousandEventsDropTheOldestCustomEventFirst() {
        var queue = EventQueue()
        queue.append(event(1, "$install"))
        for seq in 2...1_000 { queue.append(event(Int64(seq))) }
        XCTAssertEqual(queue.count, 1_000)
        let dropped = queue.append(event(1_001))
        XCTAssertEqual(dropped.map(\.seq), [2], "the oldest custom event goes, not the older reserved one")
        XCTAssertEqual(queue.count, 1_000)
        XCTAssertEqual(queue.events.first?.name, "$install")
        XCTAssertEqual(queue.events.last?.seq, 1_001)
    }

    func testOneMegabyteDropsTheOldestCustomEventsFirst() {
        var queue = EventQueue()
        queue.append(event(1, "$open"))
        // ~105 KB custom events: the tenth crosses 1 MiB.
        for seq in 2...11 { queue.append(event(Int64(seq), payload: 105_000)) }
        XCTAssertLessThanOrEqual(queue.totalBytes, EventQueue.defaultMaxBytes)
        XCTAssertEqual(queue.events.first?.name, "$open")
        XCTAssertFalse(queue.contains(id: "id-2"))
        XCTAssertTrue(queue.contains(id: "id-11"))
        XCTAssertEqual(queue.totalBytes, queue.events.reduce(0) { $0 + $1.size })
    }

    func testReservedEventsAreNeverDropped() {
        var queue = EventQueue(maxEvents: 3)
        for seq in 1...5 { queue.append(event(Int64(seq), "$signal")) }
        XCTAssertEqual(queue.count, 5, "a queue of reserved events may exceed the bound")
        let dropped = queue.append(event(6))
        XCTAssertEqual(dropped.map(\.seq), [6], "a new custom event is dropped when only reserved events are older")
        XCTAssertEqual(queue.count, 5)
    }

    func testRemoveByIds() {
        var queue = EventQueue(events: [event(1), event(2), event(3)])
        XCTAssertEqual(queue.remove(ids: ["id-1", "id-3", "unknown"]), 2)
        XCTAssertEqual(queue.events.map(\.id), ["id-2"])
        XCTAssertEqual(queue.totalBytes, event(2).size)
    }

    func testNextBatchHonoursCountAndBytes() {
        let queue = EventQueue(events: (1...60).map { event(Int64($0)) })
        XCTAssertEqual(queue.nextBatch(maxEvents: 50, maxBytes: 256 * 1_024, overheadBytes: 500).count, 50)
        let big = EventQueue(events: (1...5).map { event(Int64($0), payload: 100_000) })
        XCTAssertEqual(big.nextBatch(maxEvents: 50, maxBytes: 256 * 1_024, overheadBytes: 500).count, 2)
        let huge = EventQueue(events: [event(1, payload: 300_000)])
        XCTAssertEqual(huge.nextBatch(maxEvents: 50, maxBytes: 256 * 1_024, overheadBytes: 500).count, 1,
                       "an oversized event still goes alone; the server answers 413")
    }

    func testEventSizeIsTheEncodedWireSize() {
        let e = event(7)
        XCTAssertEqual(e.size, KerdlyJSON.encode(e.wire)!.count)
    }

    // MARK: Persistence

    func testQueueFileRoundTrips() {
        let files = InMemoryFiles()
        let store = StateStore(files: files)
        let events = [event(1, "$install"), event(2)]
        XCTAssertTrue(store.save(queue: events, installId: "install-a"))
        let loaded = store.loadQueue()
        XCTAssertEqual(loaded?.installId, "install-a")
        XCTAssertEqual(loaded?.events, events)
    }

    func testStateFileRoundTripsAndToleratesMissingFields() {
        let files = InMemoryFiles()
        let store = StateStore(files: files)
        var state = PersistedState(installId: "install-a")
        state.seq = 9
        state.skanFloor = 32
        state.partnerIds = ["meta_anon_id": "abc"]
        store.save(state)
        XCTAssertEqual(store.loadState(), state)
        files.write(Data(#"{"install_id":"install-b","seq":3,"unknown":true}"#.utf8), to: StateFiles.state)
        let partial = store.loadState()
        XCTAssertEqual(partial?.seq, 3)
        XCTAssertEqual(partial?.consentAnalytics, true)
    }

    func testTheQueueSurvivesARelaunchAndIsWrittenOnEveryChange() {
        let keychain = FakeKeychain()
        let defaults = FakeDefaults()
        let files = InMemoryFiles()
        let ids = SequentialIds()
        let first = Harness(keychain: keychain, defaults: defaults, files: files, ids: ids)
        first.configure()
        first.core.apiTrack("registration", properties: ["method": "anonymous"])
        first.settle()
        let persisted = files.json(StateFiles.queue)?["events"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(persisted, ["$install", "$open", "registration"])

        // Next launch: nothing was delivered (the transport held every request).
        let second = Harness(keychain: keychain, defaults: defaults, files: files, ids: ids)
        second.configure()
        XCTAssertEqual(second.queuedEvents.map(\.name), ["$install", "$open", "registration", "$open"])
        XCTAssertEqual(second.queuedEvents.map(\.seq), [1, 2, 3, 4], "seq continues across launches")
    }
}
