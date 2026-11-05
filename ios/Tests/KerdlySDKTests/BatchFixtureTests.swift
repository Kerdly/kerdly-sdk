import XCTest
@testable import KerdlySDK

/// The batches this SDK builds have exactly the fixtures' field
/// names and shapes.
final class BatchFixtureTests: XCTestCase {
    // MARK: Encoding: the fixture's own values re-encoded give the fixture back

    private func rebuild(_ fixture: JSONValue) throws -> JSONValue {
        let sdk = try XCTUnwrap(fixture["sdk"]), app = try XCTUnwrap(fixture["app"])
        let envelope = BatchEnvelope(
            sdkName: try XCTUnwrap(sdk["name"]?.stringValue), sdkVersion: try XCTUnwrap(sdk["version"]?.stringValue),
            wrapper: sdk["wrapper"]?.stringValue,
            bundle: try XCTUnwrap(app["bundle"]?.stringValue), appVersion: try XCTUnwrap(app["version"]?.stringValue),
            appBuild: try XCTUnwrap(app["build"]?.stringValue), environment: try XCTUnwrap(app["environment"]?.stringValue),
            installId: try XCTUnwrap(fixture["install_id"]?.stringValue))
        let events = try XCTUnwrap(fixture["events"]?.arrayValue).map { e in
            QueuedEvent(id: e["id"]!.stringValue!, name: e["name"]!.stringValue!, ts: e["ts"]!.int64Value!,
                        seq: e["seq"]!.int64Value!, userId: e["user_id"]?.stringValue, props: e["props"]!.objectValue!)
        }
        let body = try XCTUnwrap(BatchBuilder.body(envelope: envelope, sentAt: try XCTUnwrap(fixture["sent_at"]?.int64Value),
                                                   context: fixture["context"], events: events))
        return try XCTUnwrap(JSONValue.parse(body))
    }

    func testFirstLaunchFixtureEncodesExactly() throws {
        let fixture = try Fixtures.json("batch-ios-first-launch.request.json")
        XCTAssertEqual(try rebuild(fixture), fixture)
    }

    func testStandardEventsFixtureEncodesExactly() throws {
        let fixture = try Fixtures.json("batch-standard-events.request.json")
        XCTAssertEqual(try rebuild(fixture), fixture)
    }

    func testEventsFixtureEncodesExactly() throws {
        // No `context` (unchanged) and no `sdk.wrapper` (a native app): both omitted, not null.
        let fixture = try Fixtures.json("batch-events.request.json")
        XCTAssertEqual(try rebuild(fixture), fixture)
    }

    func testResponseFixtureParses() throws {
        let response = try XCTUnwrap(BatchResponse.parse(try Fixtures.data("batch.response.json")))
        XCTAssertEqual(response.accepted, ["a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c01", "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c02"])
        XCTAssertEqual(response.rejected, [RejectedEvent(id: "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c08", reason: "invalid_name")])
        XCTAssertEqual(response.configEtag, "\"1-5e1a\"")
        XCTAssertEqual(response.attribution?["cpp_id"], .string("ce3a1b2c-0000-4000-8000-000000000001"))
        XCTAssertEqual(response.needs, [])
        let attribution = KerdlyAttribution(json: try XCTUnwrap(response.attribution))
        XCTAssertEqual(attribution.network, "meta")
        XCTAssertEqual(attribution.method, "cpp_deeplink")
        XCTAssertEqual(attribution.decidedAt, Date(timeIntervalSince1970: 1_760_400_126))
        XCTAssertTrue(attribution.raw["campaign_id"] is NSNull)
    }

    // MARK: End to end: what the SDK sends on a first launch

    func testFirstLaunchBatchesMatchTheFixture() throws {
        let fixture = try Fixtures.json("batch-ios-first-launch.request.json")
        let h = Harness()
        h.serveAcceptAll()
        h.configure { $0.wrapper = "expo/0.1.0" }

        let batches = h.transport.batches
        let first = try XCTUnwrap(batches.first)
        XCTAssertEqual(first.keys, fixture.keys)
        XCTAssertEqual(first["sdk"], fixture["sdk"])
        XCTAssertEqual(first["app"], fixture["app"])
        XCTAssertEqual(first["context"], fixture["context"], "same device inputs → the same context")
        XCTAssertEqual(first["events"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["$install", "$open"])
        XCTAssertEqual(first["install_id"], .string(try XCTUnwrap(h.core.installIdBox.get())))

        let sent = h.transport.sentEvents
        for expected in try XCTUnwrap(fixture["events"]?.arrayValue) {
            let name = expected["name"]?.stringValue
            let kind = expected["props"]?["kind"]
            let actual = sent.first { $0["name"]?.stringValue == name && $0["props"]?["kind"] == kind }
            assertSameShape(actual, expected, "\(name ?? "?")/\(kind?.stringValue ?? "")")
        }
        let install = try XCTUnwrap(sent.first { $0["name"] == .string("$install") })
        let expectedInstall = fixture["events"]?.arrayValue?.first?["props"]
        XCTAssertNotNil(expectedInstall?["device"])
        XCTAssertEqual(install["props"]?["device"], expectedInstall?["device"], "same device inputs → the same snapshot")
        XCTAssertEqual(install["props"], expectedInstall)
        let asa = try XCTUnwrap(sent.first { $0["props"]?["kind"] == .string("asa_token") })
        XCTAssertEqual(asa["props"], .object(["kind": .string("asa_token"),
                                             "token": .string("eyJ0b2tlbi1zYW1wbGUtYXNhIjoxfQ=="), "attempt": .int(1)]))
        let appTx = try XCTUnwrap(sent.first { $0["props"]?["kind"] == .string("app_transaction") })
        XCTAssertEqual(appTx["props"], fixture["events"]?.arrayValue?.last?["props"])

        // Later batches leave the acked context out.
        XCTAssertGreaterThan(batches.count, 1)
        for later in batches.dropFirst() {
            XCTAssertNil(later["context"])
        }

        let request = try XCTUnwrap(h.transport.requests(path: "/v1/sdk/batch").first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://sdk.example.com/api/v1/sdk/batch")
        XCTAssertEqual(request.headers["Authorization"], "Bearer pk_test_123")
        XCTAssertEqual(request.headers["X-Kerdly-Bundle"], "com.acme.other")
        XCTAssertEqual(request.headers["X-Kerdly-Sdk"], "kerdly-ios/0.1.0 expo/0.1.0")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
    }

    // MARK: End to end: the events fixture's calls

    func testAppCallsProduceTheEventsFixture() throws {
        let fixture = try Fixtures.json("batch-events.request.json")
        let h = Harness()
        h.serveAcceptAll()
        h.configure()
        h.transport.clear()

        let token = try XCTUnwrap(UUID(uuidString: "3f2504e0-4f89-41d3-9a0c-0305e82c3301"))
        h.core.apiSetUserId("m5KwQ2xYz")
        h.settle()
        h.tracking.current.set(.denied)
        h.lifecycle.send(.didBecomeActive)
        h.settle()
        h.core.apiSetAppAccountToken(token)
        h.core.apiSetPartnerIds(["superwall_alias": "$SuperwallAlias:3F2504E0"])
        h.core.apiTrack("registration", properties: ["method": "anonymous"])
        h.core.apiTrack("Bad Name", properties: [:])
        _ = h.core.apiHandleUrl(URL(string: "acmeapp://open?cpp=web-meta&ppid=ce3a1b2c-0000-4000-8000-000000000001")!)
        h.storeKit.found.set(PurchaseInfo(
            originalTransactionId: "2000001012345678", transactionId: "2000001012345678", productId: "car_weekly_pro",
            appAccountToken: "3f2504e0-4f89-41d3-9a0c-0305e82c3301", appTransactionId: "705012345678901234",
            purchaseDate: Date(timeIntervalSince1970: 1_760_400_119), originalPurchaseDate: Date(timeIntervalSince1970: 1_760_400_119),
            offerType: "introductory", isFreeTrial: true, environment: "Production", isRenewal: false, revoked: false))
        h.core.apiNotifyPurchase(KerdlyPurchase(originalTransactionId: "2000001012345678", transactionId: "2000001012345678",
                                             productId: "car_weekly_pro", appAccountToken: token))
        h.core.apiRecordNetworkSend(KerdlyNetworkSend(network: "meta", event: "StartTrial",
                                                   eventId: "2000001012345678:trial_start", value: 0,
                                                   currency: "USD", flag: "meta_start_trial_enabled"))
        h.settle()

        let batches = h.transport.batches
        let first = try XCTUnwrap(batches.first)
        var expectedTop = fixture.keys
        expectedTop.remove("context")
        var actualTop = first.keys
        actualTop.remove("context")
        XCTAssertEqual(actualTop, expectedTop)
        XCTAssertEqual(first["sdk"], fixture["sdk"], "no wrapper key for a native app")
        XCTAssertEqual(first["app"], fixture["app"])

        let sent = h.transport.sentEvents
        XCTAssertNil(sent.first { $0["name"] == .string("Bad Name") }, "an invalid name never leaves the device")
        for expected in try XCTUnwrap(fixture["events"]?.arrayValue) where expected["name"] != .string("Bad Name") {
            let name = try XCTUnwrap(expected["name"]?.stringValue)
            let actual = sent.last { $0["name"]?.stringValue == name }
            assertSameShape(actual, expected, name)
            XCTAssertEqual(actual?["props"], expected["props"], "\(name) props")
            XCTAssertEqual(actual?["user_id"], expected["user_id"], "\(name) user_id")
        }
    }

    // MARK: End to end: the standard events fixture's calls

    func testStandardMethodsProduceTheStandardEventsFixture() throws {
        let fixture = try Fixtures.json("batch-standard-events.request.json")
        let h = Harness()
        h.serveAcceptAll()
        h.configure()
        h.core.apiSetUserId("m5KwQ2xYz")
        h.settle()
        h.transport.clear()

        h.core.apiTrackRegistration(method: "anonymous", properties: [:])
        h.core.apiTrackStartTrial(productId: "car_weekly_pro", value: 0, currency: "USD",
                                  transactionId: "2000001012345678", properties: [:])
        h.core.apiTrackSubscribe(productId: "car_weekly_pro", value: 7.99, currency: "usd",
                                 transactionId: "2000001012345679", properties: ["plan": "weekly"])
        h.core.apiTrackPurchase(productId: "exam_pack", value: 4.99, currency: "EUR", quantity: 1,
                                transactionId: "2000001012345680", properties: [:])
        h.core.apiTrack("quiz_completed", properties: ["score": 42, "state": "CA", "passed": true])
        h.core.apiFlush()
        h.settle()

        let batches = h.transport.batches
        let first = try XCTUnwrap(batches.first)
        var expectedTop = fixture.keys
        expectedTop.remove("context")
        var actualTop = first.keys
        actualTop.remove("context")
        XCTAssertEqual(actualTop, expectedTop)
        XCTAssertEqual(first["sdk"], fixture["sdk"])
        XCTAssertEqual(first["app"], fixture["app"])

        let sent = h.transport.sentEvents.filter { !($0["name"]?.stringValue ?? "$").hasPrefix("$") }
        let expected = try XCTUnwrap(fixture["events"]?.arrayValue)
        XCTAssertEqual(sent.compactMap { $0["name"]?.stringValue }, expected.compactMap { $0["name"]?.stringValue })
        for (actual, wanted) in zip(sent, expected) {
            let name = wanted["name"]?.stringValue ?? "?"
            assertSameShape(actual, wanted, name)
            XCTAssertEqual(actual["props"], wanted["props"], "\(name) props")
            XCTAssertEqual(actual["user_id"], wanted["user_id"], "\(name) user_id")
        }
        let seqs = sent.compactMap { $0["seq"]?.int64Value }
        XCTAssertEqual(seqs, seqs.sorted(), "enqueued in call order")
    }
}
