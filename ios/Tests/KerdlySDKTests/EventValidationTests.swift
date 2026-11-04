import XCTest
@testable import KerdlySDK

/// Custom event names and props.
final class EventValidationTests: XCTestCase {
    func testNames() {
        for valid in ["a", "registration", "trial_start", "step_2", String(repeating: "a", count: 40)] {
            XCTAssertTrue(EventValidator.isValidName(valid), valid)
        }
        for invalid in ["", "Bad Name", "Registration", "1step", "_x", "step-2", "ünicode", "$install",
                        String(repeating: "a", count: 41), "a b", "a.b"] {
            XCTAssertFalse(EventValidator.isValidName(invalid), invalid)
        }
    }

    func testPropsKeepValidValuesAndDropTheRest() {
        let result = EventValidator.sanitize([
            "method": "anonymous",
            "count": 3,
            "ratio": 0.25,
            "whole": 2.0,
            "flag": true,
            "Bad Key": "x",
            "nested": ["a": 1],
            "list": [1, 2],
            "nan": Double.nan,
            "inf": Double.infinity,
            "date": Date(),
        ])
        XCTAssertEqual(result.props, [
            "method": .string("anonymous"),
            "count": .int(3),
            "ratio": .double(0.25),
            "whole": .int(2),
            "flag": .bool(true),
        ])
        XCTAssertEqual(result.issues.count, 6)
    }

    func testNSNumberBooleansAreBooleansAndNumbersAreNot() {
        let result = EventValidator.sanitize([
            "yes": NSNumber(value: true),
            "one": NSNumber(value: 1),
            "zero_double": NSNumber(value: 0.0),
        ])
        XCTAssertEqual(result.props["yes"], .bool(true))
        XCTAssertEqual(result.props["one"], .int(1))
        XCTAssertEqual(result.props["zero_double"], .int(0))
    }

    func testStringsAreTruncatedTo256Characters() {
        let long = String(repeating: "é", count: 300)
        let result = EventValidator.sanitize(["text": long])
        XCTAssertEqual(result.props["text"]?.stringValue?.count, 256)
        XCTAssertEqual(result.issues.count, 1)
    }

    func testAtMost25PropsInKeyOrder() {
        var props: [String: Any] = [:]
        for i in 0..<30 { props[String(format: "k%02d", i)] = i }
        let result = EventValidator.sanitize(props)
        XCTAssertEqual(result.props.count, 25)
        XCTAssertNotNil(result.props["k00"])
        XCTAssertNotNil(result.props["k24"])
        XCTAssertNil(result.props["k25"])
    }

    func testTrackDropsInvalidAndReservedNamesBeforeEnqueue() {
        let h = Harness()
        h.configure()
        h.core.apiTrack("Bad Name", properties: [:])
        h.core.apiTrack("$install", properties: [:])
        h.core.apiTrack("paywall_view", properties: ["placement": "onboarding", "bad key": 1])
        h.settle()
        let custom = h.queuedEvents.filter { !$0.isReserved }
        XCTAssertEqual(custom.map(\.name), ["paywall_view"])
        XCTAssertEqual(custom.first?.props, ["placement": .string("onboarding")])
        XCTAssertEqual(h.queuedEvents.filter { $0.name == "$install" }.count, 1)
    }

    func testUserIdIsAttachedAtEnqueueTimeAndIdentifyFiresOnChange() {
        let h = Harness()
        h.configure()
        h.core.apiTrack("before", properties: [:])
        h.core.apiSetUserId("u1")
        h.core.apiSetUserId("u1")
        h.core.apiTrack("after", properties: [:])
        h.core.apiSetUserId(nil)
        h.settle()
        let events = h.queuedEvents.filter { ["before", "after", "$identify"].contains($0.name) }
        XCTAssertEqual(events.map(\.name), ["before", "$identify", "after", "$identify"])
        XCTAssertEqual(events.map(\.userId), [nil, "u1", "u1", nil])
        XCTAssertEqual(events[3].props, ["user_id": .null, "previous_user_id": .string("u1")])
    }

    func testCallsBeforeConfigureAreReplayedInOrder() {
        let h = Harness()
        h.core.apiSetUserId("early")
        h.core.apiTrack("early_event", properties: [:])
        h.settle()
        h.configure()
        let names = h.queuedEvents.map(\.name)
        XCTAssertEqual(names, ["$install", "$open", "$identify", "early_event"])
        XCTAssertEqual(h.queuedEvents.last?.userId, "early")
    }

    func testBlockedNamesAreDroppedOnTheDevice() throws {
        let h = Harness()
        var config = try Fixtures.json("config.response.json").objectValue!
        config["events"] = .object(["block": .array([.string("paywall_view")])])
        h.serveAcceptAll(config: .object(config))
        h.configure()
        h.core.apiTrack("paywall_view", properties: [:])
        h.core.apiTrack("registration", properties: [:])
        h.settle()
        XCTAssertFalse(h.transport.sentEvents.contains { $0["name"] == .string("paywall_view") })
        XCTAssertFalse(h.queuedEvents.contains { $0.name == "paywall_view" })
    }
}
