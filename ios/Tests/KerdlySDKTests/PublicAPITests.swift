import XCTest
import KerdlySDK   // not @testable: only the public surface is visible here

/// The public API is fixed; the Expo bridge codes against it. These checks fail to
/// compile if a signature drifts. The usage closures are type-checked, never run (running them
/// would start the shared SDK).
final class PublicAPITests: XCTestCase {
    func testSignaturesMatchTheSpec() {
        let _: (KerdlyOptions) -> Void = Kerdly.configure
        let _: () -> String? = { Kerdly.installId }
        let _: (String?) -> Void = Kerdly.setUserId
        let _: (String, [String: Any]) -> Void = Kerdly.track
        let _: (String?, [String: Any]) -> Void = Kerdly.trackRegistration
        let _: (String?, Double?, String?, String?, [String: Any]) -> Void = Kerdly.trackStartTrial
        let _: (String?, Double?, String?, String?, [String: Any]) -> Void = Kerdly.trackSubscribe
        let _: (String?, Double?, String?, Int?, String?, [String: Any]) -> Void = Kerdly.trackPurchase
        let _: (Bool?, Bool?) -> Void = Kerdly.setConsent
        let _: (URL, String?) -> KerdlyDeepLink? = Kerdly.handleUrl
        let _: (UUID?) -> Void = Kerdly.setAppAccountToken
        let _: ([String: String]) -> Void = Kerdly.setPartnerIds
        let _: (KerdlyPurchase?) -> Void = Kerdly.notifyPurchase
        let _: (KerdlyNetworkSend) -> Void = Kerdly.recordNetworkSend
        let _: () -> KerdlyAttribution? = { Kerdly.attribution }
        let _: (@escaping (KerdlyAttribution) -> Void) -> Void = Kerdly.onAttribution
        let _: (@escaping (KerdlyAttStatus) -> Void) -> Void = Kerdly.requestTrackingAuthorization
        let _: () async -> KerdlyAttStatus = Kerdly.requestTrackingAuthorization
        let _: () -> Void = Kerdly.flush
    }

    func testCallSitesAsAppsWriteThem() {
        let usage: () async -> Void = {
            var options = KerdlyOptions(key: "pk_live_x", endpoint: URL(string: "https://sdk.example.com")!)
            options.environment = .auto
            options.collectAdvertisingId = true
            options.skanWriter = false
            options.logLevel = .warn
            options.wrapper = "expo/0.1.0"
            Kerdly.configure(options)
            Kerdly.setUserId("uid")
            Kerdly.setUserId(nil)
            Kerdly.track("registration")
            Kerdly.track("registration", properties: ["method": "anonymous"])
            Kerdly.track("quiz_completed", properties: ["score": 42])
            Kerdly.trackRegistration()
            Kerdly.trackRegistration(method: "anonymous")
            Kerdly.trackRegistration(method: "apple", properties: ["source": "onboarding"])
            Kerdly.trackStartTrial()
            Kerdly.trackStartTrial(productId: "w", value: 0, currency: "USD", transactionId: "1")
            Kerdly.trackSubscribe(productId: "w", value: 9.99, currency: "USD", transactionId: "2")
            Kerdly.trackSubscribe(productId: "w", properties: ["plan": "weekly"])
            Kerdly.trackPurchase(productId: "p", value: 4.99, currency: "USD", quantity: 1, transactionId: "3")
            Kerdly.trackPurchase(value: 4.99, currency: "EUR", properties: ["pack": "exam"])
            Kerdly.setConsent(analytics: true, ads: true)
            Kerdly.setConsent(ads: false)
            let link: KerdlyDeepLink? = Kerdly.handleUrl(URL(string: "acmeapp://open?cpp=x")!)
            Kerdly.handleUrl(URL(string: "acmeapp://open")!)
            Kerdly.handleUrl(URL(string: "acmeapp://open?cpp=x")!, source: "initial")
            _ = Kerdly.handleUrl(URL(string: "acmeapp://open")!, source: nil)
            _ = (link?.url, link?.cpp, link?.ppid, link?.afrC, link?.afrV, link?.campaignIds)
            Kerdly.setAppAccountToken(UUID())
            Kerdly.setAppAccountToken(nil)
            Kerdly.setPartnerIds(["meta_anon_id": "x"])
            Kerdly.notifyPurchase()
            Kerdly.notifyPurchase(KerdlyPurchase(originalTransactionId: "1", transactionId: "2", productId: "p", appAccountToken: UUID()))
            Kerdly.notifyPurchase(KerdlyPurchase(transactionId: "2"))
            Kerdly.recordNetworkSend(KerdlyNetworkSend(network: "meta", event: "StartTrial", eventId: "e", value: 0,
                                                 currency: "USD", flag: "f"))
            Kerdly.recordNetworkSend(KerdlyNetworkSend(network: "tiktok", event: "Subscribe"))
            if let a = Kerdly.attribution {
                _ = (a.state, a.network, a.status, a.method, a.campaignId, a.campaign, a.adsetId, a.adset,
                     a.adId, a.ad, a.keywordId, a.keyword, a.linkId, a.cppId, a.decidedAt, a.raw)
            }
            Kerdly.onAttribution { attribution in _ = attribution.network }
            Kerdly.requestTrackingAuthorization { status in _ = status.rawValue }
            let status: KerdlyAttStatus = await Kerdly.requestTrackingAuthorization()
            _ = status
            Kerdly.flush()
            _ = Kerdly.installId
        }
        _ = usage
    }

    func testEnumRawValues() {
        XCTAssertEqual(KerdlyEnvironment.allRawValues, ["auto", "production", "sandbox", "development"])
        XCTAssertEqual([KerdlyLogLevel.none, .error, .warn, .info, .debug].map(\.rawValue), [0, 1, 2, 3, 4])
        XCTAssertEqual([KerdlyAttStatus.authorized, .denied, .restricted, .notDetermined, .notApplicable].map(\.rawValue),
                       ["authorized", "denied", "restricted", "not_determined", "not_applicable"])
        let options = KerdlyOptions(key: "k", endpoint: URL(string: "https://x.example")!)
        XCTAssertEqual(options.environment, .auto)
        XCTAssertTrue(options.collectAdvertisingId)
        XCTAssertFalse(options.skanWriter)
        XCTAssertEqual(options.logLevel, .warn)
        XCTAssertNil(options.wrapper)
    }
}

private extension KerdlyEnvironment {
    static var allRawValues: [String] {
        [KerdlyEnvironment.auto, .production, .sandbox, .development].map(\.rawValue)
    }
}
