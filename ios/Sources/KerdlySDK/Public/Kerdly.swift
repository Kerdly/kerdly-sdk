import Foundation
import UIKit

/// The Kerdly attribution SDK. Every method is safe to call from any thread, before or after
/// `configure` (earlier calls are replayed once the SDK has started), and never throws into the app.
public enum Kerdly {
    static var core: KerdlyCore { KerdlyCore.shared }

    /// Starts the SDK. Synchronous and cheap: resolves the install id, loads the queue and enqueues
    /// `$install` (when due) and `$open`; everything else runs on a background queue. Call it once,
    /// early in `application(_:didFinishLaunchingWithOptions:)`.
    public static func configure(_ options: KerdlyOptions) {
        core.configure(options)
    }

    /// The install id (a lowercase UUID), nil until `configure` has resolved it.
    public static var installId: String? {
        core.installIdBox.get()
    }

    /// The app's user id, attached to every later event; nil on logout. Emits `$identify` on change.
    public static func setUserId(_ userId: String?) {
        core.apiSetUserId(userId)
    }

    /// A custom event. `name` matches `^[a-z][a-z0-9_]{0,39}$`; at most 25 properties whose keys match
    /// the same pattern and whose values are strings (≤ 256 characters), finite numbers or booleans.
    /// Anything else is dropped with a debug log. A standard event's name (`registration`,
    /// `start_trial`, `subscribe`, `purchase`) gets its typed props checked as the typed methods do.
    public static func track(_ name: String, properties: [String: Any] = [:]) {
        core.apiTrack(name, properties: properties)
    }

    // MARK: Standard events
    //
    // Each enqueues an ordinary event (`registration`, `start_trial`, `subscribe`, `purchase`) with
    // its typed props; nil arguments are left out. `productId` and `transactionId` are cut to 128
    // characters, `method` to 64. `value` (what the user paid in `currency`; 0 for a free trial) must
    // be finite and ≥ 0, and is dropped without a valid ISO 4217 `currency` (trimmed and
    // upper-cased by the SDK). `quantity` must be ≥ 1. `properties` adds custom props under the
    // `track` rules (the typed ones count toward the 25); an argument wins over a property of the
    // same key. Anything dropped is logged at debug level.

    /// `registration`. `method`: how the user signed up (`anonymous`, `apple`, `google`, `email`, …).
    public static func trackRegistration(method: String? = nil, properties: [String: Any] = [:]) {
        core.apiTrackRegistration(method: method, properties: properties)
    }

    /// `start_trial`: a trial began (`value` 0 for a free trial).
    public static func trackStartTrial(productId: String? = nil, value: Double? = nil, currency: String? = nil,
                                       transactionId: String? = nil, properties: [String: Any] = [:]) {
        core.apiTrackStartTrial(productId: productId, value: value, currency: currency,
                                transactionId: transactionId, properties: properties)
    }

    /// `subscribe`: a paid subscription began.
    public static func trackSubscribe(productId: String? = nil, value: Double? = nil, currency: String? = nil,
                                      transactionId: String? = nil, properties: [String: Any] = [:]) {
        core.apiTrackSubscribe(productId: productId, value: value, currency: currency,
                               transactionId: transactionId, properties: properties)
    }

    /// `purchase`: a one-time purchase.
    public static func trackPurchase(productId: String? = nil, value: Double? = nil, currency: String? = nil,
                                     quantity: Int? = nil, transactionId: String? = nil,
                                     properties: [String: Any] = [:]) {
        core.apiTrackPurchase(productId: productId, value: value, currency: currency, quantity: quantity,
                              transactionId: transactionId, properties: properties)
    }

    /// Consent flags (nil leaves a flag unchanged). `analytics == false` keeps only the reserved
    /// install/attribution events; `ads == false` stops IDFA reads. Emits `$consent` on change.
    public static func setConsent(analytics: Bool? = nil, ads: Bool? = nil) {
        core.apiSetConsent(analytics: analytics, ads: ads)
    }

    /// Records a URL the app was opened with (`$deeplink`) and returns the params parsed from its
    /// query string: `cpp`, `ppid`, `kerdly_c`, `kerdly_v`, `campaign_ids`. Call it from every URL entry
    /// point (`application(_:open:options:)`, `scene(_:openURLContexts:)`, universal links).
    ///
    /// `source`: `"initial"` for the URL that launched the app, `"runtime"` for a later one. Nil (or
    /// any other value) lets the SDK infer it: the first URL within a minute of `configure`, before
    /// the app went to the background, is `initial`. An explicit `"initial"` uses up the inferred one,
    /// so a later call without a source is `runtime`.
    @discardableResult
    public static func handleUrl(_ url: URL, source: String? = nil) -> KerdlyDeepLink? {
        core.apiHandleUrl(url, source: source)
    }

    /// The `appAccountToken` the app's purchases carry (e.g. Superwall's alias UUID). Emits `$ids`.
    public static func setAppAccountToken(_ token: UUID?) {
        core.apiSetAppAccountToken(token)
    }

    /// Ids other SDKs in the app own (e.g. `meta_anon_id`, `superwall_alias`). Merged into the stored
    /// map; an empty value removes its key. Emits `$ids` on change.
    public static func setPartnerIds(_ ids: [String: String]) {
        core.apiSetPartnerIds(ids)
    }

    /// A purchase the paywall just completed (its ids win over what StoreKit reports). With no
    /// argument, sweeps `Transaction.currentEntitlements` instead. Each original transaction id is
    /// reported once per install (`$purchase_link`).
    public static func notifyPurchase(_ purchase: KerdlyPurchase? = nil) {
        core.apiNotifyPurchase(purchase)
    }

    /// A send the app just made through an ad network's SDK (`$network_send`).
    public static func recordNetworkSend(_ send: KerdlyNetworkSend) {
        core.apiRecordNetworkSend(send)
    }

    /// The install's attribution, cached on the device; nil until the server has decided it.
    public static var attribution: KerdlyAttribution? {
        core.apiAttribution
    }

    /// Called on the main thread whenever the attribution is first known or changes (and at once if
    /// it is already known).
    public static func onAttribution(_ handler: @escaping (KerdlyAttribution) -> Void) {
        core.addAttributionHandler(UncheckedSendable(handler))
    }

    /// Asks for App Tracking Transparency. Waits until the app is active (iOS shows the dialog only
    /// then); a caller still waiting after 5 s gets the current status, and the dialog still appears
    /// once the app becomes active. Needs `NSUserTrackingUsageDescription` in Info.plist. The SDK
    /// never prompts on its own. `completion` runs on the main thread.
    public static func requestTrackingAuthorization(_ completion: @escaping (KerdlyAttStatus) -> Void) {
        let box = UncheckedSendable(completion)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                TrackingPromptHost.prompter.request { status in box.value(status) }
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    TrackingPromptHost.prompter.request { status in box.value(status) }
                }
            }
        }
    }

    @available(iOS 13.0, *)
    public static func requestTrackingAuthorization() async -> KerdlyAttStatus {
        await withCheckedContinuation { continuation in
            requestTrackingAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Sends queued events now (honouring a server `Retry-After`).
    public static func flush() {
        core.apiFlush()
    }

    /// Debug builds only: asks Meta (ids from the bundle's Facebook config) and TikTok
    /// (`tiktokAppId`) for this device's deferred deep link, and returns each network's raw answer.
    /// Sends nothing to Kerdly. Asks only when the `ads` consent is on and tracking is authorized. In
    /// a release build it asks nothing and every answer is `error` ("debug builds only").
    /// `completion` runs on the SDK's queue.
    public static func debugFetchDeferredLinks(tiktokAppId: String?, storeAppId: String?,
                                               completion: @escaping @Sendable ([KerdlyDeferredLinkAnswer]) -> Void) {
        core.apiDebugFetchDeferredLinks(tiktokAppId: tiktokAppId, storeAppId: storeAppId) { answers in
            completion(answers.map(KerdlyDeferredLinkAnswer.init))
        }
    }
}

/// One network's answer to a deferred-deep-link request.
public struct KerdlyDeferredLinkAnswer: Sendable, Equatable {
    /// `meta` | `tiktok`.
    public let network: String
    /// `link` | `none` | `error` | `skipped_att` | `skipped_consent` | `not_configured`.
    public let status: String
    public let url: String?
    public let clickTime: String?
    public let httpStatus: Int?
    public let detail: String?

    init(_ answer: DdlAnswer) {
        network = answer.network
        status = answer.status.rawValue
        url = answer.url
        clickTime = answer.clickTime
        httpStatus = answer.httpStatus
        detail = answer.detail
    }
}

/// The one ATT prompter, created on the main thread.
@MainActor
enum TrackingPromptHost {
    static let prompter = TrackingPrompter(
        tracking: KerdlyCore.shared.deps.tracking,
        isActive: { UIApplication.shared.applicationState == .active },
        log: KerdlyCore.shared.log,
        onDecision: { _ in
            let core = KerdlyCore.shared
            core.queue.async { core.trackingDecided() }
        })
}
