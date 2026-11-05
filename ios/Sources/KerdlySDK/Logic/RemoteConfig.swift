import Foundation

/// `GET /v1/sdk/config`, with the defaults used until a config is cached.
struct RemoteConfig: Equatable, Sendable {
    var version: Int?
    /// Kill switch: false → stop sending, keep collecting reserved events.
    var enabled = true
    /// Kerdly is off for this app version: record, collect and send nothing.
    var off = false
    var maxBatch = BatchBuilder.maxEvents
    var queueFlushAt = 20
    var flushInterval: TimeInterval = 15
    var blockedEvents: Set<String> = []
    var collectAdvertisingId = true
    var collectAppTransaction = true
    var collectAsaToken = true
    var collectPurchases = true
    var collectPublicIp = true
    /// The public IPv6 echo. Only an `https` URL replaces the default.
    var ipv6EchoUrl = RemoteConfig.defaultIpv6EchoUrl
    /// nil = the SDK never writes SKAN values.
    var skan: SkanSchema?
    /// Deferred deep links; nil = off.
    var ddl: DdlConfig?
    var minSupportedSdk: String?
    var debugDevices: Set<String> = []

    static let defaults = RemoteConfig()
    static let defaultIpv6EchoUrl = URL(string: "https://api6.ipify.org?format=json")!

    /// Reads a config body. Unknown fields are ignored and out-of-range values clamped. An invalid
    /// `skan` ladder falls back to `previousValidSkan` (the last valid one); `skan: null` turns SKAN off.
    static func parse(_ json: JSONValue, previousValidSkan: SkanSchema?) -> RemoteConfig {
        var config = RemoteConfig()
        guard let object = json.objectValue else { return config }
        config.version = object["version"]?.int64Value.map { Int($0) }
        config.enabled = object["enabled"]?.boolValue ?? true
        config.off = object["off"]?.boolValue ?? false
        if let flush = object["flush"] {
            if let v = flush["max_batch"]?.int64Value { config.maxBatch = Int(min(max(v, 1), Int64(BatchBuilder.maxEvents))) }
            if let v = flush["queue_flush_at"]?.int64Value { config.queueFlushAt = Int(min(max(v, 1), 1_000)) }
            if let v = flush["interval_s"]?.doubleValue, v.isFinite { config.flushInterval = min(max(v, 1), 3_600) }
        }
        config.blockedEvents = Set(object["events"]?["block"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        if let collect = object["collect"] {
            config.collectAdvertisingId = collect["advertising_id"]?.boolValue ?? true
            config.collectAppTransaction = collect["app_transaction"]?.boolValue ?? true
            config.collectAsaToken = collect["asa_token"]?.boolValue ?? true
            config.collectPurchases = collect["purchases"]?.boolValue ?? true
            config.collectPublicIp = collect["public_ip"]?.boolValue ?? true
        }
        if let raw = object["ipv6_echo_url"]?.stringValue, let url = URL(string: raw),
           url.scheme?.lowercased() == "https", !(url.host ?? "").isEmpty {
            config.ipv6EchoUrl = url
        }
        switch object["skan"] {
        case .none, .some(.null):
            config.skan = nil
        case .some(let raw):
            config.skan = SkanSchema.parse(raw) ?? previousValidSkan
        }
        config.ddl = DdlConfig.parse(object["ddl"])
        config.minSupportedSdk = object["min_supported_sdk"]?.stringValue
        config.debugDevices = Set(object["debug_devices"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        return config
    }

    /// True when `sdkVersion` is below `min_supported_sdk`: the SDK then behaves as if the kill switch
    /// were on.
    func isBelowMinimum(sdkVersion: String) -> Bool {
        guard let min = minSupportedSdk else { return false }
        return SemanticVersion.compare(sdkVersion, min) < 0
    }
}

/// The config's `ddl` block: which networks to ask for a deferred deep link. The hosts are the
/// SDK's own (DeferredLinks.swift), never the config's.
struct DdlConfig: Equatable, Sendable {
    struct Meta: Equatable, Sendable {
        /// nil = the bundle's `FacebookAppID` / `FacebookClientToken`.
        var appId: String?
        var clientToken: String?
    }

    struct TikTok: Equatable, Sendable {
        var appId: String
        var storeAppId: String?
    }

    var enabled: Bool
    /// Asked only this long after the first launch.
    var maxAge: TimeInterval
    var meta: Meta?
    var tiktok: TikTok?
    /// `require_att`: ask only with tracking authorized. False: also ask once the user denied
    /// tracking (or it is restricted), without the IDFA (Meta through `ep2`). Default true.
    var requireAtt = true

    static let defaultMaxAgeHours: Double = 47

    /// nil when the block is absent or not an object; out-of-range ages are clamped to 1–168 h.
    static func parse(_ json: JSONValue?) -> DdlConfig? {
        guard let object = json?.objectValue else { return nil }
        let hours = object["max_age_h"]?.doubleValue.flatMap { $0.isFinite ? $0 : nil } ?? defaultMaxAgeHours
        let nonEmpty = { (value: JSONValue?) -> String? in
            value?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }
        let meta = object["meta"]?.objectValue.map {
            Meta(appId: nonEmpty($0["app_id"]), clientToken: nonEmpty($0["client_token"]))
        }
        let tiktok = object["tiktok"]?.objectValue.flatMap { block in
            nonEmpty(block["app_id"]).map { TikTok(appId: $0, storeAppId: nonEmpty(block["store_app_id"])) }
        }
        return DdlConfig(enabled: object["enabled"]?.boolValue ?? false,
                         maxAge: min(max(hours, 1), 168) * 3_600, meta: meta, tiktok: tiktok,
                         requireAtt: object["require_att"]?.boolValue ?? true)
    }
}

/// The cached config document (`Application Support/kerdly/config.json`).
struct ConfigCache: Codable, Equatable, Sendable {
    var etag: String?
    /// ms since the epoch.
    var fetchedAt: Int64
    var body: JSONValue
    /// The last ladder that passed validation, kept for when a later one does not.
    var lastValidSkan: JSONValue?
    /// The app version this config was fetched for (Kerdly resolves the config per
    /// version). Nil in a cache written before the field existed.
    var appVersion: String?

    enum CodingKeys: String, CodingKey {
        case etag, body
        case fetchedAt = "fetched_at"
        case lastValidSkan = "last_valid_skan"
        case appVersion = "app_version"
    }

    static let maxAge: TimeInterval = 6 * 3_600

    func isStale(now: Date) -> Bool {
        now.timeIntervalSince(Clocks.date(ms: fetchedAt)) >= Self.maxAge
            || Clocks.date(ms: fetchedAt) > now.addingTimeInterval(Self.maxAge)
    }

    var config: RemoteConfig {
        RemoteConfig.parse(body, previousValidSkan: SkanSchema.parse(lastValidSkan))
    }

    /// Whether this config was fetched for `appVersion`; after an app update it was not.
    func isFor(appVersion: String) -> Bool {
        self.appVersion == appVersion
    }

    /// The cache after a 200: the new body, and the last valid ladder carried forward.
    func replacing(body: JSONValue, etag: String?, fetchedAt: Int64, appVersion: String) -> ConfigCache {
        let newSkan = body["skan"]
        let valid = SkanSchema.parse(newSkan) != nil ? newSkan : lastValidSkan
        return ConfigCache(etag: etag, fetchedAt: fetchedAt, body: body, lastValidSkan: valid, appVersion: appVersion)
    }

    static func first(body: JSONValue, etag: String?, fetchedAt: Int64, appVersion: String) -> ConfigCache {
        let skan = body["skan"]
        return ConfigCache(etag: etag, fetchedAt: fetchedAt, body: body,
                           lastValidSkan: SkanSchema.parse(skan) != nil ? skan : nil, appVersion: appVersion)
    }
}

enum SemanticVersion {
    /// Compares dotted numeric versions ("0.1.0" < "0.10.0"); non-numeric parts count as 0.
    static func compare(_ a: String, _ b: String) -> Int {
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    private static func parts(_ v: String) -> [Int] {
        let core = v.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? v
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }
}
