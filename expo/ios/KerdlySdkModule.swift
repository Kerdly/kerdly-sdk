import ExpoModulesCore
import Foundation

// The Expo bridge over the native KerdlySDK.
//
// The KerdlySDK sources are vendored into this pod by scripts/sync-native.mjs (ios/KerdlySDK/), so `Kerdly`,
// `KerdlyOptions`, … are declared in this module and need no `import KerdlySDK`. Because module-local
// declarations shadow imported ones, every ExpoModulesCore name below is module-qualified: a type
// the SDK adds later (say, an `Events` enum) can never capture the DSL.
//
// Every function is an AsyncFunction on the main queue: native calls run in the order JS made them
// (configure first), on the thread the SDK expects for `configure`.

public final class KerdlySdkModule: ExpoModulesCore.Module {
  static let attributionEvent = "onAttribution"

  public func definition() -> ExpoModulesCore.ModuleDefinition {
    ExpoModulesCore.Name("KerdlySdk")

    ExpoModulesCore.Events(KerdlySdkModule.attributionEvent)

    ExpoModulesCore.OnCreate {
      KerdlyExpoAttributionRelay.shared.attach(self)
    }

    ExpoModulesCore.OnDestroy {
      KerdlyExpoAttributionRelay.shared.detach(self)
    }

    ExpoModulesCore.AsyncFunction("configure") { (options: KerdlyExpoConfigureOptions) in
      guard !options.key.isEmpty, let endpoint = URL(string: options.endpoint) else {
        NSLog("[Kerdly] configure: missing key or invalid endpoint; the SDK was not configured")
        return
      }
      var kerdlyOptions = KerdlyOptions(key: options.key, endpoint: endpoint)
      kerdlyOptions.environment = KerdlyEnvironment(rawValue: options.environment) ?? .auto
      kerdlyOptions.collectAdvertisingId = options.collectAdvertisingId
      kerdlyOptions.skanWriter = options.skanWriter
      kerdlyOptions.logLevel = KerdlySdkModule.logLevel(options.logLevel)
      kerdlyOptions.wrapper = options.wrapper
      Kerdly.configure(kerdlyOptions)
    }
    .runOnQueue(.main)

    ExpoModulesCore.AsyncFunction("setUserId") { (userId: String?) in
      Kerdly.setUserId(userId)
    }
    .runOnQueue(.main)

    ExpoModulesCore.AsyncFunction("track") { (name: String, properties: [String: Any]) in
      Kerdly.track(name, properties: properties)
    }
    .runOnQueue(.main)

    // Standard events. JS passes every typed field, null when omitted, in the order
    // of the native signature; the SDK validates them again.
    ExpoModulesCore.AsyncFunction("trackRegistration") { (method: String?, properties: [String: Any]) in
      Kerdly.trackRegistration(method: method, properties: properties)
    }
    .runOnQueue(.main)

    ExpoModulesCore.AsyncFunction("trackStartTrial") {
      (productId: String?, value: Double?, currency: String?, transactionId: String?, properties: [String: Any]) in
      Kerdly.trackStartTrial(
        productId: productId,
        value: value,
        currency: currency,
        transactionId: transactionId,
        properties: properties
      )
    }
    .runOnQueue(.main)

    ExpoModulesCore.AsyncFunction("trackSubscribe") {
      (productId: String?, value: Double?, currency: String?, transactionId: String?, properties: [String: Any]) in
      Kerdly.trackSubscribe(
        productId: productId,
        value: value,
        currency: currency,
        transactionId: transactionId,
        properties: properties
      )
    }
    .runOnQueue(.main)

    ExpoModulesCore.AsyncFunction("trackPurchase") {
      (productId: String?, value: Double?, currency: String?, quantity: Int?, transactionId: String?,
       properties: [String: Any]) in
      Kerdly.trackPurchase(
        productId: productId,
        value: value,
        currency: currency,
        quantity: quantity,
        transactionId: transactionId,
        properties: properties
      )
    }
    .runOnQueue(.main)

    ExpoModulesCore.AsyncFunction("setConsent") { (analytics: Bool?, ads: Bool?) in
      Kerdly.setConsent(analytics: analytics, ads: ads)
    }
    .runOnQueue(.main)

    // The second argument is the source the JS layer knows ("initial" for Linking's initial URL,
    // "runtime" for its `url` events, or null); the SDK infers it only when it is null.
    ExpoModulesCore.AsyncFunction("handleUrl") { (urlString: String, source: String?) -> [String: Any]? in
      guard let url = URL(string: urlString) else {
        NSLog("[Kerdly] handleUrl: not a valid URL")
        return nil
      }
      return Kerdly.handleUrl(url, source: source).map(KerdlySdkModule.dictionary(from:))
    }
    .runOnQueue(.main)

    ExpoModulesCore.AsyncFunction("setAppAccountToken") { (token: String?) in
      guard let token else {
        Kerdly.setAppAccountToken(nil)
        return
      }
      // An unparsable token is ignored rather than clearing the stored one.
      guard let uuid = UUID(uuidString: token) else {
        NSLog("[Kerdly] setAppAccountToken: not a UUID; ignored")
        return
      }
      Kerdly.setAppAccountToken(uuid)
    }
    .runOnQueue(.main)

    ExpoModulesCore.AsyncFunction("setPartnerIds") { (ids: [String: String]) in
      Kerdly.setPartnerIds(ids)
    }
    .runOnQueue(.main)

    // Accepts either platform's shape; only the iOS fields are read. No purchase, or one without
    // any iOS field (e.g. the Android shape), sweeps Transaction.currentEntitlements instead.
    ExpoModulesCore.AsyncFunction("notifyPurchase") { (purchase: KerdlyExpoPurchase?) in
      guard let purchase else {
        Kerdly.notifyPurchase(nil)
        return
      }
      let token = purchase.appAccountToken.flatMap { UUID(uuidString: $0) }
      if purchase.originalTransactionId == nil, purchase.transactionId == nil, purchase.productId == nil, token == nil {
        Kerdly.notifyPurchase(nil)
        return
      }
      Kerdly.notifyPurchase(KerdlyPurchase(
        originalTransactionId: purchase.originalTransactionId,
        transactionId: purchase.transactionId,
        productId: purchase.productId,
        appAccountToken: token
      ))
    }
    .runOnQueue(.main)

    ExpoModulesCore.AsyncFunction("recordNetworkSend") { (send: KerdlyExpoNetworkSend) in
      guard !send.network.isEmpty, !send.event.isEmpty else {
        NSLog("[Kerdly] recordNetworkSend: network and event are required; ignored")
        return
      }
      Kerdly.recordNetworkSend(KerdlyNetworkSend(
        network: send.network,
        event: send.event,
        eventId: send.eventId,
        value: send.value,
        currency: send.currency,
        flag: send.flag
      ))
    }
    .runOnQueue(.main)

    ExpoModulesCore.AsyncFunction("getAttribution") { () -> [String: Any]? in
      Kerdly.attribution.map(KerdlySdkModule.dictionary(from:))
    }
    .runOnQueue(.main)

    // The SDK waits for the app to be active and, without NSUserTrackingUsageDescription (the config
    // plugin's userTrackingPermission), logs an error and reports the current status instead of prompting.
    ExpoModulesCore.AsyncFunction("requestTrackingAuthorization") { (promise: ExpoModulesCore.Promise) in
      Kerdly.requestTrackingAuthorization { status in
        promise.resolve(status.rawValue)
      }
    }
    .runOnQueue(.main)

    ExpoModulesCore.AsyncFunction("flush") {
      Kerdly.flush()
    }
    .runOnQueue(.main)

    ExpoModulesCore.AsyncFunction("getInstallId") { () -> String? in
      Kerdly.installId
    }
    .runOnQueue(.main)

    // Debug only: each network's raw answer to a deferred-deep-link request; sends nothing to Kerdly.
    ExpoModulesCore.AsyncFunction("debugFetchDeferredLinks") {
      (tiktokAppId: String?, storeAppId: String?, ignoreAtt: Bool, promise: ExpoModulesCore.Promise) in
      Kerdly.debugFetchDeferredLinks(tiktokAppId: tiktokAppId, storeAppId: storeAppId, ignoreAtt: ignoreAtt) { answers in
        promise.resolve(answers.map { answer -> [String: Any] in
          var out: [String: Any] = ["network": answer.network, "status": answer.status]
          if let url = answer.url { out["url"] = url }
          if let clickTime = answer.clickTime { out["clickTime"] = clickTime }
          if let httpStatus = answer.httpStatus { out["httpStatus"] = httpStatus }
          if let detail = answer.detail { out["detail"] = detail }
          return out
        })
      }
    }
    .runOnQueue(.main)
  }

  // MARK: - Mapping

  static func logLevel(_ name: String) -> KerdlyLogLevel {
    switch name {
    case "none": return KerdlyLogLevel.none
    case "error": return KerdlyLogLevel.error
    case "info": return KerdlyLogLevel.info
    case "debug": return KerdlyLogLevel.debug
    default: return KerdlyLogLevel.warn
    }
  }

  private static func orNull(_ value: String?) -> Any {
    if let value { return value }
    return NSNull()
  }

  static func dictionary(from link: KerdlyDeepLink) -> [String: Any] {
    return [
      "url": link.url.absoluteString,
      "cpp": orNull(link.cpp),
      "ppid": orNull(link.ppid),
      "afrC": orNull(link.afrC),
      "afrV": orNull(link.afrV),
      "campaignIds": orNull(link.campaignIds),
    ]
  }

  static func dictionary(from attribution: KerdlyAttribution) -> [String: Any] {
    var decidedAt: Any = NSNull()
    if let date = attribution.decidedAt {
      decidedAt = (date.timeIntervalSince1970 * 1000).rounded()
    }
    return [
      "state": attribution.state,
      "network": attribution.network,
      "status": attribution.status,
      "method": attribution.method,
      "campaignId": orNull(attribution.campaignId),
      "campaign": orNull(attribution.campaign),
      "adsetId": orNull(attribution.adsetId),
      "adset": orNull(attribution.adset),
      "adId": orNull(attribution.adId),
      "ad": orNull(attribution.ad),
      "keywordId": orNull(attribution.keywordId),
      "keyword": orNull(attribution.keyword),
      "linkId": orNull(attribution.linkId),
      "cppId": orNull(attribution.cppId),
      "decidedAt": decidedAt,
      "raw": attribution.raw,
    ]
  }
}

/// `Kerdly.onAttribution` has no unregister, so the handler is registered once per process and routed
/// to the live module instance (a JS reload creates a new one).
private final class KerdlyExpoAttributionRelay: @unchecked Sendable {
  static let shared = KerdlyExpoAttributionRelay()

  private let lock = NSLock()
  private weak var module: KerdlySdkModule?
  private var registered = false

  func attach(_ module: KerdlySdkModule) {
    lock.lock()
    self.module = module
    let needsRegistration = !registered
    registered = true
    lock.unlock()
    if needsRegistration {
      Kerdly.onAttribution { [weak self] attribution in
        self?.deliver(attribution)
      }
    }
  }

  func detach(_ module: KerdlySdkModule) {
    lock.lock()
    if self.module === module {
      self.module = nil
    }
    lock.unlock()
  }

  private func deliver(_ attribution: KerdlyAttribution) {
    lock.lock()
    let module = self.module
    lock.unlock()
    module?.sendEvent(KerdlySdkModule.attributionEvent, KerdlySdkModule.dictionary(from: attribution))
  }
}

// MARK: - Arguments (src/native.ts is the JS side of this contract)

struct KerdlyExpoConfigureOptions: ExpoModulesCore.Record {
  @ExpoModulesCore.Field var key: String = ""
  @ExpoModulesCore.Field var endpoint: String = ""
  @ExpoModulesCore.Field var environment: String = "auto"
  @ExpoModulesCore.Field var collectAdvertisingId: Bool = true
  @ExpoModulesCore.Field var skanWriter: Bool = false
  @ExpoModulesCore.Field var logLevel: String = "warn"
  @ExpoModulesCore.Field var wrapper: String? = nil
}

struct KerdlyExpoPurchase: ExpoModulesCore.Record {
  @ExpoModulesCore.Field var originalTransactionId: String? = nil
  @ExpoModulesCore.Field var transactionId: String? = nil
  @ExpoModulesCore.Field var productId: String? = nil
  @ExpoModulesCore.Field var appAccountToken: String? = nil
}

struct KerdlyExpoNetworkSend: ExpoModulesCore.Record {
  @ExpoModulesCore.Field var network: String = ""
  @ExpoModulesCore.Field var event: String = ""
  @ExpoModulesCore.Field var eventId: String? = nil
  @ExpoModulesCore.Field var value: Double? = nil
  @ExpoModulesCore.Field var currency: String? = nil
  @ExpoModulesCore.Field var flag: String? = nil
}
