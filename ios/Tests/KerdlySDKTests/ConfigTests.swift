import XCTest
@testable import KerdlySDK

/// The remote config, its cache and the kill switch.
final class ConfigTests: XCTestCase {
    func testTheFixtureParses() throws {
        let config = RemoteConfig.parse(try Fixtures.json("config.response.json"), previousValidSkan: nil)
        XCTAssertEqual(config.version, 1)
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.maxBatch, 50)
        XCTAssertEqual(config.queueFlushAt, 20)
        XCTAssertEqual(config.flushInterval, 15)
        XCTAssertTrue(config.collectAsaToken && config.collectAppTransaction && config.collectPurchases && config.collectAdvertisingId)
        XCTAssertEqual(config.skan?.rungs.count, 4)
        XCTAssertEqual(config.skan?.enabled, false)
        XCTAssertEqual(config.minSupportedSdk, "0.1.0")
        XCTAssertFalse(config.isBelowMinimum(sdkVersion: KerdlyCore.sdkVersion))
    }

    func testDefaultsClampsAndFallbacks() throws {
        let previous = try XCTUnwrap(RemoteConfig.parse(try Fixtures.json("config.response.json"), previousValidSkan: nil).skan)
        let config = RemoteConfig.parse(.object([
            "flush": .object(["max_batch": .int(500), "queue_flush_at": .int(0), "interval_s": .int(1_000_000)]),
            "collect": .object(["asa_token": .bool(false)]),
            "skan": .object(["version": .int(9), "rungs": .array([.string("nonsense")])]),
            "debug_devices": .array([.string("abc")]),
            "events": .object(["block": .array([.string("paywall_view")])]),
        ]), previousValidSkan: previous)
        XCTAssertTrue(config.enabled, "a missing kill switch means enabled")
        XCTAssertEqual(config.maxBatch, 50)
        XCTAssertEqual(config.queueFlushAt, 1)
        XCTAssertEqual(config.flushInterval, 3_600)
        XCTAssertFalse(config.collectAsaToken)
        XCTAssertTrue(config.collectPurchases)
        XCTAssertEqual(config.skan, previous, "an invalid ladder falls back to the last valid one")
        XCTAssertEqual(config.debugDevices, ["abc"])
        XCTAssertEqual(config.blockedEvents, ["paywall_view"])
        XCTAssertNil(RemoteConfig.parse(.object(["skan": .null]), previousValidSkan: previous).skan,
                     "skan: null turns the writer off")
    }

    func testPublicIpSwitchAndHttpsOnlyEchoUrl() throws {
        let fixture = RemoteConfig.parse(try Fixtures.json("config.response.json"), previousValidSkan: nil)
        XCTAssertTrue(fixture.collectPublicIp, "absent means on")
        XCTAssertEqual(fixture.ipv6EchoUrl.absoluteString, "https://api6.ipify.org?format=json")

        let set = RemoteConfig.parse(.object([
            "collect": .object(["public_ip": .bool(false)]),
            "ipv6_echo_url": .string("HTTPS://echo6.example.com/ip?format=json"),
        ]), previousValidSkan: nil)
        XCTAssertFalse(set.collectPublicIp)
        XCTAssertTrue(set.collectAdvertisingId, "the other switches keep their defaults")
        XCTAssertEqual(set.ipv6EchoUrl.absoluteString, "HTTPS://echo6.example.com/ip?format=json")
        XCTAssertTrue(RemoteConfig.parse(.object(["collect": .object(["public_ip": .string("no")])]),
                                         previousValidSkan: nil).collectPublicIp, "a non-bool keeps the default")

        let notHttps: [JSONValue] = [.string("http://echo6.example.com/ip"), .string("ftp://echo6.example.com/ip"),
                                     .string("https://"), .string("echo6.example.com/ip"), .string("not a url"),
                                     .string(""), .int(1), .null]
        for raw in notHttps {
            XCTAssertEqual(RemoteConfig.parse(.object(["ipv6_echo_url": raw]), previousValidSkan: nil).ipv6EchoUrl,
                           RemoteConfig.defaultIpv6EchoUrl, "\(raw) keeps the default")
        }
    }

    func testCacheStalenessAndLastValidLadder() throws {
        let body = try Fixtures.json("config.response.json")
        let fetched = Date(timeIntervalSince1970: 1_760_400_000)
        let cache = ConfigCache.first(body: body, etag: "\"1\"", fetchedAt: Clocks.ms(fetched), appVersion: "5.12")
        XCTAssertFalse(cache.isStale(now: fetched.addingTimeInterval(5 * 3_600)))
        XCTAssertTrue(cache.isStale(now: fetched.addingTimeInterval(6 * 3_600)))
        var broken = body.objectValue!
        broken["skan"] = .object(["rungs": .array([])  , "version": .int(2), "enabled": .bool(true)])
        broken["skan"] = .object(["rungs": .array([.object(["event": .string("x"), "fine": .int(99), "coarse": .string("low")])])])
        let next = cache.replacing(body: .object(broken), etag: "\"2\"", fetchedAt: Clocks.ms(fetched), appVersion: "5.12")
        XCTAssertEqual(next.config.skan?.rungs.count, 4, "the last valid ladder survives a bad one")
        XCTAssertEqual(next.etag, "\"2\"")
    }

    func testSemanticVersions() {
        XCTAssertEqual(SemanticVersion.compare("0.1.0", "0.1.0"), 0)
        XCTAssertEqual(SemanticVersion.compare("0.1.0", "0.2.0"), -1)
        XCTAssertEqual(SemanticVersion.compare("0.10.0", "0.9.9"), 1)
        XCTAssertEqual(SemanticVersion.compare("1.0", "1.0.0"), 0)
        XCTAssertEqual(SemanticVersion.compare("1.2.0-beta", "1.2.0"), 0)
    }

    // MARK: Through the core

    func testAFreshCacheIsNotRefetchedAtLaunchAndAStaleOneIsWithItsEtag() throws {
        let keychain = FakeKeychain(), defaults = FakeDefaults(), files = InMemoryFiles()
        let first = Harness(keychain: keychain, defaults: defaults, files: files)
        first.serveAcceptAll()
        first.configure()
        XCTAssertEqual(first.transport.requests(path: "/v1/sdk/config").count, 1)
        XCTAssertNil(first.transport.requests(path: "/v1/sdk/config").first?.headers["If-None-Match"])

        let soon = Harness(keychain: keychain, defaults: defaults, files: files)
        soon.serveAcceptAll()
        soon.clock.advance(3_600)
        soon.configure()
        XCTAssertEqual(soon.transport.requests(path: "/v1/sdk/config").count, 0, "cached for 6 h")

        let later = Harness(keychain: keychain, defaults: defaults, files: files)
        later.transport.respond = { request in
            request.url.path.hasSuffix("/v1/sdk/config")
                ? .response(status: 304, headers: [:], body: Data()) : Harness.batchResponse(accepted: [])
        }
        later.clock.advance(7 * 3_600)
        later.configure()
        let refetch = try XCTUnwrap(later.transport.requests(path: "/v1/sdk/config").first)
        XCTAssertEqual(refetch.headers["If-None-Match"], Harness.configEtag)
        XCTAssertEqual(refetch.method, "GET")
        XCTAssertEqual(refetch.headers["Authorization"], "Bearer pk_test_123")
        XCTAssertEqual(later.onQueue { $0.configCache?.fetchedAt }, Clocks.ms(Harness.start.addingTimeInterval(7 * 3_600)),
                       "a 304 renews the cache")
    }

    func testEveryRequestNamesTheAppVersion() throws {
        let h = Harness()
        h.serveAcceptAll()
        h.configure()
        h.core.apiFlush()
        h.settle()
        for path in ["/v1/sdk/config", "/v1/sdk/batch"] {
            let request = try XCTUnwrap(h.transport.requests(path: path).first, path)
            XCTAssertEqual(request.headers["X-Afr-App-Version"], "5.12", path)
            XCTAssertEqual(request.headers["X-Afr-App-Build"], "131", path)
        }
        XCTAssertEqual(h.onQueue { $0.configCache?.appVersion }, "5.12", "the cache remembers the version it is for")
    }

    func testAnAppUpdateRefetchesAFreshConfigAndTheLaunchWaitsForIt() throws {
        let keychain = FakeKeychain(), defaults = FakeDefaults(), files = InMemoryFiles()
        let old = Harness(keychain: keychain, defaults: defaults, files: files)
        old.serveAcceptAll()
        old.configure()

        let same = Harness(keychain: keychain, defaults: defaults, files: files)
        same.clock.advance(60)
        same.configure()
        XCTAssertTrue(same.onQueue { $0.launchConfigResolved }, "same version, fresh copy: no wait")
        XCTAssertEqual(same.transport.requests(path: "/v1/sdk/config").count, 0)

        let updated = Harness(keychain: keychain, defaults: defaults, files: files)
        updated.device.app.set(AppInfo(bundle: "com.acme.other", version: "5.13", build: "140"))
        updated.holdEverything()
        updated.clock.advance(60)
        updated.configure()
        let refetch = try XCTUnwrap(updated.transport.requests(path: "/v1/sdk/config").first,
                                    "a fresh copy fetched for 5.12 is fetched again for 5.13")
        XCTAssertEqual(refetch.headers["X-Afr-App-Version"], "5.13")
        XCTAssertEqual(refetch.headers["If-None-Match"], Harness.configEtag)
        XCTAssertFalse(updated.onQueue { $0.launchConfigResolved }, "the collectors wait for 5.13's config")
        updated.transport.completeNext(.response(status: 304, headers: [:], body: Data()), path: "/v1/sdk/config")
        updated.settle()
        XCTAssertTrue(updated.onQueue { $0.launchConfigResolved })
        XCTAssertEqual(updated.onQueue { $0.configCache?.appVersion }, "5.13", "a 304 for 5.13 makes the copy 5.13's")
    }

    func testNothingButTheConfigFetchGoesOutUntilThisVersionsConfigIsIn() throws {
        let h = Harness()
        h.holdEverything()
        h.publicIp.answer.set("2001:db8::1")
        h.configure()
        h.core.apiTrack("registration", properties: [:])
        h.core.apiFlush()
        h.settle()
        XCTAssertEqual(h.transport.sent.map(\.url.path), ["/api/v1/sdk/config"], "the config request is the only one")
        XCTAssertEqual(h.adServices.calls.get(), 0)
        XCTAssertTrue(h.publicIp.lookups.get().isEmpty)
        XCTAssertEqual(h.queuedEvents.map(\.name), ["$install", "$open", "registration"], "events are kept meanwhile")

        // No answer: no timeout, the fetch is asked again with a back-off, and on a foreground.
        h.transport.completeNext(.failure("offline"), path: "/v1/sdk/config")
        h.settle()
        XCTAssertTrue(h.transport.requests(path: "/v1/sdk/batch").isEmpty)
        h.scheduler.fire { $0 == 10 }   // the old fallback's delay: nothing left to fire
        h.scheduler.fire { $0 == 5 }
        h.settle()
        XCTAssertEqual(h.transport.requests(path: "/v1/sdk/config").count, 2)
        h.transport.completeNext(Harness.status(503), path: "/v1/sdk/config")
        h.settle()
        h.lifecycle.send(.willEnterForeground)
        h.settle()
        XCTAssertEqual(h.transport.requests(path: "/v1/sdk/config").count, 3, "a foreground asks at once")
        XCTAssertTrue(h.transport.requests(path: "/v1/sdk/batch").isEmpty)

        h.transport.completeNext(Harness.configResponse(), path: "/v1/sdk/config")
        h.settle()
        let batch = try XCTUnwrap(h.transport.batches.first)
        XCTAssertEqual(batch["events"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["$install", "$open", "registration"])
        XCTAssertEqual(h.publicIp.lookups.get().count, 1, "the collectors start with the config")
    }

    /// The config Kerdly serves for a switched-off version (version rules' `off`).
    static func offConfig() throws -> JSONValue {
        var body = try XCTUnwrap(Fixtures.json("config.response.json").objectValue)
        body["off"] = .bool(true)
        body["enabled"] = .bool(false)
        body["collect"] = .object((body["collect"]?.objectValue ?? [:]).mapValues { _ in .bool(false) })
        return .object(body)
    }

    func testOffRecordsCollectsAndSendsNothing() throws {
        let keychain = FakeKeychain(), defaults = FakeDefaults(), files = InMemoryFiles()
        let h = Harness(keychain: keychain, defaults: defaults, files: files)
        h.tracking.current.set(.authorized)
        h.serveAcceptAll(config: try Self.offConfig())
        h.publicIp.answer.set("2001:db8::1")
        h.configure()
        h.core.apiTrack("registration", properties: [:])
        h.core.apiSetUserId("u1")
        h.core.apiFlush()
        h.settle()
        XCTAssertEqual(h.transport.sent.map(\.url.path), ["/api/v1/sdk/config"])
        XCTAssertTrue(h.queuedEvents.isEmpty, "the launch's own events are dropped too")
        XCTAssertEqual(h.adServices.calls.get(), 0)
        XCTAssertTrue(h.publicIp.lookups.get().isEmpty)
        XCTAssertEqual(h.storeKit.appTxCalls.get(), 0)
        XCTAssertEqual(h.storeKit.entitlementCalls.get(), 0)

        // The next launch, same version, fresh copy: still nothing, not even a config fetch.
        let next = Harness(keychain: keychain, defaults: defaults, files: files)
        next.serveAcceptAll(config: try Self.offConfig())
        next.clock.advance(60)
        next.configure()
        XCTAssertTrue(next.transport.sent.isEmpty)
        XCTAssertTrue(next.queuedEvents.isEmpty)

        // Six hours on, Kerdly switched it back on: the launch fetches, then records and sends again.
        let back = Harness(keychain: keychain, defaults: defaults, files: files)
        back.serveAcceptAll()
        back.clock.advance(7 * 3_600)
        back.configure()
        back.core.apiTrack("registration", properties: [:])
        back.core.apiFlush()
        back.settle()
        let names = back.transport.sentEvents.compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(names.contains("registration"), "what follows the config that says on is sent")
        XCTAssertFalse(names.contains("$open"), "the launch's $open went with the copy that still said off")
        XCTAssertFalse(names.contains("$install"), "an install first seen while off is never reported")
    }

    func testACacheFromBeforeTheVersionStampCountsAsAnotherVersion() throws {
        let legacy = Data(#"{"etag":"\"1\"","fetched_at":1760400000100,"body":{"version":1}}"#.utf8)
        let cache = try JSONDecoder().decode(ConfigCache.self, from: legacy)
        XCTAssertNil(cache.appVersion)
        XCTAssertFalse(cache.isFor(appVersion: "5.12"))
    }

    func testTheKillSwitchStopsSendingAndKeepsOnlyReservedEvents() throws {
        var config = try Fixtures.json("config.response.json").objectValue!
        config["enabled"] = .bool(false)
        let h = Harness()
        h.serveAcceptAll(config: .object(config))
        h.configure()
        let sentBefore = h.transport.requests(path: "/v1/sdk/batch").count
        h.core.apiTrack("registration", properties: [:])
        h.core.apiSetUserId("u1")
        h.core.apiFlush()
        h.settle()
        XCTAssertEqual(h.transport.requests(path: "/v1/sdk/batch").count, sentBefore, "nothing is sent")
        XCTAssertFalse(h.queuedEvents.contains { $0.name == "registration" }, "custom events are not collected")
        XCTAssertTrue(h.queuedEvents.contains { $0.name == "$identify" }, "reserved events keep queueing")
        XCTAssertEqual(h.transport.requests(path: "/v1/sdk/attribution").count, 0)
    }

    func testAnUnsupportedSdkVersionBehavesLikeTheKillSwitch() throws {
        var config = try Fixtures.json("config.response.json").objectValue!
        config["min_supported_sdk"] = .string("9.0.0")
        let h = Harness()
        h.serveAcceptAll(config: .object(config))
        h.configure()
        let sentBefore = h.transport.requests(path: "/v1/sdk/batch").count
        h.core.apiSetUserId("u1")
        h.core.apiFlush()
        h.settle()
        XCTAssertEqual(h.transport.requests(path: "/v1/sdk/batch").count, sentBefore)
    }

    func testDebugDevicesLogVerbosely() throws {
        let h = Harness()
        h.holdEverything()
        h.configure { $0.logLevel = .warn }
        let id = try XCTUnwrap(h.core.installIdBox.get())
        XCTAssertEqual(h.core.log.currentLevel, .warn)
        var config = try Fixtures.json("config.response.json").objectValue!
        config["debug_devices"] = .array([.string(id)])
        h.transport.completeNext(.response(status: 200, headers: [:], body: KerdlyJSON.encode(JSONValue.object(config))!),
                                 path: "/v1/sdk/config")
        h.settle()
        XCTAssertEqual(h.core.log.currentLevel, .debug)
    }
}
