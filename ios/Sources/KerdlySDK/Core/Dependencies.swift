import Foundation

// The seams between the SDK's logic and the system. Each protocol is small; the system
// implementations live in Platform/, the tests' fakes in Tests/KerdlySDKTests/Support/.

/// The Keychain copy of the install id (service `com.kerdly.sdk`, account `install_id`).
protocol KeychainStoring: Sendable {
    func readInstallId() -> KeychainRead
    func writeInstallId(_ id: String) -> Bool
}

/// The standard UserDefaults suite.
protocol DefaultsStoring: Sendable {
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func set(_ value: String?, forKey key: String)
    func set(_ value: Bool, forKey key: String)
}

/// The SDK's own files (`Application Support/kerdly/`). Writes are atomic.
protocol FileStoring: Sendable {
    func read(_ name: String) -> Data?
    @discardableResult func write(_ data: Data, to name: String) -> Bool
    func remove(_ name: String)
}

struct HTTPRequest: Equatable, Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?
}

enum HTTPResult: Equatable, Sendable {
    /// Header names are lowercased.
    case response(status: Int, headers: [String: String], body: Data)
    case failure(String)
}

protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest, completion: @escaping @Sendable (HTTPResult) -> Void)
}

protocol Clock: Sendable {
    func now() -> Date
}

/// Main-bundle, file-system and UIKit facts.
protocol DeviceInfoProviding: Sendable {
    func appInfo() -> AppInfo
    func facts() -> DeviceFacts
    /// UIKit reads: idfv, screen, application state. Main thread only.
    @MainActor func snapshot() -> DeviceSnapshot
    /// The Documents directory's creation date.
    func installedAt() -> Date?
    func environmentInputs() -> EnvironmentInputs
    /// The bundle's Facebook config and URL schemes, for deferred deep links.
    func deferredLinkBundle() -> DeferredLinkBundle
}

/// App Tracking Transparency.
protocol TrackingAuthorizing: Sendable {
    func status() -> KerdlyAttStatus
    /// Whether the app declares `NSUserTrackingUsageDescription` (without it, iOS terminates an app
    /// that asks).
    func canPrompt() -> Bool
    /// `ATTrackingManager.requestTrackingAuthorization`; call on the main thread, while active.
    func request(_ completion: @escaping @Sendable (KerdlyAttStatus) -> Void)
}

/// `AAAttribution.attributionToken()`; blocking, call off the main thread.
protocol AdServicesTokenProviding: Sendable {
    func attributionToken() throws -> String
}

/// The IDFA; nil when unavailable or all zeros.
protocol AdvertisingIdProviding: Sendable {
    func advertisingId() -> String?
}

/// The IPv6 echo: one `GET` answering `{"ip": "…"}`.
protocol PublicIpProviding: Sendable {
    /// Completes with the answer's `ip` as given, or nil on an error, a timeout or another body.
    func lookup(_ url: URL, completion: @escaping @Sendable (String?) -> Void)
}

/// The AppTransaction signal's fields (`app_transaction`).
struct AppTransactionInfo: Equatable, Sendable {
    var jws: String
    var appTransactionId: String?
    var originalPurchaseDate: Date
    var originalAppVersion: String
    var environment: String
    var deviceVerificationNonce: String
    var deviceVerification: String
}

protocol StoreKitProviding: Sendable {
    /// `AppTransaction.shared` (iOS 16+). Never `refresh()`. Fails with a reason on older systems.
    func appTransaction(_ completion: @escaping @Sendable (Result<AppTransactionInfo, KerdlyAdapterError>) -> Void)
    /// Verified `Transaction.currentEntitlements`.
    func currentEntitlements(_ completion: @escaping @Sendable ([PurchaseInfo]) -> Void)
    /// The verified transaction a paywall notify refers to, if StoreKit has it.
    func findTransaction(transactionId: String?, originalTransactionId: String?, productId: String?,
                         _ completion: @escaping @Sendable (PurchaseInfo?) -> Void)
    /// Starts listening to `Transaction.updates` (verified only) for the life of the process.
    func observeUpdates(_ handler: @escaping @Sendable (PurchaseInfo) -> Void)
}

enum LifecycleEvent: Equatable, Sendable {
    case willEnterForeground
    case didBecomeActive
    case didEnterBackground
    case protectedDataAvailable
}

protocol LifecycleObserving: Sendable {
    /// Delivers UIApplication notifications (on the main thread) for the life of the process.
    func observe(_ handler: @escaping @Sendable (LifecycleEvent) -> Void)
    /// Asks iOS for time to finish a flush after going to the background; returns a token for `end`.
    func beginBackgroundTask() -> Int?
    func endBackgroundTask(_ token: Int)
}

/// A cancellable delayed task.
protocol Cancellable: Sendable {
    func cancel()
}

protocol Scheduling: Sendable {
    /// Runs `work` on the SDK's queue after `delay` seconds.
    @discardableResult
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Cancellable
}

struct KerdlyAdapterError: Error, Equatable, Sendable, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Everything `KerdlyCore` talks to.
struct KerdlyDependencies: Sendable {
    var keychain: KeychainStoring
    var defaults: DefaultsStoring
    var files: FileStoring
    var transport: HTTPTransport
    var clock: Clock
    var device: DeviceInfoProviding
    var tracking: TrackingAuthorizing
    var adServices: AdServicesTokenProviding
    var advertisingId: AdvertisingIdProviding
    var publicIp: PublicIpProviding
    var storeKit: StoreKitProviding
    var skanWriter: SkanWriting
    var lifecycle: LifecycleObserving
    /// Builds the scheduler for the SDK's queue.
    var makeScheduler: @Sendable (DispatchQueue) -> Scheduling
    /// A queue for blocking system calls (the AdServices token, the IDFA) and the IPv6 lookup.
    var workQueue: DispatchQueue
    var newId: @Sendable () -> String
    /// A value in [0, 1] for back-off jitter.
    var unitRandom: @Sendable () -> Double
}
