import XCTest
@testable import KerdlySDK

/// `$purchase_link` once per original transaction id, from notify, the entitlement
/// sweep and `Transaction.updates`.
final class PurchaseTests: XCTestCase {
    func info(original: String, transaction: String, offer: String? = nil, trial: Bool = false,
              purchased: TimeInterval = 300, renewal: Bool? = false) -> PurchaseInfo {
        PurchaseInfo(originalTransactionId: original, transactionId: transaction, productId: "car_weekly_pro",
                     appAccountToken: "3f2504e0-4f89-41d3-9a0c-0305e82c3301", appTransactionId: "705012345678901234",
                     purchaseDate: Harness.start.addingTimeInterval(purchased),
                     originalPurchaseDate: Harness.start.addingTimeInterval(300), offerType: offer, isFreeTrial: trial,
                     environment: "Production", isRenewal: renewal, revoked: false)
    }

    func links(_ h: Harness) -> [QueuedEvent] {
        h.queuedEvents.filter { $0.name == "$purchase_link" } // nothing is delivered: the transport holds batches
    }

    func testNotifyEmitsOnceWithTheAppsIdsWinning() throws {
        let h = Harness()
        h.serveConfigOnly()                          // the fixture collects purchases
        h.configure()
        h.storeKit.found.set(info(original: "2000001", transaction: "2000001", offer: "introductory", trial: true))
        let alias = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
        h.core.apiNotifyPurchase(KerdlyPurchase(originalTransactionId: "2000001", transactionId: "2000001",
                                             productId: "car_weekly_pro", appAccountToken: alias))
        h.core.apiNotifyPurchase(KerdlyPurchase(originalTransactionId: "2000001", transactionId: "2000001"))
        h.settle()
        let all = links(h)
        XCTAssertEqual(all.count, 1)
        let props = try XCTUnwrap(all.first?.props)
        XCTAssertEqual(props["source"], .string("notify"))
        XCTAssertEqual(props["store"], .string("app_store"))
        XCTAssertEqual(props["app_account_token"], .string("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
        XCTAssertEqual(props["app_transaction_id"], .string("705012345678901234"))
        XCTAssertEqual(props["offer_type"], .string("introductory"))
        XCTAssertEqual(props["purchase_date"], .int(Clocks.ms(Harness.start.addingTimeInterval(300))))
    }

    func testSweepAndUpdatesDoNotRepeatAnOriginalId() {
        let h = Harness()
        h.storeKit.entitlements.set([info(original: "2000001", transaction: "2000001")])
        h.serveAcceptAll()
        h.configure()
        let sent = { h.transport.sentEvents.filter { $0["name"] == .string("$purchase_link") } }
        XCTAssertEqual(sent().count, 1)
        XCTAssertEqual(sent().first?["props"]?["source"], .string("entitlements"))
        h.lifecycle.send(.willEnterForeground)                                    // sweep again
        h.storeKit.emitUpdate(info(original: "2000001", transaction: "2000002", purchased: 259_200, renewal: true))
        h.settle()
        XCTAssertEqual(sent().count, 1, "a renewal of a reported subscription is not reported again")
        h.storeKit.emitUpdate(info(original: "3000001", transaction: "3000001"))
        h.settle()
        XCTAssertEqual(sent().count, 2)
        XCTAssertEqual(sent().last?["props"]?["source"], .string("updates"))
    }

    func testANotifyWithoutStoreKitDataStillLinksAndTheSweepDoesNotDuplicate() {
        let h = Harness()
        h.serveAcceptAll()
        h.configure()
        h.storeKit.found.set(nil)
        h.core.apiNotifyPurchase(KerdlyPurchase(transactionId: "2000001", productId: "car_weekly_pro"))
        h.settle()
        let sent = { h.transport.sentEvents.filter { $0["name"] == .string("$purchase_link") } }
        XCTAssertEqual(sent().count, 1)
        XCTAssertEqual(sent().first?["props"]?["original_transaction_id"], .null)
        XCTAssertEqual(sent().first?["props"]?["purchase_date"], .null)
        h.storeKit.entitlements.set([info(original: "1999999", transaction: "2000001")])
        h.core.apiNotifyPurchase(nil)
        h.settle()
        XCTAssertEqual(sent().count, 1, "matched on the transaction id")
        XCTAssertTrue(h.state.reportedPurchaseIds.contains("1999999"), "and its original id is remembered")
    }

    func testCollectPurchasesOffSendsNoLinks() throws {
        var config = try Fixtures.json("config.response.json").objectValue!
        config["collect"] = .object(["purchases": .bool(false)])
        let h = Harness()
        h.storeKit.entitlements.set([info(original: "2000001", transaction: "2000001")])
        h.serveAcceptAll(config: .object(config))
        h.configure()
        h.core.apiNotifyPurchase(KerdlyPurchase(originalTransactionId: "2000002"))
        h.settle()
        XCTAssertFalse(h.transport.sentEvents.contains { $0["name"] == .string("$purchase_link") })
        XCTAssertEqual(h.storeKit.entitlementCalls.get(), 0, "no StoreKit observation is needed")
    }

    func testDedupeKeys() {
        let notified = NotifiedPurchase(KerdlyPurchase(originalTransactionId: " 2000001 ", transactionId: "2000005"))
        XCTAssertEqual(PurchaseLinks.dedupeKeys(info: nil, notified: notified), ["2000001", "2000005"])
        XCTAssertTrue(PurchaseLinks.isReported(["x", "2000005"], in: ["2000005"]))
        XCTAssertFalse(NotifiedPurchase(KerdlyPurchase(productId: "p")).hasIds)
    }
}
