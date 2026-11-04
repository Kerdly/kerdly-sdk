import XCTest
@testable import KerdlySDK

/// The public IPv6, looked up once on the `$install` launch and sent as a
/// `public_ip` signal when the answer is a global unicast IPv6 address.
final class PublicIpTests: XCTestCase {
    func publicIpSignals(_ events: [QueuedEvent]) -> [QueuedEvent] {
        events.filter { $0.name == "$signal" && $0.props["kind"] == .string("public_ip") }
    }

    func sentPublicIp(_ h: Harness) -> [JSONValue] {
        h.transport.sentEvents.filter { $0["props"]?["kind"] == .string("public_ip") }
    }

    /// Files holding a fresh cached config (the fixture, changed by `mutate`).
    func cachedConfig(_ mutate: (inout [String: JSONValue]) -> Void) throws -> InMemoryFiles {
        var body = try XCTUnwrap(Fixtures.json("config.response.json").objectValue)
        mutate(&body)
        let files = InMemoryFiles()
        StateStore(files: files).save(config: ConfigCache.first(body: .object(body), etag: Harness.configEtag,
                                                                fetchedAt: Clocks.ms(Harness.start), appVersion: "5.12"))
        return files
    }

    // MARK: The address check

    func testGlobalUnicastAddressesAreCanonicalized() {
        XCTAssertEqual(PublicIPv6.globalUnicast("2001:DB8:0:0:0:0:0:1"), "2001:db8::1")
        XCTAssertEqual(PublicIPv6.globalUnicast(" 2606:4700:4700::1111\n"), "2606:4700:4700::1111")
        XCTAssertEqual(PublicIPv6.globalUnicast("2a02:6b8:0:0:1:0:0:5"), "2a02:6b8::1:0:0:5")
        XCTAssertEqual(PublicIPv6.globalUnicast("2001:db8:0:1:1:1:1:1"), "2001:db8:0:1:1:1:1:1",
                       "a single zero group is not shortened")
        XCTAssertEqual(PublicIPv6.globalUnicast("3fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"),
                       "3fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "the top of 2000::/3")
    }

    func testEverythingButGlobalUnicastIsRejected() {
        let rejected = [
            "203.0.113.7",                 // IPv4
            "::ffff:203.0.113.7",          // IPv4-mapped
            "::1", "::",                   // loopback, unspecified
            "fe80::1c2b:3aff:fe4d:5e6f",   // link-local
            "fe80::1%en0",                 // a zone id
            "fd12:3456:789a::1", "fc00::1",// unique-local
            "ff02::1",                     // multicast
            "1fff:ffff::1", "4000::1",     // outside 2000::/3
            "2001:db8::1::2", "2001:db8::g", "2001:db8:1:2:3:4:5:6:7",
            "", "   ", "not an address", "{\"ip\":\"2001:db8::1\"}",
            "2001:db8::1\u{0}junk",        // a NUL would end the C string early
        ]
        for text in rejected {
            XCTAssertNil(PublicIPv6.globalUnicast(text), text)
        }
    }

    // MARK: Through the core

    func testTheInstallLaunchLooksItUpOnceThisVersionsConfigIsIn() throws {
        let h = Harness()
        h.holdEverything()
        h.publicIp.answer.set("2001:DB8:0:0:0:0:0:1")
        h.configure()
        XCTAssertTrue(h.publicIp.lookups.get().isEmpty, "no request before this version's config is in")
        h.transport.completeNext(Harness.configResponse(), path: "/v1/sdk/config")
        h.settle()
        XCTAssertEqual(h.publicIp.lookups.get(), [RemoteConfig.defaultIpv6EchoUrl])
        let signals = publicIpSignals(h.queuedEvents)
        XCTAssertEqual(signals.map(\.props), [["kind": .string("public_ip"), "ipv6": .string("2001:db8::1")]])
    }

    func testTheInstallFlushNeverWaitsForTheLookup() throws {
        let h = Harness()
        h.serveAcceptAll()
        h.publicIp.answer.set("2001:db8:85a3::8a2e:370:7334")
        h.publicIp.hold.set(true)
        h.configure()
        XCTAssertEqual(h.publicIp.lookups.get().count, 1)
        let first = try XCTUnwrap(h.transport.batches.first?["events"]?.arrayValue)
        XCTAssertEqual(first.first?["name"], .string("$install"), "the install batch went without it")
        XCTAssertTrue(sentPublicIp(h).isEmpty)

        h.publicIp.releaseHeld()
        h.settle()
        let sent = sentPublicIp(h)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["name"], .string("$signal"))
        XCTAssertEqual(sent.first?["props"], .object(["kind": .string("public_ip"),
                                                      "ipv6": .string("2001:db8:85a3::8a2e:370:7334")]))
    }

    func testALaunchWithoutAnInstallNeverLooksItUp() {
        let keychain = FakeKeychain(), defaults = FakeDefaults(), files = InMemoryFiles()
        let first = Harness(keychain: keychain, defaults: defaults, files: files)
        first.serveAcceptAll()
        first.configure()   // the fake answers nil: an IPv4-only network
        XCTAssertEqual(first.publicIp.lookups.get().count, 1)
        XCTAssertTrue(sentPublicIp(first).isEmpty, "a failed lookup sends nothing")

        let next = Harness(keychain: keychain, defaults: defaults, files: files)
        next.serveAcceptAll()
        next.publicIp.answer.set("2001:db8::1")
        next.configure()
        next.lifecycle.send(.didEnterBackground)
        next.settle()
        next.clock.advance(31 * 60)
        next.lifecycle.send(.willEnterForeground)
        next.settle()
        XCTAssertFalse(next.transport.sentEvents.contains { $0["name"] == .string("$install") })
        XCTAssertTrue(next.publicIp.lookups.get().isEmpty, "only the $install launch; a failure is never retried")
        XCTAssertTrue(sentPublicIp(next).isEmpty)
    }

    func testAdsConsentOffNeverReadsIt() {
        let h = Harness()
        h.serveAcceptAll()
        h.publicIp.answer.set("2001:db8::1")
        h.core.apiSetConsent(analytics: nil, ads: false)   // before configure: replayed at start
        h.configure()
        XCTAssertTrue(h.publicIp.lookups.get().isEmpty, "ads consent off: never looked up")
        XCTAssertTrue(sentPublicIp(h).isEmpty)

        let late = Harness()
        late.serveAcceptAll()
        late.publicIp.answer.set("2001:db8::1")
        late.publicIp.hold.set(true)
        late.configure()
        late.core.apiSetConsent(analytics: nil, ads: false)
        late.settle()
        late.publicIp.releaseHeld()
        late.settle()
        XCTAssertEqual(late.publicIp.lookups.get().count, 1)
        XCTAssertTrue(publicIpSignals(late.queuedEvents).isEmpty && sentPublicIp(late).isEmpty,
                      "an answer that arrives after ads consent went off is dropped")
    }

    func testTheConfigTurnsItOffAndPicksTheEchoUrl() throws {
        let off = Harness(files: try cachedConfig { body in
            var collect = body["collect"]?.objectValue ?? [:]
            collect["public_ip"] = .bool(false)
            body["collect"] = .object(collect)
        })
        off.serveAcceptAll()
        off.publicIp.answer.set("2001:db8::1")
        off.configure()
        XCTAssertTrue(off.publicIp.lookups.get().isEmpty, "collect.public_ip false: never looked up")
        XCTAssertTrue(sentPublicIp(off).isEmpty)

        let custom = Harness(files: try cachedConfig { $0["ipv6_echo_url"] = .string("https://echo6.example.com/ip?format=json") })
        custom.serveAcceptAll()
        custom.configure()
        XCTAssertEqual(custom.publicIp.lookups.get().map(\.absoluteString), ["https://echo6.example.com/ip?format=json"])

        // No cached config: nothing is looked up before the fetched config says whether to.
        var body = try XCTUnwrap(Fixtures.json("config.response.json").objectValue)
        body["collect"] = .object(["public_ip": .bool(false)])
        let fetched = Harness()
        fetched.serveAcceptAll(config: .object(body))
        fetched.publicIp.answer.set("2001:db8::1")
        fetched.configure()
        XCTAssertTrue(fetched.publicIp.lookups.get().isEmpty, "the fetched config turns it off before it starts")
        XCTAssertTrue(sentPublicIp(fetched).isEmpty)
    }

    func testAnswersThatAreNotGlobalIPv6AreDropped() {
        for answer in ["203.0.113.7", "::ffff:203.0.113.7", "fe80::1", "fd00::1", "garbage"] {
            let h = Harness()
            h.serveAcceptAll()
            h.publicIp.answer.set(answer)
            h.configure()
            XCTAssertEqual(h.publicIp.lookups.get().count, 1, answer)
            XCTAssertTrue(publicIpSignals(h.queuedEvents).isEmpty && sentPublicIp(h).isEmpty, answer)
        }
    }
}
