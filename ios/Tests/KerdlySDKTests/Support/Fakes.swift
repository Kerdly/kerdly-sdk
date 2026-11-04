import Foundation
import XCTest
@testable import KerdlySDK

// Fakes for every system seam in Dependencies.swift. All are thread-safe (the core calls them from
// its queue; tests configure them from the main thread).

final class FakeKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    private var _forcedRead: KeychainRead?
    private var _writeSucceeds = true
    private var _writes: [String] = []

    init(_ value: String? = nil) { _value = value }

    var value: String? { get { locked { _value } } set { locked { _value = newValue } } }
    /// Overrides the read result (e.g. `.locked`, `.failed`).
    var forcedRead: KeychainRead? { get { locked { _forcedRead } } set { locked { _forcedRead = newValue } } }
    var writeSucceeds: Bool { get { locked { _writeSucceeds } } set { locked { _writeSucceeds = newValue } } }
    var writes: [String] { locked { _writes } }

    func readInstallId() -> KeychainRead {
        locked {
            if let forced = _forcedRead { return forced }
            return _value.map { .found($0) } ?? .notFound
        }
    }

    func writeInstallId(_ id: String) -> Bool {
        locked {
            _writes.append(id)
            guard _writeSucceeds else { return false }
            _value = id
            return true
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class FakeDefaults: DefaultsStoring, @unchecked Sendable {
    private let values = Locked<[String: Any]>([:])

    init(_ initial: [String: String] = [:]) {
        values.set(initial)
    }

    func string(forKey key: String) -> String? { values.get()[key] as? String }
    func bool(forKey key: String) -> Bool { values.get()[key] as? Bool ?? false }
    func set(_ value: String?, forKey key: String) { values.update { $0[key] = value } }
    func set(_ value: Bool, forKey key: String) { values.update { $0[key] = value } }
}

final class InMemoryFiles: FileStoring, @unchecked Sendable {
    let files = Locked<[String: Data]>([:])
    let writeCount = Locked(0)

    func read(_ name: String) -> Data? { files.get()[name] }

    @discardableResult
    func write(_ data: Data, to name: String) -> Bool {
        files.update { $0[name] = data }
        writeCount.update { $0 += 1 }
        return true
    }

    func remove(_ name: String) { files.update { $0[name] = nil } }

    func json(_ name: String) -> JSONValue? { read(name).flatMap(JSONValue.parse) }
}

/// Records requests; `respond` decides each response (nil holds the request until `complete`).
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Sent {
        let request: HTTPRequest
        let completion: @Sendable (HTTPResult) -> Void
    }

    private let lock = NSLock()
    private var _sent: [HTTPRequest] = []
    private var _held: [Sent] = []
    /// By default a quiet config is served at once (the SDK waits for its version's config before any
    /// other request) and every other request is held until a test completes it.
    private var _respond: (HTTPRequest) -> HTTPResult? = { request in
        request.url.path.hasSuffix("/v1/sdk/config") ? Harness.quietConfigResponse() : nil
    }

    var respond: (HTTPRequest) -> HTTPResult? {
        get { lock.lock(); defer { lock.unlock() }; return _respond }
        set { lock.lock(); _respond = newValue; lock.unlock() }
    }

    var sent: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return _sent }
    var held: [Sent] { lock.lock(); defer { lock.unlock() }; return _held }

    func requests(path suffix: String) -> [HTTPRequest] {
        sent.filter { $0.url.path.hasSuffix(suffix) }
    }

    var batches: [JSONValue] {
        requests(path: "/v1/sdk/batch").compactMap { $0.body.flatMap(JSONValue.parse) }
    }

    /// Every event sent in any batch, in send order.
    var sentEvents: [JSONValue] {
        batches.flatMap { $0["events"]?.arrayValue ?? [] }
    }

    func send(_ request: HTTPRequest, completion: @escaping @Sendable (HTTPResult) -> Void) {
        lock.lock()
        _sent.append(request)
        let respond = _respond
        lock.unlock()
        if let result = respond(request) {
            completion(result)
        } else {
            lock.lock()
            _held.append(Sent(request: request, completion: completion))
            lock.unlock()
        }
    }

    /// Completes the oldest held request whose path ends with `path` (a batch by default).
    func completeNext(_ result: HTTPResult, path: String = "/v1/sdk/batch") {
        lock.lock()
        guard let index = _held.firstIndex(where: { $0.request.url.path.hasSuffix(path) }) else {
            lock.unlock()
            return
        }
        let next = _held.remove(at: index)
        lock.unlock()
        next.completion(result)
    }

    func clear() {
        lock.lock()
        _sent = []
        lock.unlock()
    }
}

final class ManualClock: Clock, @unchecked Sendable {
    private let date: Locked<Date>
    init(_ date: Date) { self.date = Locked(date) }
    func now() -> Date { date.get() }
    func advance(_ seconds: TimeInterval) { date.update { $0 = $0.addingTimeInterval(seconds) } }
    func set(_ newDate: Date) { date.set(newDate) }
}

final class FakeDevice: DeviceInfoProviding, @unchecked Sendable {
    let app = Locked(AppInfo(bundle: "com.acme.other", version: "5.12", build: "131"))
    let deviceFacts = Locked(DeviceFacts(os: "26.0.1", model: "iPhone17,1", locale: "en_US",
                                         languages: ["en-US"], timeZone: "America/Chicago"))
    let deviceSnapshot = Locked(DeviceSnapshot(idfv: "5B0E7C1D-4D2B-4E0C-9F1A-2B3C4D5E6F70", screenWidth: 1206,
                                               screenHeight: 2622, screenScale: 3, isForeground: true))
    let installed = Locked<Date?>(Date(timeIntervalSince1970: 1_760_399_981))
    let environment = Locked(EnvironmentInputs(isSimulator: false, isDebugBuild: false,
                                               isDevelopmentSigned: false, receiptName: "receipt"))

    let ddlBundle = Locked(DeferredLinkBundle(metaAppId: "3198394677008326", metaClientToken: "client-token",
                                              urlSchemes: ["com.acme.app"], appName: "Acme", regionCode: "US"))

    func appInfo() -> AppInfo { app.get() }
    func facts() -> DeviceFacts { deviceFacts.get() }
    @MainActor func snapshot() -> DeviceSnapshot { deviceSnapshot.get() }
    func installedAt() -> Date? { installed.get() }
    func environmentInputs() -> EnvironmentInputs { environment.get() }
    func deferredLinkBundle() -> DeferredLinkBundle { ddlBundle.get() }
}

final class FakeTracking: TrackingAuthorizing, @unchecked Sendable {
    let current = Locked(KerdlyAttStatus.notDetermined)
    let promptable = Locked(true)
    /// What the next system request answers.
    let answer = Locked(KerdlyAttStatus.authorized)
    let requests = Locked(0)

    func status() -> KerdlyAttStatus { current.get() }
    func canPrompt() -> Bool { promptable.get() }

    func request(_ completion: @escaping @Sendable (KerdlyAttStatus) -> Void) {
        requests.update { $0 += 1 }
        let result = answer.get()
        current.set(result)
        DispatchQueue.global().async { completion(result) }
    }
}

final class FakeAdServices: AdServicesTokenProviding, @unchecked Sendable {
    let token = Locked<String?>("eyJ0b2tlbi1zYW1wbGUtYXNhIjoxfQ==")
    let calls = Locked(0)
    /// Called on each request, e.g. to record ordering against SKAN writes.
    let onCall = Locked<(@Sendable () -> Void)?>(nil)

    func attributionToken() throws -> String {
        calls.update { $0 += 1 }
        onCall.get()?()
        guard let token = token.get() else { throw KerdlyAdapterError("platformNotSupported") }
        return token
    }
}

final class FakeAdvertisingId: AdvertisingIdProviding, @unchecked Sendable {
    let idfa = Locked<String?>("6D92078A-8246-4BA4-AE5B-76104861E7DC")
    let calls = Locked(0)
    func advertisingId() -> String? {
        calls.update { $0 += 1 }
        return idfa.get()
    }
}

/// The IPv6 echo. Answers nil (an IPv4-only network) unless a test sets `answer`.
final class FakePublicIp: PublicIpProviding, @unchecked Sendable {
    let answer = Locked<String?>(nil)
    /// The URL of each lookup.
    let lookups = Locked<[URL]>([])
    /// When true, answers are held until `releaseHeld` (to test that the install's flush never waits).
    let hold = Locked(false)
    let held = Locked<[@Sendable () -> Void]>([])

    func lookup(_ url: URL, completion: @escaping @Sendable (String?) -> Void) {
        lookups.update { $0.append(url) }
        let result = answer.get()
        if hold.get() {
            held.update { $0.append { completion(result) } }
        } else {
            completion(result)
        }
    }

    func releaseHeld() {
        let pending = held.update { list -> [@Sendable () -> Void] in
            defer { list = [] }
            return list
        }
        pending.forEach { $0() }
    }
}

final class FakeStoreKit: StoreKitProviding, @unchecked Sendable {
    let appTx = Locked<Result<AppTransactionInfo, KerdlyAdapterError>>(.success(AppTransactionInfo(
        jws: "eyJhbGciOiJFUzI1NiJ9.e30.c2ln", appTransactionId: "705012345678901234",
        originalPurchaseDate: Date(timeIntervalSince1970: 1_760_399_980), originalAppVersion: "131",
        environment: "Production", deviceVerificationNonce: "6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b",
        deviceVerification: "c2FtcGxlLWRldmljZS12ZXJpZmljYXRpb24=")))
    let appTxCalls = Locked(0)
    let entitlements = Locked<[PurchaseInfo]>([])
    let entitlementCalls = Locked(0)
    let found = Locked<PurchaseInfo?>(nil)
    let lookups = Locked(0)
    let updatesHandler = Locked<(@Sendable (PurchaseInfo) -> Void)?>(nil)

    func appTransaction(_ completion: @escaping @Sendable (Result<AppTransactionInfo, KerdlyAdapterError>) -> Void) {
        appTxCalls.update { $0 += 1 }
        completion(appTx.get())
    }

    func currentEntitlements(_ completion: @escaping @Sendable ([PurchaseInfo]) -> Void) {
        entitlementCalls.update { $0 += 1 }
        completion(entitlements.get())
    }

    func findTransaction(transactionId: String?, originalTransactionId: String?, productId: String?,
                         _ completion: @escaping @Sendable (PurchaseInfo?) -> Void) {
        lookups.update { $0 += 1 }
        completion(found.get())
    }

    func observeUpdates(_ handler: @escaping @Sendable (PurchaseInfo) -> Void) {
        updatesHandler.set(handler)
    }

    func emitUpdate(_ info: PurchaseInfo) {
        updatesHandler.get()?(info)
    }
}

final class FakeSkanWriter: SkanWriting, @unchecked Sendable {
    struct Write: Equatable {
        let api: String
        let fine: Int
        let coarse: SkanCoarse?
        let lock: Bool
    }

    let writes = Locked<[Write]>([])
    /// The error each SKAN write reports (nil = success).
    let skanError = Locked<String?>(nil)
    let aakError = Locked<String?>(nil)
    let api = Locked<String?>("skan4")
    let aakAvailable = Locked(true)
    /// When true, SKAN completions are held until `releaseHeld` (to test ordering and timeouts).
    let holdSkan = Locked(false)
    let held = Locked<[@Sendable () -> Void]>([])
    let onSkanWrite = Locked<(@Sendable () -> Void)?>(nil)

    var skanApiName: String? { api.get() }

    func updateSkan(fine: Int, coarse: SkanCoarse, lockWindow: Bool,
                    completion: @escaping @Sendable (SkanWriteResult) -> Void) {
        guard let api = api.get() else { return completion(.unsupported) }
        writes.update { $0.append(Write(api: api, fine: fine, coarse: api == "skan4" ? coarse : nil, lock: lockWindow)) }
        onSkanWrite.get()?()
        let result = SkanWriteResult.completed(api: api, error: skanError.get())
        if holdSkan.get() {
            held.update { $0.append { completion(result) } }
        } else {
            completion(result)
        }
    }

    func updateAak(fine: Int, lockPostback: Bool, completion: @escaping @Sendable (SkanWriteResult) -> Void) {
        guard aakAvailable.get() else { return completion(.unsupported) }
        writes.update { $0.append(Write(api: "aak", fine: fine, coarse: nil, lock: lockPostback)) }
        completion(.completed(api: "aak", error: aakError.get()))
    }

    func releaseHeld() {
        let pending = held.update { list -> [@Sendable () -> Void] in
            defer { list = [] }
            return list
        }
        pending.forEach { $0() }
    }
}

final class FakeLifecycle: LifecycleObserving, @unchecked Sendable {
    let handler = Locked<(@Sendable (LifecycleEvent) -> Void)?>(nil)
    let begun = Locked(0)
    let ended = Locked<[Int]>([])

    func observe(_ handler: @escaping @Sendable (LifecycleEvent) -> Void) {
        self.handler.set(handler)
    }

    func send(_ event: LifecycleEvent) {
        handler.get()?(event)
    }

    func beginBackgroundTask() -> Int? {
        begun.update { value -> Int in
            value += 1
            return value
        }
    }

    func endBackgroundTask(_ token: Int) {
        ended.update { $0.append(token) }
    }
}

/// Collects delayed work instead of running it; tests fire it explicitly.
final class ManualScheduler: Scheduling, @unchecked Sendable {
    final class Item: Cancellable, @unchecked Sendable {
        let delay: TimeInterval
        let work: @Sendable () -> Void
        let cancelled = Locked(false)
        let fired = Locked(false)
        init(delay: TimeInterval, work: @escaping @Sendable () -> Void) {
            self.delay = delay
            self.work = work
        }
        func cancel() { cancelled.set(true) }
    }

    let queue: DispatchQueue
    let items = Locked<[Item]>([])

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Cancellable {
        let item = Item(delay: delay, work: work)
        items.update { $0.append(item) }
        return item
    }

    var pending: [Item] {
        items.get().filter { !$0.cancelled.get() && !$0.fired.get() }
    }

    /// Runs (on the SDK queue) every pending item whose delay matches.
    func fire(where predicate: (TimeInterval) -> Bool) {
        for item in pending where predicate(item.delay) {
            item.fired.set(true)
            queue.async(execute: item.work)
        }
    }
}

/// Deterministic lowercase UUIDv4-shaped ids: …-0001, …-0002, …
final class SequentialIds: @unchecked Sendable {
    private let counter = Locked(0)
    func next() -> String {
        let n = counter.update { value -> Int in
            value += 1
            return value
        }
        return String(format: "00000000-0000-4000-8000-%012d", n)
    }
}
