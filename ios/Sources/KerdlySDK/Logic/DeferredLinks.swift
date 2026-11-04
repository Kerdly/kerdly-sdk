import Foundation

/// Deferred deep links: the networks' own requests, sent from the device, so a network can say
/// which of its ads an install came from. Each request mirrors the network SDK's own, field for
/// field: Meta from FBSDKCoreKit 18.1.1 (`FBSDKAppLinkUtility fetchDeferredAppLink`), TikTok from
/// TikTokBusinessSDK 1.7.1 (`fetchDeferredDeeplinkWithConfig`).
///
/// Pure: the core gathers the device facts and sends the request.

/// What the requests need from the device.
struct DdlDeviceFacts: Equatable, Sendable {
    var bundleId: String
    var appName: String
    var appVersion: String
    var appBuild: String
    var os: String
    var model: String
    /// `Locale.current.identifier`, e.g. `en_US` (Meta's `extinfo`).
    var localeIdentifier: String
    /// The first preferred language, e.g. `en-US` (TikTok's `locale`).
    var preferredLanguage: String
    var regionCode: String
    var timeZoneName: String
    var timeZoneAbbrev: String
    /// Screen size in points.
    var screenWidth: Int
    var screenHeight: Int
    var screenScale: Double
    var coreCount: Int
    /// Empty unless tracking is authorized.
    var idfa: String
    var idfv: String?
    /// The app's `CFBundleURLSchemes`.
    var urlSchemes: [String]
}

/// One network's answer.
struct DdlAnswer: Equatable, Sendable {
    enum Status: String, Sendable {
        case link, none, error
        case skippedAtt = "skipped_att"
        case skippedConsent = "skipped_consent"
        case notConfigured = "not_configured"
    }

    var network: String
    var status: Status
    var url: String?
    /// As the network gave it (Meta: `click_time`).
    var clickTime: String?
    var httpStatus: Int?
    /// The error, or the start of an unexpected body.
    var detail: String?

    static func skipped(_ network: String, _ status: Status, _ detail: String? = nil) -> DdlAnswer {
        DdlAnswer(network: network, status: status, url: nil, clickTime: nil, httpStatus: nil, detail: detail)
    }
}

extension DdlAnswer {
    /// No answer, a 429 or a 5xx: worth asking again. Any other answer, a refusal included, is final.
    var isTransient: Bool {
        guard status == .error else { return false }
        guard let code = httpStatus else { return true }
        return code == 429 || code >= 500
    }

    /// The network's click time in ms. Meta gives Unix seconds, as a string or a number.
    var clickTimeMs: Int64? {
        guard let raw = clickTime?.trimmingCharacters(in: .whitespaces), let value = Double(raw),
              value.isFinite, value > 0 else { return nil }
        return Int64(value < 100_000_000_000 ? value * 1_000 : value)
    }
}

enum MetaDdl {
    static let network = "meta"
    /// The hosts FBSDKCoreKit's default domain config routes `/activities` to: `ep1` with tracking
    /// authorized, `ep2` without. Only `ep1` is a tracking domain in the privacy manifest (FBSDK
    /// refuses `ep2` as one), so iOS lets the `ep2` request through for a user who denied tracking.
    static let trackingHost = "ep1.facebook.com"
    static let noTrackingHost = "ep2.facebook.com"
    /// FBSDKCoreKit 18.1.1's `FBSDK_DEFAULT_GRAPH_API_VERSION`.
    static let defaultGraphVersion = "v26.0"

    /// FBSDKAppEventsDeviceInfo's 16-slot `extinfo`, version `i2`. Carrier is empty since iOS 16;
    /// slots 13–14 (disk) are -1, as the SDK sends them.
    static func extinfo(_ f: DdlDeviceFacts) -> String {
        let density = f.screenScale > 0 ? String(format: "%.02f", f.screenScale) : ""
        let slots: [Any] = [
            "i2", f.bundleId, f.appBuild, f.appVersion, f.os, f.model, f.localeIdentifier,
            f.timeZoneAbbrev, "", f.screenWidth, f.screenHeight, density, f.coreCount, -1, -1, f.timeZoneName,
        ]
        return json(slots) ?? "[]"
    }

    /// `POST https://<host>/<version>/<app id>/activities`, form-encoded, signed with the app's
    /// public client token. With tracking authorized: `ep1`, the IDFA and
    /// `advertiser_tracking_enabled=1`. Without: `ep2`, no IDFA and `0`, as FBSDKCoreKit sends it.
    /// `application_tracking_enabled` and `advertiser_id_collection_enabled` are app settings in
    /// FBSDKCoreKit, not the ATT status, so both stay `1`.
    static func request(appId: String, clientToken: String, anonId: String, facts: DdlDeviceFacts,
                        trackingAuthorized: Bool, graphVersion: String = defaultGraphVersion) -> HTTPRequest? {
        let host = trackingAuthorized ? trackingHost : noTrackingHost
        guard !appId.isEmpty, !clientToken.isEmpty,
              let url = URL(string: "https://\(host)/\(graphVersion)/\(appId)/activities") else { return nil }
        var fields: [(String, String)] = [("event", "DEFERRED_APP_LINK")]
        if trackingAuthorized { fields.append(("advertiser_id", facts.idfa)) }
        fields += [
            ("anon_id", anonId),
            ("advertiser_tracking_enabled", trackingAuthorized ? "1" : "0"),
            ("ud", "{}"),
            ("application_tracking_enabled", "1"),
            ("advertiser_id_collection_enabled", "1"),
            ("extinfo", extinfo(facts)),
        ]
        if !facts.urlSchemes.isEmpty, let schemes = json(facts.urlSchemes) {
            fields.append(("url_schemes", schemes))
        }
        fields += [("format", "json"), ("sdk", "ios"), ("include_headers", "false"),
                   ("access_token", "\(appId)|\(clientToken)")]
        let body = fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
        return HTTPRequest(method: "POST", url: url,
                           headers: ["Content-Type": "application/x-www-form-urlencoded"],
                           body: Data(body.utf8))
    }

    /// `{"applink_url": …, "click_time": …}` when Meta has a link for this device; `{}` otherwise.
    static func parse(_ result: HTTPResult) -> DdlAnswer {
        switch result {
        case .failure(let reason):
            return DdlAnswer(network: network, status: .error, url: nil, clickTime: nil, httpStatus: nil, detail: reason)
        case .response(let status, _, let body):
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            guard status == 200, let object else {
                let error = (object?["error"] as? [String: Any]).map { "\($0["code"] ?? "")/\($0["error_subcode"] ?? "") \($0["message"] ?? "")" }
                return DdlAnswer(network: network, status: .error, url: nil, clickTime: nil, httpStatus: status,
                                 detail: error ?? preview(body))
            }
            if let link = object["applink_url"] as? String, !link.isEmpty {
                return DdlAnswer(network: network, status: .link, url: link,
                                 clickTime: object["click_time"].map { "\($0)" }, httpStatus: status, detail: nil)
            }
            return DdlAnswer(network: network, status: .none, url: nil, clickTime: nil, httpStatus: status, detail: preview(body))
        }
    }
}

enum TikTokDdl {
    static let network = "tiktok"
    /// TikTokBusinessSDK's default `apiDomain`.
    static let defaultHost = "analytics.us.tiktok.com"
    static let path = "/api/v1/app_sdk/ddl"

    /// The SDK's `fallbackUserAgent`: app/version, model, OS, resolution.
    static func userAgent(_ f: DdlDeviceFacts) -> String {
        "\(f.appName)/\(f.appVersion) \(f.model) iOS/\(f.os) Resolution/\(f.screenWidth)*\(f.screenHeight)"
    }

    /// TikTokBusinessSDK's `att_status` names.
    static func attStatus(_ status: KerdlyAttStatus) -> String {
        switch status {
        case .authorized: return "AUTHORIZED"
        case .denied: return "DENIED"
        case .restricted: return "RESTRICTED"
        case .notDetermined: return "NOT_DETERMINED"
        case .notApplicable: return "NOT_APPLICABLE"
        }
    }

    /// `POST https://<host>/api/v1/app_sdk/ddl`, unsigned JSON. `storeAppId` is the App Store id the
    /// app passes TikTok as `appId`. The host is the same whatever the ATT status; the request
    /// carries the status and, only when it is authorized, the IDFA (empty otherwise).
    static func request(tiktokAppId: String, storeAppId: String?, facts: DdlDeviceFacts, att: KerdlyAttStatus,
                        now: Date, host: String = defaultHost) -> HTTPRequest? {
        guard !tiktokAppId.isEmpty, let url = URL(string: "https://\(host)\(path)") else { return nil }
        var app: [String: Any] = [
            "name": facts.appName, "namespace": facts.bundleId, "version": facts.appVersion,
            "build": facts.appBuild, "app_session_id": "", "last_app_session_id": "",
            "last_app_session_start_time": "", "tiktok_app_id": tiktokAppId,
        ]
        if let storeAppId, !storeAppId.isEmpty { app["id"] = storeAppId }
        let ua = userAgent(facts)
        let device: [String: Any] = [
            "att_status": attStatus(att), "platform": "ios", "idfa": att == .authorized ? facts.idfa : "",
            "idfv": facts.idfv ?? "",
            "ip": "", "user_agent": ua, "locale": "\(facts.preferredLanguage)/\(facts.regionCode)",
            "model": facts.model, "os_version": facts.os,
        ]
        let body: [String: Any] = [
            "context": ["app": app, "device": device, "user": [String: Any]()],
            "ip": "", "tiktok_app_id": tiktokAppId, "user_agent": ua,
            "timestamp": iso8601(now),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return nil }
        return HTTPRequest(method: "POST", url: url, headers: ["Content-Type": "application/json"], body: data)
    }

    /// `{"code": 0, "data": {"ddl": "<url>"}}`; any other code is an error.
    static func parse(_ result: HTTPResult) -> DdlAnswer {
        switch result {
        case .failure(let reason):
            return DdlAnswer(network: network, status: .error, url: nil, clickTime: nil, httpStatus: nil, detail: reason)
        case .response(let status, _, let body):
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let code = (object?["code"] as? NSNumber)?.intValue
            guard status == 200, code == 0 else {
                let message = object?["message"].map { "\(code.map(String.init) ?? "?") \($0)" }
                return DdlAnswer(network: network, status: .error, url: nil, clickTime: nil, httpStatus: status,
                                 detail: message ?? preview(body))
            }
            if let link = (object?["data"] as? [String: Any])?["ddl"] as? String, !link.isEmpty {
                return DdlAnswer(network: network, status: .link, url: link, clickTime: nil, httpStatus: status, detail: nil)
            }
            return DdlAnswer(network: network, status: .none, url: nil, clickTime: nil, httpStatus: status, detail: preview(body))
        }
    }
}

private func json(_ value: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) else { return nil }
    return String(data: data, encoding: .utf8)
}

private func formEncode(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

private func preview(_ body: Data) -> String {
    String(String(decoding: body.prefix(300), as: UTF8.self))
}

private func iso8601(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}
