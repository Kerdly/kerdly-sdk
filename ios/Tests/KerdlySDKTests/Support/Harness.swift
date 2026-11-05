import Foundation
import XCTest
@testable import KerdlySDK

/// An `KerdlyCore` wired to fakes. The clock starts at the first-launch fixture's moment.
final class Harness {
    static let start = Date(timeIntervalSince1970: 1_760_400_000.100)
    static let configEtag = "\"1-5e1a\""

    let keychain: FakeKeychain
    let defaults: FakeDefaults
    let files: InMemoryFiles
    let transport = FakeTransport()
    let clock = ManualClock(Harness.start)
    let device = FakeDevice()
    let tracking = FakeTracking()
    let adServices = FakeAdServices()
    let advertisingId = FakeAdvertisingId()
    let publicIp = FakePublicIp()
    let storeKit = FakeStoreKit()
    let skanWriter = FakeSkanWriter()
    let lifecycle = FakeLifecycle()
    let ids = SequentialIds()
    let queue = DispatchQueue(label: "test.kerdly.core")
    let workQueue = DispatchQueue(label: "test.kerdly.work")
    let scheduler: ManualScheduler
    let core: KerdlyCore

    init(keychain: FakeKeychain = FakeKeychain(), defaults: FakeDefaults = FakeDefaults(),
         files: InMemoryFiles = InMemoryFiles(), ids: SequentialIds? = nil) {
        self.keychain = keychain
        self.defaults = defaults
        self.files = files
        let idSource = ids ?? SequentialIds()
        let schedulerBox = Locked<ManualScheduler?>(nil)
        let dependencies = KerdlyDependencies(
            keychain: keychain, defaults: defaults, files: files, transport: transport, clock: clock,
            device: device, tracking: tracking, adServices: adServices, advertisingId: advertisingId,
            publicIp: publicIp, storeKit: storeKit, skanWriter: skanWriter, lifecycle: lifecycle,
            makeScheduler: { queue in
                let scheduler = ManualScheduler(queue: queue)
                schedulerBox.set(scheduler)
                return scheduler
            },
            workQueue: workQueue,
            newId: { idSource.next() },
            unitRandom: { 0.5 })
        core = KerdlyCore(dependencies: dependencies, queue: queue)
        scheduler = schedulerBox.get()!
    }

    static func options(_ mutate: (inout KerdlyOptions) -> Void = { _ in }) -> KerdlyOptions {
        var options = KerdlyOptions(key: "pk_test_123", endpoint: URL(string: "https://sdk.example.com/api")!)
        options.logLevel = .none
        mutate(&options)
        return options
    }

    func configure(_ mutate: (inout KerdlyOptions) -> Void = { _ in }) {
        core.configure(Self.options(mutate))
        settle()
    }

    /// Lets the SDK queue, the work queue and main-queue hops run until nothing is left.
    func settle() {
        for _ in 0..<3 {
            for _ in 0..<10 {
                queue.sync {}
                workQueue.sync {}
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    /// Settles until `done` holds, for up to `timeout` seconds. One `settle()` can return before a
    /// long chain of queue hops ends on a slow machine (CI); this waits for the state a test needs.
    @discardableResult
    func settle(until done: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        settle()
        while !done() && Date() < deadline {
            settle()
        }
        return done()
    }

    /// Reads queue-confined state.
    func onQueue<T>(_ body: (KerdlyCore) -> T) -> T {
        queue.sync { body(core) }
    }

    var queuedEvents: [QueuedEvent] { onQueue { $0.eventQueue.events } }
    var state: PersistedState { onQueue { $0.state } }

    // MARK: Server behaviour

    /// Accepts every batch event, serves the config fixture, and has no attribution yet.
    func serveAcceptAll(config: JSONValue? = nil, attribution: [String: JSONValue]? = nil,
                        needs: [String] = []) {
        let configBody = config ?? (try? Fixtures.json("config.response.json")) ?? .object([:])
        transport.respond = { request in
            switch request.url.path {
            case let path where path.hasSuffix("/v1/sdk/batch"):
                let ids = request.body.flatMap(JSONValue.parse)?["events"]?.arrayValue?
                    .compactMap { $0["id"]?.stringValue } ?? []
                return Self.batchResponse(accepted: ids, attribution: attribution, needs: needs)
            case let path where path.hasSuffix("/v1/sdk/config"):
                return .response(status: 200, headers: ["etag": Self.configEtag], body: KerdlyJSON.encode(configBody)!)
            default:
                return .response(status: 204, headers: [:], body: Data())
            }
        }
    }

    static func batchResponse(accepted: [String], rejected: [(String, String)] = [],
                              attribution: [String: JSONValue]? = nil, needs: [String] = [],
                              etag: String = Harness.configEtag) -> HTTPResult {
        let body: JSONValue = .object([
            "accepted": .array(accepted.map { .string($0) }),
            "rejected": .array(rejected.map { .object(["id": .string($0.0), "reason": .string($0.1)]) }),
            "config_etag": .string(etag),
            "attribution": attribution.map { .object($0) } ?? .null,
            "needs": .array(needs.map { .string($0) }),
            "cv_hints": .array([]),
        ])
        return .response(status: 200, headers: [:], body: KerdlyJSON.encode(body)!)
    }

    /// What the fake server answers a config fetch with unless a test says otherwise: the fixture
    /// with every collector off and no SKAN ladder, so a test sees only the events it causes.
    static func quietConfigResponse() -> HTTPResult {
        var body = (try? Fixtures.json("config.response.json"))?.objectValue ?? [:]
        let collect = body["collect"]?.objectValue ?? [:]
        body["collect"] = .object(collect.mapValues { _ in .bool(false) })
        body["skan"] = .null
        return .response(status: 200, headers: ["etag": configEtag], body: KerdlyJSON.encode(JSONValue.object(body))!)
    }

    /// The config fixture (or `body`) as the server sends it.
    static func configResponse(_ body: JSONValue? = nil) -> HTTPResult {
        let config = body ?? (try? Fixtures.json("config.response.json")) ?? .object([:])
        return .response(status: 200, headers: ["etag": configEtag], body: KerdlyJSON.encode(config)!)
    }

    /// Serves the config fixture (or `body`) and holds every other request.
    func serveConfigOnly(_ body: JSONValue? = nil) {
        transport.respond = { request in
            request.url.path.hasSuffix("/v1/sdk/config") ? Self.configResponse(body) : nil
        }
    }

    /// Holds every request, the config fetch included, until a test completes it.
    func holdEverything() {
        transport.respond = { _ in nil }
    }

    static func status(_ code: Int, headers: [String: String] = [:], code errorCode: String? = nil) -> HTTPResult {
        let body = errorCode.map { "{\"error\":\"x\",\"code\":\"\($0)\"}" } ?? ""
        return .response(status: code, headers: headers, body: Data(body.utf8))
    }
}

enum Fixtures {
    /// `spec/fixtures`, found from this file's location (the simulator can read the host's files).
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Support
        .deletingLastPathComponent()   // KerdlySDKTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ios
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent("spec/fixtures", isDirectory: true)

    static func data(_ name: String) throws -> Data {
        let url = directory.appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw KerdlyAdapterError("fixture not found: \(url.path)")
        }
        return data
    }

    static func json(_ name: String) throws -> JSONValue {
        guard let value = JSONValue.parse(try data(name)) else { throw KerdlyAdapterError("fixture is not JSON: \(name)") }
        return value
    }
}

extension JSONValue {
    var keys: Set<String> { Set(objectValue?.keys.map { $0 } ?? []) }

    /// The JSON kind, for shape comparisons (`int` and `double` both count as a number).
    var kind: String {
        switch self {
        case .null: return "null"
        case .bool: return "bool"
        case .int, .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

/// Asserts `actual` has exactly `expected`'s keys at every object level and the same JSON kinds
/// (null matches anything: a nullable field may be filled on one side).
func assertSameShape(_ actual: JSONValue?, _ expected: JSONValue?, _ path: String = "$",
                     file: StaticString = #filePath, line: UInt = #line) {
    guard let actual, let expected else {
        XCTFail("\(path): missing (actual \(actual == nil ? "nil" : "set"), expected \(expected == nil ? "nil" : "set"))",
                file: file, line: line)
        return
    }
    if actual.isNull || expected.isNull { return }
    XCTAssertEqual(actual.kind, expected.kind, "\(path): kind", file: file, line: line)
    if let a = actual.objectValue, let e = expected.objectValue {
        XCTAssertEqual(Set(a.keys), Set(e.keys), "\(path): keys", file: file, line: line)
        for key in Set(a.keys).intersection(e.keys) {
            assertSameShape(a[key], e[key], "\(path).\(key)", file: file, line: line)
        }
    }
}
