import XCTest
@testable import KerdlySDK

/// The standard events' typed props, from the typed methods and from `track`.
final class StandardEventTests: XCTestCase {
    private func purchase(_ properties: [String: Any]) -> EventValidator.Sanitized {
        StandardEvent.sanitize(StandardEvent.purchase, properties)
    }

    // MARK: Typed props

    func testValidPropsAreKeptAndCurrencyIsNormalized() {
        let result = purchase(["product_id": "exam_pack", "value": 4.99, "currency": " eur\n", "quantity": 2,
                               "transaction_id": "2000001012345680"])
        XCTAssertEqual(result.props, [
            "product_id": .string("exam_pack"),
            "value": .double(4.99),
            "currency": .string("EUR"),
            "quantity": .int(2),
            "transaction_id": .string("2000001012345680"),
        ])
        XCTAssertEqual(result.issues, [])
    }

    func testAFreeTrialIsValueZero() {
        let result = StandardEvent.sanitize(StandardEvent.startTrial, ["value": 0.0, "currency": "usd"])
        XCTAssertEqual(result.props, ["value": .int(0), "currency": .string("USD")])
    }

    func testNegativeAndNonFiniteValuesAreDropped() {
        for bad in [-0.01, -1, Double.nan, Double.infinity, -Double.infinity] as [Any] {
            let result = purchase(["value": bad, "currency": "USD", "product_id": "p"])
            XCTAssertNil(result.props["value"], "\(bad)")
            XCTAssertEqual(result.props["currency"], .string("USD"), "the rest is kept")
            XCTAssertEqual(result.props["product_id"], .string("p"))
            XCTAssertEqual(result.issues.count, 1, "\(bad)")
        }
        XCTAssertNil(purchase(["value": "4.99", "currency": "USD"]).props["value"], "a string is not a number")
        XCTAssertNil(purchase(["value": true, "currency": "USD"]).props["value"], "a boolean is not a number")
    }

    func testValueWithoutAValidCurrencyIsDropped() {
        let missing = purchase(["value": 4.99, "product_id": "p"])
        XCTAssertEqual(missing.props, ["product_id": .string("p")])
        XCTAssertEqual(missing.issues, ["prop 'value' dropped: no valid currency"])

        for bad in ["US", "USDX", "U$D", "€", "", "1SD", 840] as [Any] {
            let result = purchase(["value": 4.99, "currency": bad, "quantity": 1])
            XCTAssertEqual(result.props, ["quantity": .int(1)], "\(bad)")
            XCTAssertEqual(result.issues.count, 2, "\(bad): the currency and the value")
        }

        let currencyOnly = purchase(["currency": "usd"])
        XCTAssertEqual(currencyOnly.props, ["currency": .string("USD")], "a currency without a value is kept")
    }

    func testQuantityMustBeAnIntegerOfAtLeastOne() {
        for bad in [0, -1, 2.5, "1", true] as [Any] {
            let result = purchase(["quantity": bad])
            XCTAssertNil(result.props["quantity"], "\(bad)")
            XCTAssertEqual(result.issues.count, 1, "\(bad)")
        }
        XCTAssertEqual(purchase(["quantity": 2.0]).props["quantity"], .int(2), "an integral double counts")
        XCTAssertEqual(purchase(["quantity": 1]).props["quantity"], .int(1))
    }

    func testLongIdsAndMethodsAreTruncated() {
        let long = String(repeating: "a", count: 200)
        let result = purchase(["product_id": long, "transaction_id": long])
        XCTAssertEqual(result.props["product_id"], .string(String(repeating: "a", count: 128)))
        XCTAssertEqual(result.props["transaction_id"], .string(String(repeating: "a", count: 128)))
        XCTAssertEqual(result.issues.count, 2)

        let registration = StandardEvent.sanitize(StandardEvent.registration, ["method": long])
        XCTAssertEqual(registration.props["method"], .string(String(repeating: "a", count: 64)))
        XCTAssertEqual(registration.issues, ["prop 'method' truncated to 64 characters"])

        let exact = String(repeating: "b", count: 128)
        XCTAssertEqual(purchase(["product_id": exact]).props["product_id"], .string(exact))
        XCTAssertEqual(purchase(["product_id": exact]).issues, [])
    }

    func testWrongTypesAreDropped() {
        let result = purchase(["product_id": 42, "transaction_id": ["x"], "currency": NSNull()])
        XCTAssertEqual(result.props, [:])
        XCTAssertEqual(result.issues.count, 3)
    }

    func testTypedKeysAreOnlyTypedForTheirEvent() {
        // `method` is not a purchase prop and `value` is not a registration prop: custom rules apply.
        XCTAssertEqual(purchase(["method": "apple"]).props, ["method": .string("apple")])
        let registration = StandardEvent.sanitize(StandardEvent.registration, ["value": -1, "currency": "usd"])
        XCTAssertEqual(registration.props, ["value": .int(-1), "currency": .string("usd")])
        let custom = StandardEvent.sanitize("quiz_completed", ["value": -1, "currency": "usd", "quantity": 0])
        XCTAssertEqual(custom.props, ["value": .int(-1), "currency": .string("usd"), "quantity": .int(0)])
    }

    // MARK: Custom props alongside

    func testExtraPropsFollowTheCustomRulesWithinOne25PropBudget() {
        var properties: [String: Any] = [
            "product_id": "p", "value": 1.5, "currency": "USD", "quantity": 1, "transaction_id": "t",
            "Bad Key": "x", "nested": ["a": 1], "note": String(repeating: "n", count: 300),
        ]
        for i in 0..<30 { properties[String(format: "k%02d", i)] = i }
        let result = purchase(properties)
        XCTAssertEqual(result.props.count, 25)
        for key in ["product_id", "value", "currency", "quantity", "transaction_id"] {
            XCTAssertNotNil(result.props[key], "typed props come first: \(key)")
        }
        XCTAssertNil(result.props["Bad Key"])
        XCTAssertNil(result.props["nested"])
        XCTAssertNotNil(result.props["k00"])
        XCTAssertNotNil(result.props["k19"])
        XCTAssertNil(result.props["k20"], "5 typed + 20 custom = 25")
        XCTAssertNil(result.props["note"], "sorted after the k.. keys, so over the limit")
    }

    func testCustomStringsAreTruncatedInUTF16Units() {
        // The collector (JavaScript) counts UTF-16 units; an emoji is two, and is never split.
        XCTAssertEqual(EventValidator.truncated(String(repeating: "😀", count: 200), to: 256),
                       String(repeating: "😀", count: 128))
        XCTAssertEqual(EventValidator.truncated(String(repeating: "a", count: 255) + "😀", to: 256),
                       String(repeating: "a", count: 255))
        XCTAssertNil(EventValidator.truncated(String(repeating: "😀", count: 128), to: 256))
        let result = StandardEvent.sanitize(StandardEvent.subscribe, ["plan": String(repeating: "😀", count: 200)])
        XCTAssertEqual(result.props["plan"]?.stringValue?.utf16.count, 256)
    }

    func testArgumentsWinOverProperties() {
        let merged = StandardEvent.merge(
            StandardEvent.arguments(productId: "a", value: 2, currency: nil, transactionId: nil),
            ["product_id": "b", "currency": "usd", "plan": "weekly"])
        XCTAssertEqual(merged.ignored, ["product_id"])
        let result = StandardEvent.sanitize(StandardEvent.subscribe, merged.props)
        XCTAssertEqual(result.props, ["product_id": .string("a"), "value": .int(2), "currency": .string("USD"),
                                      "plan": .string("weekly")])
    }

    // MARK: End to end

    private func props(_ h: Harness, _ name: String) -> [[String: JSONValue]] {
        h.queuedEvents.filter { $0.name == name }.map(\.props)
    }

    func testTypedMethodsEnqueueTheirEvents() {
        let h = Harness()
        h.configure()
        h.core.apiTrackRegistration(method: "apple", properties: [:])
        h.core.apiTrackStartTrial(productId: "w", value: 0, currency: "usd", transactionId: "1", properties: [:])
        h.core.apiTrackSubscribe(productId: "w", value: -3, currency: "usd", transactionId: "2", properties: ["plan": "weekly"])
        h.core.apiTrackPurchase(productId: "p", value: 4.99, currency: nil, quantity: 0, transactionId: "3", properties: [:])
        h.core.apiTrackRegistration(method: nil, properties: [:])
        h.settle()
        let custom = h.queuedEvents.filter { !$0.isReserved }
        XCTAssertEqual(custom.map(\.name), ["registration", "start_trial", "subscribe", "purchase", "registration"])
        XCTAssertEqual(custom.map(\.props), [
            ["method": .string("apple")],
            ["product_id": .string("w"), "value": .int(0), "currency": .string("USD"), "transaction_id": .string("1")],
            ["product_id": .string("w"), "currency": .string("USD"), "transaction_id": .string("2"), "plan": .string("weekly")],
            ["product_id": .string("p"), "transaction_id": .string("3")],
            [:],
        ])
    }

    func testTrackValidatesStandardNamesTheSameWay() {
        let long = String(repeating: "x", count: 300)
        let h = Harness()
        h.configure()
        h.core.apiTrackPurchase(productId: long, value: Double.nan, currency: "usd", quantity: 0, transactionId: long,
                                properties: ["note": "n"])
        h.core.apiTrack("purchase", properties: ["product_id": long, "value": Double.nan, "currency": "usd",
                                                 "quantity": 0, "transaction_id": long, "note": "n"])
        h.core.apiTrackPurchase(productId: "p", value: -1, currency: "eur", quantity: 3, transactionId: nil, properties: [:])
        h.core.apiTrack("purchase", properties: ["product_id": "p", "value": -1, "currency": "eur", "quantity": 3])
        h.core.apiTrackStartTrial(productId: nil, value: 0, currency: nil, transactionId: nil, properties: [:])
        h.core.apiTrack("start_trial", properties: ["value": 0])
        h.settle()
        let purchases = props(h, "purchase")
        XCTAssertEqual(purchases.count, 4)
        XCTAssertEqual(purchases[0], purchases[1])
        XCTAssertEqual(purchases[0], ["product_id": .string(String(long.prefix(128))), "currency": .string("USD"),
                                      "transaction_id": .string(String(long.prefix(128))), "note": .string("n")])
        XCTAssertEqual(purchases[2], purchases[3])
        XCTAssertEqual(purchases[2], ["product_id": .string("p"), "currency": .string("EUR"), "quantity": .int(3)])
        XCTAssertEqual(props(h, "start_trial"), [[:], [:]], "no currency: the value is dropped either way")
    }

    func testStandardEventsAreOrdinaryEventsForConsent() {
        let h = Harness()
        h.configure()
        h.core.apiSetConsent(analytics: false, ads: nil)
        h.core.apiTrackSubscribe(productId: "w", value: 7.99, currency: "USD", transactionId: "1", properties: [:])
        h.settle()
        XCTAssertTrue(props(h, "subscribe").isEmpty, "analytics consent off drops them like any custom event")
    }
}
