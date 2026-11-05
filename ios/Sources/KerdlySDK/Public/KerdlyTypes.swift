import Foundation

// The public value types of the SDK. The Expo bridge maps them one to one.

/// `configure(environment:)`. `.auto` detects it on the device.
public enum KerdlyEnvironment: String, Sendable {
    case auto, production, sandbox, development
}

/// `logLevel`. Every line is prefixed `[Kerdly]`.
public enum KerdlyLogLevel: Int, Sendable {
    case none, error, warn, info, debug
}

/// App Tracking Transparency status, as the wire protocol spells it.
public enum KerdlyAttStatus: String, Sendable {
    case authorized, denied, restricted
    case notDetermined = "not_determined"
    case notApplicable = "not_applicable"
}

public struct KerdlyOptions: Sendable {
    /// The Kerdly collector: `https://app.kerdly.com/api`.
    public static let defaultEndpoint = URL(string: "https://app.kerdly.com/api")!

    /// `pk_live_…` / `pk_test_…`: the app's public SDK key.
    public var key: String
    /// Base URL; `/v1/sdk/batch` etc. are appended to it. Default: ``defaultEndpoint``.
    public var endpoint: URL
    public var environment: KerdlyEnvironment = .auto
    /// IDFA, only ever read when ATT = authorized and `ads` consent is on.
    public var collectAdvertisingId: Bool = true
    /// Write SKAdNetwork / AdAttributionKit conversion values. Needs the remote
    /// config's `skan.enabled` as well.
    public var skanWriter: Bool = false
    public var logLevel: KerdlyLogLevel = .warn
    /// Set by wrappers such as the Expo bridge, e.g. `"expo/0.1.0"`.
    public var wrapper: String? = nil

    public init(key: String, endpoint: URL = KerdlyOptions.defaultEndpoint) {
        self.key = key
        self.endpoint = endpoint
    }
}

/// What `handleUrl` parsed from a URL's query string. Each field is nil when absent.
public struct KerdlyDeepLink: Sendable, Equatable {
    public let url: URL
    public let cpp: String?, ppid: String?
    /// The click id of the Kerdly link that opened the app (`kerdly_c`).
    public let clickId: String?
    /// The web visit that link continues (`kerdly_v`).
    public let visitId: String?
    public let campaignIds: String?

    init(url: URL, cpp: String?, ppid: String?, clickId: String?, visitId: String?, campaignIds: String?) {
        self.url = url
        self.cpp = cpp
        self.ppid = ppid
        self.clickId = clickId
        self.visitId = visitId
        self.campaignIds = campaignIds
    }
}

/// What the paywall SDK reports after a purchase (e.g. Superwall's `transactionComplete`).
public struct KerdlyPurchase: Sendable, Equatable {
    public var originalTransactionId: String?
    public var transactionId: String?
    public var productId: String?
    public var appAccountToken: UUID?

    public init(originalTransactionId: String? = nil, transactionId: String? = nil,
                productId: String? = nil, appAccountToken: UUID? = nil) {
        self.originalTransactionId = originalTransactionId
        self.transactionId = transactionId
        self.productId = productId
        self.appAccountToken = appAccountToken
    }
}

/// A send the app just made through an ad network's SDK (`$network_send`).
public struct KerdlyNetworkSend: Sendable, Equatable {
    public var network: String, event: String, eventId: String?
    public var value: Double?, currency: String?, flag: String?

    public init(network: String, event: String, eventId: String? = nil,
                value: Double? = nil, currency: String? = nil, flag: String? = nil) {
        self.network = network
        self.event = event
        self.eventId = eventId
        self.value = value
        self.currency = currency
        self.flag = flag
    }
}

/// The install's attribution.
public struct KerdlyAttribution {
    public let state: String, network: String, status: String, method: String
    public let campaignId: String?, campaign: String?, adsetId: String?, adset: String?
    public let adId: String?, ad: String?, keywordId: String?, keyword: String?
    public let linkId: String?, cppId: String?, decidedAt: Date?
    /// The whole JSON object as the server sent it (JSON null is `NSNull`).
    public let raw: [String: Any]

    init(json: [String: JSONValue]) {
        func string(_ key: String) -> String? { json[key]?.lenientStringValue }
        state = string("state") ?? "unknown"
        network = string("network") ?? "unknown"
        status = string("status") ?? "unknown"
        method = string("method") ?? "none"
        campaignId = string("campaign_id")
        campaign = string("campaign")
        adsetId = string("adset_id")
        adset = string("adset")
        adId = string("ad_id")
        ad = string("ad")
        keywordId = string("keyword_id")
        keyword = string("keyword")
        linkId = string("link_id")
        cppId = string("cpp_id")
        if let ms = json["decided_at"]?.doubleValue {
            decidedAt = Date(timeIntervalSince1970: ms / 1000)
        } else {
            decidedAt = nil
        }
        raw = JSONValue.object(json).anyValue as? [String: Any] ?? [:]
    }
}
