import XCTest
@testable import KerdlySDK

/// HTTP statuses and acks, purely and through the core.
final class DeliveryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_760_400_000)

    private func classify(_ status: Int?, headers: [String: String] = [:], body: String = "") -> DeliveryOutcome {
        DeliveryPolicy.classify(status: status, headers: headers, body: Data(body.utf8), now: now)
    }

    // MARK: Status table

    func testStatusTable() {
        XCTAssertEqual(classify(400, body: #"{"error":"x","code":"malformed"}"#), .drop(code: "malformed", stopUntilNextLaunch: false))
        XCTAssertEqual(classify(401, body: #"{"error":"x","code":"bad_key"}"#), .drop(code: "bad_key", stopUntilNextLaunch: true))
        XCTAssertEqual(classify(403, body: #"{"error":"x","code":"bundle_mismatch"}"#), .drop(code: "bundle_mismatch", stopUntilNextLaunch: true))
        XCTAssertEqual(classify(403, body: #"{"error":"x","code":"key_revoked"}"#), .drop(code: "key_revoked", stopUntilNextLaunch: true))
        XCTAssertEqual(classify(408, headers: ["retry-after": "12"]), .retry(retryAfter: 12))
        XCTAssertEqual(classify(429, headers: ["retry-after": "30"]), .retry(retryAfter: 30))
        XCTAssertEqual(classify(429), .retry(retryAfter: nil))
        XCTAssertEqual(classify(413), .split)
        XCTAssertEqual(classify(500), .retry(retryAfter: nil))
        XCTAssertEqual(classify(503, headers: ["retry-after": "5"]), .retry(retryAfter: 5))
        XCTAssertEqual(classify(nil), .retry(retryAfter: nil), "a network error")
        XCTAssertEqual(classify(404), .retry(retryAfter: nil), "a missing route keeps the events")
        XCTAssertEqual(classify(422), .drop(code: "http_422", stopUntilNextLaunch: false))
        XCTAssertEqual(classify(200, body: "not json"), .retry(retryAfter: nil))
        guard case .success(let response) = classify(200, body: #"{"accepted":["a"],"rejected":[]}"#) else {
            return XCTFail("200 is a success")
        }
        XCTAssertEqual(response.accepted, ["a"])
        XCTAssertNil(response.configEtag)
    }

    func testRetryAfterParsing() {
        XCTAssertEqual(DeliveryPolicy.retryAfter(headers: ["retry-after": "120"], now: now), 120)
        XCTAssertEqual(DeliveryPolicy.retryAfter(headers: ["retry-after": "99999"], now: now), 3_600, "clamped to an hour")
        XCTAssertEqual(DeliveryPolicy.retryAfter(headers: ["retry-after": "-5"], now: now), 0)
        XCTAssertNil(DeliveryPolicy.retryAfter(headers: ["retry-after": "soon"], now: now))
        let date = "Tue, 14 Oct 2025 00:01:00 GMT"   // 60 s after `now`
        XCTAssertEqual(DeliveryPolicy.retryAfter(headers: ["retry-after": date], now: now), 60)
    }

    // MARK: Acks through the core

    /// A configured harness whose launch batch is held, plus a few custom events.
    private func harnessWithQueue(customEvents: Int) -> Harness {
        let h = Harness()
        h.configure()                               // batch 1 ($install, $open) is held
        for i in 0..<customEvents {
            h.core.apiTrack("step_\(i)", properties: [:])
        }
        h.settle()
        return h
    }

    func testAcceptedAndRejectedIdsLeaveTheQueueOthersStay() throws {
        let h = harnessWithQueue(customEvents: 0)
        let sent = try XCTUnwrap(h.transport.batches.first?["events"]?.arrayValue).compactMap { $0["id"]?.stringValue }
        XCTAssertEqual(sent.count, 2)
        h.transport.completeNext(Harness.batchResponse(accepted: [sent[0]]))
        h.settle()
        XCTAssertEqual(h.queuedEvents.map(\.id), [sent[1]], "an id in neither list stays queued")

        let h2 = harnessWithQueue(customEvents: 0)
        let sent2 = try XCTUnwrap(h2.transport.batches.first?["events"]?.arrayValue).compactMap { $0["id"]?.stringValue }
        h2.transport.completeNext(Harness.batchResponse(accepted: [sent2[0]], rejected: [(sent2[1], "invalid_props")]))
        h2.settle()
        XCTAssertTrue(h2.queuedEvents.isEmpty, "a rejected id is never resent")
        XCTAssertEqual(h2.state.backoffAttempt, 0)
    }

    func testAResponseThatSettlesNothingBacksOff() {
        let h = harnessWithQueue(customEvents: 0)
        h.transport.completeNext(Harness.batchResponse(accepted: []))
        h.settle()
        XCTAssertEqual(h.queuedEvents.count, 2)
        XCTAssertEqual(h.state.backoffAttempt, 1)
        XCTAssertNotNil(h.state.retryAt)
    }

    func testTooLargeSplitsTheBatchInHalfThenDropsASingleEvent() throws {
        let h = harnessWithQueue(customEvents: 2)    // queue: $install, $open, step_0, step_1
        h.transport.completeNext(Harness.status(500))  // the held launch batch fails; retry later
        h.settle()
        h.transport.respond = { request in
            let count = request.body.flatMap(JSONValue.parse)?["events"]?.arrayValue?.count ?? 0
            return count > 1 ? Harness.status(413, code: "too_large") : nil
        }
        h.core.apiFlush()
        h.settle()
        let counts = h.transport.batches.dropFirst().map { $0["events"]?.arrayValue?.count ?? 0 }
        XCTAssertEqual(counts, [4, 2, 1], "4 → 413 → 2 → 413 → 1")
        XCTAssertEqual(h.queuedEvents.count, 4)
        h.transport.completeNext(Harness.status(413, code: "too_large"))
        h.settle()
        XCTAssertEqual(h.queuedEvents.count, 3, "a single event that is still too large is dropped")
    }

    func testUnauthorizedDropsTheBatchAndStopsUntilTheNextLaunch() {
        let keychain = FakeKeychain(), defaults = FakeDefaults(), files = InMemoryFiles()
        let h = Harness(keychain: keychain, defaults: defaults, files: files)
        h.configure()
        h.transport.completeNext(Harness.status(401, code: "bad_key"))
        h.settle()
        XCTAssertTrue(h.queuedEvents.isEmpty, "the batch is dropped")
        h.core.apiTrack("registration", properties: [:])
        h.core.apiFlush()
        h.settle()
        XCTAssertEqual(h.transport.requests(path: "/v1/sdk/batch").count, 1, "nothing more is sent this launch")
        XCTAssertEqual(h.queuedEvents.map(\.name), ["registration"], "events keep queueing")

        let next = Harness(keychain: keychain, defaults: defaults, files: files)
        next.serveAcceptAll()
        next.configure()
        XCTAssertGreaterThanOrEqual(next.transport.requests(path: "/v1/sdk/batch").count, 1, "the next launch sends again")
    }

    func testMalformedDropsTheBatchButKeepsSending() {
        let h = harnessWithQueue(customEvents: 1)
        h.serveAcceptAll()
        h.transport.completeNext(Harness.status(400, code: "malformed"))
        h.settle()
        XCTAssertFalse(h.queuedEvents.contains { $0.name == "$install" })
        XCTAssertTrue(h.queuedEvents.isEmpty, "the remaining event went out in the next batch")
    }

    func testServerErrorsBackOffAndRetryAfterWins() throws {
        let h = harnessWithQueue(customEvents: 0)
        h.transport.completeNext(Harness.status(503))
        h.settle()
        XCTAssertEqual(h.state.backoffAttempt, 1)
        let firstRetry = try XCTUnwrap(h.state.retryAt)
        XCTAssertGreaterThanOrEqual(firstRetry - Clocks.ms(Harness.start), 1_000)

        // An explicit flush skips the client back-off …
        h.core.apiFlush()
        h.settle()
        XCTAssertEqual(h.transport.requests(path: "/v1/sdk/batch").count, 2)
        h.transport.completeNext(Harness.status(429, headers: ["retry-after": "30"], code: "rate_limited"))
        h.settle()
        XCTAssertEqual(h.state.retryAt, Clocks.ms(Harness.start) + 30_000)
        XCTAssertTrue(h.state.retryAtFromServer)
        // … but not a server Retry-After.
        h.core.apiFlush()
        h.settle()
        XCTAssertEqual(h.transport.requests(path: "/v1/sdk/batch").count, 2)
        // When the timer fires, the batch goes again.
        h.serveAcceptAll()
        h.clock.advance(30)
        h.scheduler.fire { $0 >= 29 && $0 <= 31 }
        h.settle()
        XCTAssertEqual(h.transport.requests(path: "/v1/sdk/batch").count, 3)
        XCTAssertTrue(h.queuedEvents.isEmpty)
        XCTAssertNil(h.state.retryAt)
        XCTAssertEqual(h.state.backoffAttempt, 0)
    }

    func testThePersistedNextAttemptIsHonouredAtLaunch() {
        let keychain = FakeKeychain(), defaults = FakeDefaults(), files = InMemoryFiles()
        let h = Harness(keychain: keychain, defaults: defaults, files: files)
        h.configure()
        h.transport.completeNext(Harness.status(429, headers: ["retry-after": "600"]))
        h.settle()
        let next = Harness(keychain: keychain, defaults: defaults, files: files)
        next.serveAcceptAll()
        next.configure()
        XCTAssertEqual(next.transport.requests(path: "/v1/sdk/batch").count, 0, "the launch flush waits for retry_at")
        XCTAssertTrue(next.scheduler.pending.contains { abs($0.delay - 600) < 1 })
    }

    // MARK: What a 200 carries

    func testAttributionConfigEtagAndNeeds() throws {
        let h = Harness()
        let attribution = try XCTUnwrap(try Fixtures.json("batch.response.json")["attribution"]?.objectValue)
        var configFetches = 0
        h.transport.respond = { request in
            if request.url.path.hasSuffix("/v1/sdk/config") {
                configFetches += 1
                return .response(status: 200, headers: ["etag": "\"7\""], body: try! Fixtures.data("config.response.json"))
            }
            if request.url.path.hasSuffix("/v1/sdk/batch") {
                let ids = request.body.flatMap(JSONValue.parse)?["events"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
                return Harness.batchResponse(accepted: ids, attribution: attribution, needs: ["asa_token"], etag: "\"7\"")
            }
            return Harness.status(204)
        }
        let received = expectation(description: "onAttribution")
        received.assertForOverFulfill = false
        h.core.addAttributionHandler(UncheckedSendable({ value in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(value.network, "meta")
            received.fulfill()
        }))
        h.configure()
        wait(for: [received], timeout: 2)
        XCTAssertEqual(h.core.apiAttribution?.cppId, "ce3a1b2c-0000-4000-8000-000000000001")
        XCTAssertEqual(h.state.attribution?.objectValue, attribution)
        XCTAssertEqual(configFetches, 1, "the etag matches the fetched config: no refetch")
        let tokens = h.transport.sentEvents.filter { $0["props"]?["kind"] == .string("asa_token") }
        XCTAssertEqual(tokens.compactMap { $0["props"]?["attempt"]?.int64Value }, [1, 2, 3],
                       "`needs` asks again, at most 3 tokens per install")
        XCTAssertEqual(h.adServices.calls.get(), 3)
    }

    func testADifferentConfigEtagRefetchesTheConfig() {
        let h = Harness()
        h.serveAcceptAll()
        h.configure()
        let before = h.transport.requests(path: "/v1/sdk/config").count
        h.transport.respond = { request in
            if request.url.path.hasSuffix("/v1/sdk/batch") {
                let ids = request.body.flatMap(JSONValue.parse)?["events"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
                return Harness.batchResponse(accepted: ids, etag: "\"2-ffff\"")
            }
            return .response(status: 304, headers: [:], body: Data())
        }
        h.core.apiTrack("registration", properties: [:])
        h.core.apiFlush()
        h.settle()
        let configRequests = h.transport.requests(path: "/v1/sdk/config")
        XCTAssertEqual(configRequests.count, before + 1)
        XCTAssertEqual(configRequests.last?.headers["If-None-Match"], Harness.configEtag)
    }
}
