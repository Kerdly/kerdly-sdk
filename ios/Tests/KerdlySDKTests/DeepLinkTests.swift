import XCTest
@testable import KerdlySDK

/// Parsing, `$deeplink`, and pending replay of attribution-bearing links.
final class DeepLinkTests: XCTestCase {
    func parse(_ string: String) -> ParsedDeepLink? {
        DeepLinkParser.parse(URL(string: string)!)
    }

    func testAcmeProductPageLink() throws {
        let link = try XCTUnwrap(parse("com.acme.app://onboarding?cpp=california&ppid=ce3a1b2c-0000-4000-8000-000000000001"))
        XCTAssertEqual(link.cpp, "california")
        XCTAssertEqual(link.ppid, "ce3a1b2c-0000-4000-8000-000000000001")
        XCTAssertNil(link.clickId)
        XCTAssertTrue(link.isAttributionBearing)
    }

    func testParamsAreReadWhateverTheSchemeHostOrPath() throws {
        let universal = try XCTUnwrap(parse("https://go.acme-app.com/l/abc?kerdly_c=k3f9q2xab7mn&kerdly_v=v123&utm_source=meta"))
        XCTAssertEqual(universal.clickId, "k3f9q2xab7mn")
        XCTAssertEqual(universal.visitId, "v123")
        XCTAssertEqual(universal.props["kerdly_c"], .string("k3f9q2xab7mn"))
        XCTAssertEqual(universal.props["kerdly_v"], .string("v123"))
        let appLink = try XCTUnwrap(parse("acmeapp://acme-app.com/lp/failing-exam?campaign_ids=ARFkbV9lbmM%3D&x=1"))
        XCTAssertEqual(appLink.campaignIds, "ARFkbV9lbmM=")
        XCTAssertFalse(appLink.isAttributionBearing, "campaign_ids alone is kept but not pending")
    }

    func testLinksMadeBefore010AreReadUnderTheirAfrNames() throws {
        let old = try XCTUnwrap(parse("https://go.acme-app.com/l/abc?afr_c=k3f9q2xab7mn&afr_v=v123"))
        XCTAssertEqual(old.clickId, "k3f9q2xab7mn")
        XCTAssertEqual(old.visitId, "v123")
        XCTAssertTrue(old.isAttributionBearing)
        XCTAssertNil(old.props["afr_c"])
        let both = try XCTUnwrap(parse("acmeapp://open?afr_c=oldoldoldold&kerdly_c=k3f9q2xab7mn"))
        XCTAssertEqual(both.clickId, "k3f9q2xab7mn", "the current name wins")
    }

    func testAbsentAndEmptyParamsAreNil() throws {
        let link = try XCTUnwrap(parse("acmeapp://open?cpp=&ppid=%20&other=1"))
        XCTAssertNil(link.cpp)
        XCTAssertNil(link.ppid)
        XCTAssertFalse(link.isAttributionBearing)
        let bare = try XCTUnwrap(parse("acmeapp://open"))
        XCTAssertEqual(bare.props["cpp"], .null)
        XCTAssertEqual(bare.props["url"], .string("acmeapp://open"))
    }

    func testTheFirstNonEmptyValueWins() throws {
        XCTAssertEqual(try XCTUnwrap(parse("acmeapp://x?cpp=&cpp=b&cpp=c")).cpp, "b")
    }

    func testSourceIsInitialOnlyForTheLaunchURL() {
        let start = Date(timeIntervalSince1970: 1_000)
        var tracker = DeepLinkSourceTracker(configuredAt: start)
        XCTAssertEqual(tracker.source(at: start.addingTimeInterval(2)), "initial")
        XCTAssertEqual(tracker.source(at: start.addingTimeInterval(3)), "runtime")
        var late = DeepLinkSourceTracker(configuredAt: start)
        XCTAssertEqual(late.source(at: start.addingTimeInterval(120)), "runtime")
        var backgrounded = DeepLinkSourceTracker(configuredAt: start)
        backgrounded.didEnterBackground()
        XCTAssertEqual(backgrounded.source(at: start.addingTimeInterval(5)), "runtime")
    }

    func testAnExplicitSourceWinsAndUsesUpTheInferredInitial() {
        let start = Date(timeIntervalSince1970: 1_000)
        var tracker = DeepLinkSourceTracker(configuredAt: start)
        XCTAssertEqual(tracker.source(at: start.addingTimeInterval(1), explicit: "initial"), "initial")
        XCTAssertEqual(tracker.source(at: start.addingTimeInterval(2)), "runtime",
                       "an explicit initial uses up the inferred one")

        var runtimeFirst = DeepLinkSourceTracker(configuredAt: start)
        XCTAssertEqual(runtimeFirst.source(at: start.addingTimeInterval(1), explicit: "runtime"), "runtime",
                       "explicit runtime wins over the inferred initial")

        var late = DeepLinkSourceTracker(configuredAt: start)
        late.didEnterBackground()
        XCTAssertEqual(late.source(at: start.addingTimeInterval(600), explicit: "initial"), "initial",
                       "explicit initial wins over the inference")

        var unknown = DeepLinkSourceTracker(configuredAt: start)
        XCTAssertEqual(unknown.source(at: start.addingTimeInterval(1), explicit: "launch"), "initial",
                       "any other value falls back to the inference")
        XCTAssertEqual(unknown.source(at: start.addingTimeInterval(2), explicit: "INITIAL"), "runtime")
    }

    func testHandleUrlTakesAnExplicitSource() {
        let h = Harness()
        h.configure()
        _ = h.core.apiHandleUrl(URL(string: "acmeapp://open?cpp=a")!, source: "initial")
        _ = h.core.apiHandleUrl(URL(string: "acmeapp://open?cpp=b")!)
        _ = h.core.apiHandleUrl(URL(string: "acmeapp://open?cpp=c")!, source: "runtime")
        _ = h.core.apiHandleUrl(URL(string: "acmeapp://open?cpp=d")!, source: "bogus")
        h.settle()
        let links = h.queuedEvents.filter { $0.name == "$deeplink" }
        XCTAssertEqual(links.map { $0.props["cpp"] }, [.string("a"), .string("b"), .string("c"), .string("d")])
        XCTAssertEqual(links.map { $0.props["source"] }, [.string("initial"), .string("runtime"),
                                                         .string("runtime"), .string("runtime")])

        let bridge = Harness()
        _ = bridge.core.apiHandleUrl(URL(string: "acmeapp://open?cpp=x")!, source: "initial")   // before configure
        bridge.settle()
        bridge.clock.advance(120)
        bridge.configure()
        XCTAssertEqual(bridge.queuedEvents.first { $0.name == "$deeplink" }?.props["source"], .string("initial"),
                       "replayed calls keep their explicit source")
    }

    func testHandleUrlReturnsTheParamsAndEnqueues() throws {
        let h = Harness()
        h.configure()
        let link = try XCTUnwrap(h.core.apiHandleUrl(URL(string: "com.acme.app://onboarding?cpp=texas")!))
        XCTAssertEqual(link.cpp, "texas")
        h.settle()
        let event = try XCTUnwrap(h.queuedEvents.first { $0.name == "$deeplink" })
        XCTAssertEqual(event.props["source"], .string("initial"))
        XCTAssertEqual(event.props["cpp"], .string("texas"))
        XCTAssertEqual(h.state.pendingDeepLinks.map(\.id), [event.id])
    }

    func testPendingLinksReplayWithTheSameIdUntilAccepted() throws {
        let keychain = FakeKeychain(), defaults = FakeDefaults(), files = InMemoryFiles(), ids = SequentialIds()
        let first = Harness(keychain: keychain, defaults: defaults, files: files, ids: ids)
        first.configure()
        _ = first.core.apiHandleUrl(URL(string: "acmeapp://open?kerdly_c=k3f9q2xab7mn")!)
        first.settle()
        let original = try XCTUnwrap(first.state.pendingDeepLinks.first)
        // The app dies; the queue file is lost but the pending copy survives.
        files.remove(StateFiles.queue)

        let second = Harness(keychain: keychain, defaults: defaults, files: files, ids: ids)
        second.configure()
        let replayed = try XCTUnwrap(second.queuedEvents.first { $0.name == "$deeplink" })
        XCTAssertEqual(replayed, original, "same id, seq and props")
        // A batch that does not include it settles nothing about it; accepting it clears it.
        second.transport.completeNext(Harness.batchResponse(accepted: [replayed.id]))
        second.settle()
        XCTAssertTrue(second.state.pendingDeepLinks.isEmpty)

        let third = Harness(keychain: keychain, defaults: defaults, files: files, ids: ids)
        third.configure()
        XCTAssertFalse(third.queuedEvents.contains { $0.name == "$deeplink" })
    }

    func testARejectedLinkIsNotReplayed() throws {
        let h = Harness()
        h.configure()
        h.transport.completeNext(Harness.status(500))
        h.settle()
        _ = h.core.apiHandleUrl(URL(string: "acmeapp://open?cpp=x")!)
        h.settle()
        let link = try XCTUnwrap(h.state.pendingDeepLinks.first)
        h.core.apiFlush()
        h.settle()
        h.transport.completeNext(Harness.batchResponse(accepted: [], rejected: [(link.id, "invalid_props")]))
        h.settle()
        XCTAssertTrue(h.state.pendingDeepLinks.isEmpty)
    }

    func testAnalyticsConsentOffDropsDeepLinks() {
        let h = Harness()
        h.configure()
        h.core.apiSetConsent(analytics: false, ads: nil)
        _ = h.core.apiHandleUrl(URL(string: "acmeapp://open?cpp=x")!)
        h.settle()
        XCTAssertFalse(h.queuedEvents.contains { $0.name == "$deeplink" })
        XCTAssertTrue(h.state.pendingDeepLinks.isEmpty)
        XCTAssertTrue(h.queuedEvents.contains { $0.name == "$consent" })
    }
}
