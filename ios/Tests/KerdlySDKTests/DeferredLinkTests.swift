import XCTest
@testable import KerdlySDK

/// The deferred-deep-link requests (Meta's and TikTok's own, replayed) and their answers.
final class DeferredLinkTests: XCTestCase {
    let facts = DdlDeviceFacts(
        bundleId: "com.acme.app", appName: "Acme", appVersion: "5.13", appBuild: "140",
        os: "26.0.1", model: "iPhone16,2", localeIdentifier: "en_US", preferredLanguage: "en-US",
        regionCode: "US", timeZoneName: "America/New_York", timeZoneAbbrev: "EDT",
        screenWidth: 430, screenHeight: 932, screenScale: 3, coreCount: 6,
        idfa: "6D92078A-8246-4BA4-AE5B-76104861E7DC", idfv: "IDFV-1", urlSchemes: ["com.acme.app", "fb123"])

    func form(_ request: HTTPRequest) -> [String: String] {
        var out: [String: String] = [:]
        for pair in String(decoding: request.body ?? Data(), as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            out[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        return out
    }

    func testMetaRequestMirrorsTheFacebookSdk() throws {
        let request = try XCTUnwrap(MetaDdl.request(appId: "123", clientToken: "tok", anonId: "XZABC", facts: facts,
                                                    trackingAuthorized: true))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://ep1.facebook.com/v26.0/123/activities")
        let body = form(request)
        XCTAssertEqual(body["event"], "DEFERRED_APP_LINK")
        XCTAssertEqual(body["advertiser_id"], facts.idfa)
        XCTAssertEqual(body["advertiser_tracking_enabled"], "1")
        XCTAssertEqual(body["application_tracking_enabled"], "1")
        XCTAssertEqual(body["advertiser_id_collection_enabled"], "1")
        XCTAssertEqual(body["anon_id"], "XZABC")
        XCTAssertEqual(body["access_token"], "123|tok")
        XCTAssertEqual(body["url_schemes"], #"["com.acme.app","fb123"]"#)
        let extinfo = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(body["extinfo"]).utf8)) as? [Any])
        XCTAssertEqual(extinfo.count, 16)
        XCTAssertEqual(extinfo[0] as? String, "i2")
        XCTAssertEqual(extinfo[2] as? String, "140", "slot 2 is the build, slot 3 the version")
        XCTAssertEqual(extinfo[3] as? String, "5.13")
        XCTAssertEqual(extinfo[11] as? String, "3.00")
        XCTAssertEqual(extinfo[15] as? String, "America/New_York")
    }

    func testMetaWithoutTrackingGoesToEp2WithoutTheIdfa() throws {
        let request = try XCTUnwrap(MetaDdl.request(appId: "123", clientToken: "tok", anonId: "XZABC", facts: facts,
                                                    trackingAuthorized: false))
        XCTAssertEqual(request.url.absoluteString, "https://ep2.facebook.com/v26.0/123/activities")
        let body = form(request)
        XCTAssertNil(body["advertiser_id"], "the IDFA never goes without tracking authorized")
        XCTAssertEqual(body["advertiser_tracking_enabled"], "0")
        XCTAssertEqual(body["application_tracking_enabled"], "1", "an app setting in FBSDKCoreKit, not ATT")
        XCTAssertEqual(body["advertiser_id_collection_enabled"], "1", "an app setting in FBSDKCoreKit, not ATT")
        XCTAssertEqual(body["anon_id"], "XZABC")
        XCTAssertEqual(body["event"], "DEFERRED_APP_LINK")
    }

    func testMetaNeedsTheBundleIds() {
        XCTAssertNil(MetaDdl.request(appId: "", clientToken: "tok", anonId: "x", facts: facts, trackingAuthorized: true))
        XCTAssertNil(MetaDdl.request(appId: "123", clientToken: "", anonId: "x", facts: facts, trackingAuthorized: true))
    }

    func testMetaAnswers() {
        let link = MetaDdl.parse(.response(status: 200, headers: [:],
            body: Data(#"{"applink_url":"com.acme.app://kerdly?ad_id=1","click_time":"1761177600"}"#.utf8)))
        XCTAssertEqual(link.status, .link)
        XCTAssertEqual(link.url, "com.acme.app://kerdly?ad_id=1")
        XCTAssertEqual(link.clickTime, "1761177600")
        XCTAssertEqual(MetaDdl.parse(.response(status: 200, headers: [:], body: Data("{}".utf8))).status, .none)
        let error = MetaDdl.parse(.response(status: 400, headers: [:],
            body: Data(#"{"error":{"code":100,"message":"Invalid parameter"}}"#.utf8)))
        XCTAssertEqual(error.status, .error)
        XCTAssertEqual(error.httpStatus, 400)
        XCTAssertTrue(error.detail?.contains("Invalid parameter") == true)
        XCTAssertEqual(MetaDdl.parse(.failure("offline")).status, .error)
    }

    func testTikTokRequestMirrorsTheBusinessSdk() throws {
        let request = try XCTUnwrap(TikTokDdl.request(tiktokAppId: "7671310127875112981", storeAppId: "6748651210",
                                                      facts: facts, att: .authorized, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(request.url.absoluteString, "https://analytics.us.tiktok.com/api/v1/app_sdk/ddl")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(body["tiktok_app_id"] as? String, "7671310127875112981")
        let context = try XCTUnwrap(body["context"] as? [String: Any])
        let app = try XCTUnwrap(context["app"] as? [String: Any])
        XCTAssertEqual(app["id"] as? String, "6748651210")
        XCTAssertEqual(app["namespace"] as? String, "com.acme.app")
        let device = try XCTUnwrap(context["device"] as? [String: Any])
        XCTAssertEqual(device["att_status"] as? String, "AUTHORIZED")
        XCTAssertEqual(device["idfa"] as? String, facts.idfa)
        XCTAssertEqual(device["locale"] as? String, "en-US/US")
        XCTAssertEqual(body["timestamp"] as? String, "1970-01-01T00:00:00.000Z")
    }

    func testTikTokWithoutTrackingSendsTheStatusAndNoIdfa() throws {
        for (att, name) in [(KerdlyAttStatus.denied, "DENIED"), (.restricted, "RESTRICTED"), (.notDetermined, "NOT_DETERMINED")] {
            let request = try XCTUnwrap(TikTokDdl.request(tiktokAppId: "7671310127875112981", storeAppId: nil,
                                                          facts: facts, att: att, now: Date(timeIntervalSince1970: 0)))
            XCTAssertEqual(request.url.absoluteString, "https://analytics.us.tiktok.com/api/v1/app_sdk/ddl", "the same host")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
            let device = try XCTUnwrap((body["context"] as? [String: Any])?["device"] as? [String: Any])
            XCTAssertEqual(device["att_status"] as? String, name)
            XCTAssertEqual(device["idfa"] as? String, "", "the IDFA never goes without tracking authorized")
            XCTAssertEqual(device["idfv"] as? String, "IDFV-1")
        }
    }

    func testTikTokAnswers() {
        let link = TikTokDdl.parse(.response(status: 200, headers: [:],
            body: Data(#"{"code":0,"message":"OK","data":{"ddl":"com.acme.app://kerdly?ad_id=2"}}"#.utf8)))
        XCTAssertEqual(link.status, .link)
        XCTAssertEqual(link.url, "com.acme.app://kerdly?ad_id=2")
        XCTAssertEqual(TikTokDdl.parse(.response(status: 200, headers: [:], body: Data(#"{"code":0,"data":{}}"#.utf8))).status, .none)
        let error = TikTokDdl.parse(.response(status: 200, headers: [:], body: Data(#"{"code":40001,"message":"not allowed"}"#.utf8)))
        XCTAssertEqual(error.status, .error)
        XCTAssertEqual(error.detail, "40001 not allowed")
    }

    // MARK: Through the core

    static let metaLink = "com.acme.app://onboarding?utm_source=meta&campaign_id=1&adset_id=2&ad_id=3"

    /// Files holding a fresh cached config whose `ddl` block is `ddl`.
    func cachedConfig(ddl: JSONValue) throws -> InMemoryFiles {
        var body = try XCTUnwrap(Fixtures.json("config.response.json").objectValue)
        body["ddl"] = ddl
        let files = InMemoryFiles()
        StateStore(files: files).save(config: ConfigCache.first(body: .object(body), etag: Harness.configEtag,
                                                                fetchedAt: Clocks.ms(Harness.start), appVersion: "5.12"))
        return files
    }

    static let enabled: JSONValue = .object([
        "enabled": .bool(true), "max_age_h": .int(47),
        "meta": .object(["app_id": .null, "client_token": .null]),
        "tiktok": .object(["app_id": .string("7600000000000000001"), "store_app_id": .string("6748651210")]),
    ])

    /// A harness that accepts every batch and answers the networks with `meta` / `tiktok`.
    func harness(ddl: JSONValue = DeferredLinkTests.enabled, att: KerdlyAttStatus = .authorized,
                 defaults: FakeDefaults = FakeDefaults(),
                 meta: @escaping @Sendable () -> HTTPResult = { .response(status: 200, headers: [:],
                     body: Data(#"{"applink_url":"\#(DeferredLinkTests.metaLink)","click_time":"1760396400"}"#.utf8)) },
                 tiktok: @escaping @Sendable () -> HTTPResult = { .response(status: 200, headers: [:],
                     body: Data(#"{"code":0,"message":"OK","data":{"ddl":""}}"#.utf8)) }) throws -> Harness {
        let h = Harness(defaults: defaults, files: try cachedConfig(ddl: ddl))
        h.tracking.current.set(att)
        h.serveAcceptAll()
        let accept = h.transport.respond
        h.transport.respond = { request in
            switch request.url.host {
            case "ep1.facebook.com", "ep2.facebook.com": return meta()
            case "analytics.us.tiktok.com": return tiktok()
            default: return accept(request)
            }
        }
        return h
    }

    static let networkHosts: Set<String> = ["ep1.facebook.com", "ep2.facebook.com", "analytics.us.tiktok.com"]

    func networkRequests(_ h: Harness) -> [String] {
        h.transport.sent.compactMap { $0.url.host }.filter { Self.networkHosts.contains($0) }
    }

    func deferredSignals(_ h: Harness) -> [JSONValue] {
        h.transport.sentEvents.filter { $0["props"]?["kind"] == .string("deferred_link") }.compactMap { $0["props"] }
    }

    func testOffUnlessTheConfigTurnsItOn() throws {
        let h = try harness(ddl: .object(["enabled": .bool(false), "max_age_h": .int(47), "meta": .null, "tiktok": .null]))
        h.configure()
        XCTAssertEqual(networkRequests(h), [])
        XCTAssertEqual(deferredSignals(h), [])
    }

    func testTheInstallLaunchAsksEachNetworkOnceAndReportsTheAnswers() throws {
        let h = try harness()
        h.configure()
        XCTAssertEqual(Set(networkRequests(h)), ["ep1.facebook.com", "analytics.us.tiktok.com"])
        let signals = deferredSignals(h)
        let meta = try XCTUnwrap(signals.first { $0["network"] == .string("meta") })
        XCTAssertEqual(meta["status"], .string("link"))
        XCTAssertEqual(meta["url"], .string(Self.metaLink))
        XCTAssertEqual(meta["click_ts"], .int(1_760_396_400_000))
        XCTAssertEqual(meta["attempt"], .int(1))
        XCTAssertEqual(meta["att"], .string("authorized"))
        XCTAssertEqual(signals.first { $0["network"] == .string("tiktok") }?["status"], .string("none"))
        XCTAssertEqual(h.state.ddl["meta"]?.done, true)

        // A later foreground asks nobody again.
        h.lifecycle.send(.willEnterForeground)
        h.settle()
        XCTAssertEqual(networkRequests(h).count, 2)
    }

    func testWaitsForTrackingAndNeverAsksWithoutIt() throws {
        let h = try harness(att: .notDetermined)
        h.configure()
        XCTAssertEqual(networkRequests(h), [], "no request before the user allowed tracking")
        XCTAssertEqual(deferredSignals(h), [])

        h.tracking.current.set(.authorized)
        h.lifecycle.send(.didBecomeActive)
        h.settle()
        XCTAssertEqual(Set(networkRequests(h)), ["ep1.facebook.com", "analytics.us.tiktok.com"])

        let denied = try harness(att: .denied)
        denied.configure()
        denied.lifecycle.send(.willEnterForeground)
        denied.settle()
        XCTAssertEqual(networkRequests(denied), [])
    }

    static let withoutAtt: JSONValue = .object([
        "enabled": .bool(true), "max_age_h": .int(47), "require_att": .bool(false),
        "meta": .object(["app_id": .null, "client_token": .null]),
        "tiktok": .object(["app_id": .string("7600000000000000001"), "store_app_id": .string("6748651210")]),
    ])

    func request(_ h: Harness, host: String) -> HTTPRequest? {
        h.transport.sent.first { $0.url.host == host }
    }

    func testWithoutRequireAttADeniedUserIsAskedWithoutTheIdfa() throws {
        let h = try harness(ddl: Self.withoutAtt, att: .denied)
        h.configure()
        XCTAssertEqual(Set(networkRequests(h)), ["ep2.facebook.com", "analytics.us.tiktok.com"])
        XCTAssertEqual(h.advertisingId.calls.get(), 0, "the IDFA is never read")

        let meta = form(try XCTUnwrap(request(h, host: "ep2.facebook.com")))
        XCTAssertNil(meta["advertiser_id"])
        XCTAssertEqual(meta["advertiser_tracking_enabled"], "0")
        let tiktok = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(request(h, host: "analytics.us.tiktok.com")?.body)) as? [String: Any])
        let device = try XCTUnwrap((tiktok["context"] as? [String: Any])?["device"] as? [String: Any])
        XCTAssertEqual(device["att_status"] as? String, "DENIED")
        XCTAssertEqual(device["idfa"] as? String, "")

        let signal = try XCTUnwrap(deferredSignals(h).first { $0["network"] == .string("meta") })
        XCTAssertEqual(signal["status"], .string("link"))
        XCTAssertEqual(signal["att"], .string("denied"))
        XCTAssertEqual(h.state.ddl["meta"]?.done, true)

        // Allowing tracking later asks nobody again: each network answers once.
        h.tracking.current.set(.authorized)
        h.lifecycle.send(.didBecomeActive)
        h.settle()
        XCTAssertEqual(networkRequests(h).count, 2)
    }

    func testWithoutRequireAttARestrictedUserIsAsked() throws {
        let h = try harness(ddl: Self.withoutAtt, att: .restricted)
        h.configure()
        XCTAssertEqual(Set(networkRequests(h)), ["ep2.facebook.com", "analytics.us.tiktok.com"])
    }

    func testWithoutRequireAttStillWaitsForThePrompt() throws {
        let h = try harness(ddl: Self.withoutAtt, att: .notDetermined)
        h.configure()
        h.lifecycle.send(.willEnterForeground)
        h.settle()
        XCTAssertEqual(networkRequests(h), [], "not before the ATT prompt is answered")

        h.tracking.current.set(.denied)
        h.lifecycle.send(.didBecomeActive)
        h.settle()
        XCTAssertEqual(Set(networkRequests(h)), ["ep2.facebook.com", "analytics.us.tiktok.com"])
    }

    func testWithoutRequireAttAnAllowedUserIsStillAskedWithTheIdfa() throws {
        let h = try harness(ddl: Self.withoutAtt, att: .notDetermined)
        h.configure()
        h.tracking.current.set(.authorized)
        h.lifecycle.send(.didBecomeActive)
        h.settle()
        XCTAssertEqual(Set(networkRequests(h)), ["ep1.facebook.com", "analytics.us.tiktok.com"])
        XCTAssertEqual(form(try XCTUnwrap(request(h, host: "ep1.facebook.com")))["advertiser_id"],
                       "6D92078A-8246-4BA4-AE5B-76104861E7DC")
    }

    func testRequireAttIsTheDefault() {
        XCTAssertEqual(DdlConfig.parse(Self.enabled)?.requireAtt, true)
        XCTAssertEqual(DdlConfig.parse(.object(["enabled": .bool(true), "require_att": .bool(true)]))?.requireAtt, true)
        XCTAssertEqual(DdlConfig.parse(Self.withoutAtt)?.requireAtt, false)
    }

    func testRequireAttKeepsADeniedUserUnasked() throws {
        var ddl = try XCTUnwrap(Self.withoutAtt.objectValue)
        ddl["require_att"] = .bool(true)
        let h = try harness(ddl: .object(ddl), att: .denied)
        h.configure()
        h.lifecycle.send(.willEnterForeground)
        h.settle()
        XCTAssertEqual(networkRequests(h), [])
    }

    // MARK: Debug

    func debugAnswers(_ h: Harness, ignoreAtt: Bool) -> [DdlAnswer] {
        let done = expectation(description: "answers")
        let answers = Locked<[DdlAnswer]>([])
        h.core.apiDebugFetchDeferredLinks(tiktokAppId: "7600000000000000001", storeAppId: nil, ignoreAtt: ignoreAtt) {
            answers.set($0)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return answers.get()
    }

    func testDebugSkipsWithoutTrackingUnlessToldToIgnoreIt() throws {
        let h = try harness(att: .denied)
        XCTAssertEqual(debugAnswers(h, ignoreAtt: false).map(\.status), [.skippedAtt, .skippedAtt])
        XCTAssertEqual(networkRequests(h), [])

        let answers = debugAnswers(h, ignoreAtt: true)
        XCTAssertEqual(answers.map(\.network), ["meta", "tiktok"])
        XCTAssertEqual(answers.map(\.status), [.link, .none])
        XCTAssertEqual(Set(networkRequests(h)), ["ep2.facebook.com", "analytics.us.tiktok.com"])
        XCTAssertEqual(h.advertisingId.calls.get(), 0)
    }

    func testDebugIgnoringAttWithoutAnIdfaUsesTheShapeWithoutTracking() throws {
        let h = try harness(att: .authorized)
        h.advertisingId.idfa.set(nil)
        XCTAssertEqual(debugAnswers(h, ignoreAtt: false).map(\.detail), ["no IDFA", "no IDFA"])
        _ = debugAnswers(h, ignoreAtt: true)
        XCTAssertEqual(Set(networkRequests(h)), ["ep2.facebook.com", "analytics.us.tiktok.com"])
    }

    func testTheAdsConsentGatesIt() throws {
        let h = try harness()
        h.core.apiSetConsent(analytics: nil, ads: false)
        h.configure()
        XCTAssertEqual(networkRequests(h), [])
    }

    func testAFailureInTransitIsRetriedOnAForegroundAndGivenUpAfterThree() throws {
        let failing = Locked(true)
        let h = try harness(meta: {
            failing.get() ? .failure("offline") : .response(status: 200, headers: [:], body: Data("{}".utf8))
        })
        h.configure()
        XCTAssertNil(deferredSignals(h).first { $0["network"] == .string("meta") }, "no signal for a failure in transit")
        XCTAssertEqual(h.state.ddl["meta"], DdlNetworkState(done: false, failures: 1))

        h.lifecycle.send(.willEnterForeground)
        h.settle()
        XCTAssertEqual(h.state.ddl["meta"]?.failures, 2)
        h.lifecycle.send(.willEnterForeground)
        h.settle()
        let meta = try XCTUnwrap(deferredSignals(h).first { $0["network"] == .string("meta") })
        XCTAssertEqual(meta["status"], .string("error"))
        XCTAssertEqual(meta["attempt"], .int(3))
        XCTAssertEqual(h.state.ddl["meta"]?.done, true)

        failing.set(false)
        h.lifecycle.send(.willEnterForeground)
        h.settle()
        XCTAssertEqual(networkRequests(h).filter { $0 == "ep1.facebook.com" }.count, 3, "never asked after giving up")
    }

    func testARefusalIsFinal() throws {
        let h = try harness(meta: { .response(status: 400, headers: [:], body: Data(#"{"error":{"code":100,"message":"bad"}}"#.utf8)) })
        h.configure()
        let meta = try XCTUnwrap(deferredSignals(h).first { $0["network"] == .string("meta") })
        XCTAssertEqual(meta["status"], .string("error"))
        XCTAssertEqual(meta["http_status"], .int(400))
        XCTAssertEqual(h.state.ddl["meta"]?.done, true)
    }

    func testARestoreIsNeverAsked() throws {
        // UserDefaults holds an id the empty Keychain lacks: a backup restored onto this phone.
        let h = try harness(defaults: FakeDefaults([KerdlyCore.defaultsInstallIdKey: "1d2c3b4a-0000-4000-8000-000000000001"]))
        h.configure()
        XCTAssertEqual(h.state.ddlEligible, false)
        XCTAssertEqual(networkRequests(h), [])
    }

    func testNotAskedAfterTheAgeWindow() throws {
        let h = try harness(att: .notDetermined)
        h.configure()
        h.clock.advance(48 * 3_600)
        h.tracking.current.set(.authorized)
        h.lifecycle.send(.didBecomeActive)
        h.settle()
        XCTAssertEqual(networkRequests(h), [])
    }

    func testMetaWithoutIdsReportsNotConfiguredAndTikTokStillGoes() throws {
        let h = try harness()
        h.device.ddlBundle.set(DeferredLinkBundle(metaAppId: nil, metaClientToken: nil, urlSchemes: [], appName: "Acme", regionCode: "US"))
        h.configure()
        XCTAssertEqual(networkRequests(h), ["analytics.us.tiktok.com"])
        XCTAssertEqual(deferredSignals(h).first { $0["network"] == .string("meta") }?["status"], .string("not_configured"))
    }
}

