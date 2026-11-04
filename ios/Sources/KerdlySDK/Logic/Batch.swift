import Foundation

/// The fixed part of every batch.
struct BatchEnvelope: Equatable, Sendable {
    var sdkName: String
    var sdkVersion: String
    var wrapper: String?
    var bundle: String
    var appVersion: String
    var appBuild: String
    var environment: String
    var installId: String
}

/// `POST /v1/sdk/batch` body. Optional members are omitted when nil (`context` when unchanged,
/// `sdk.wrapper` when there is no wrapper, an event's `user_id` when there is no user).
struct BatchRequest: Encodable, Sendable {
    struct SDK: Encodable, Sendable {
        let name: String
        let version: String
        let wrapper: String?
    }

    struct App: Encodable, Sendable {
        let bundle: String
        let version: String
        let build: String
        let environment: String
    }

    let sdk: SDK
    let app: App
    let installId: String
    let sentAt: Int64
    let context: JSONValue?
    let events: [WireEvent]

    enum CodingKeys: String, CodingKey {
        case sdk, app, context, events
        case installId = "install_id"
        case sentAt = "sent_at"
    }
}

enum BatchBuilder {
    /// ≤ 50 events, ≤ 256 KB uncompressed body.
    static let maxEvents = 50
    static let maxBodyBytes = 256 * 1024

    static func request(envelope: BatchEnvelope, sentAt: Int64, context: JSONValue?,
                        events: [QueuedEvent]) -> BatchRequest {
        BatchRequest(
            sdk: .init(name: envelope.sdkName, version: envelope.sdkVersion, wrapper: envelope.wrapper),
            app: .init(bundle: envelope.bundle, version: envelope.appVersion, build: envelope.appBuild,
                       environment: envelope.environment),
            installId: envelope.installId,
            sentAt: sentAt,
            context: context,
            events: events.map(\.wire)
        )
    }

    static func body(envelope: BatchEnvelope, sentAt: Int64, context: JSONValue?,
                     events: [QueuedEvent]) -> Data? {
        KerdlyJSON.encode(request(envelope: envelope, sentAt: sentAt, context: context, events: events))
    }

    /// Bytes the envelope (everything but the events) takes, for the batch size budget.
    static func overheadBytes(envelope: BatchEnvelope, context: JSONValue?) -> Int {
        body(envelope: envelope, sentAt: Int64.max, context: context, events: [])?.count ?? 2_048
    }
}

/// A `rejected` entry of the batch response.
struct RejectedEvent: Equatable, Sendable {
    let id: String
    let reason: String
}

/// The 200 response of `POST /v1/sdk/batch`. Missing members read as empty.
struct BatchResponse: Equatable, Sendable {
    var accepted: [String] = []
    var rejected: [RejectedEvent] = []
    var configEtag: String?
    var attribution: [String: JSONValue]?
    var needs: [String] = []
    var cvHints: [JSONValue] = []

    /// nil when the body is not a JSON object.
    static func parse(_ data: Data) -> BatchResponse? {
        guard let object = JSONValue.parse(data)?.objectValue else { return nil }
        var response = BatchResponse()
        response.accepted = object["accepted"]?.arrayValue?.compactMap(\.stringValue) ?? []
        response.rejected = object["rejected"]?.arrayValue?.compactMap { item -> RejectedEvent? in
            guard let id = item["id"]?.stringValue else { return nil }
            return RejectedEvent(id: id, reason: item["reason"]?.stringValue ?? "unknown")
        } ?? []
        response.configEtag = object["config_etag"]?.stringValue
        response.attribution = object["attribution"]?.objectValue
        response.needs = object["needs"]?.arrayValue?.compactMap(\.stringValue) ?? []
        response.cvHints = object["cv_hints"]?.arrayValue ?? []
        return response
    }

    /// Every id the response settles: accepted (stored, or a duplicate) and rejected (permanent).
    var settledIds: Set<String> {
        Set(accepted).union(rejected.map(\.id))
    }
}

/// What to do with a batch after the collector answered (status table).
enum DeliveryOutcome: Equatable, Sendable {
    /// 200: remove every accepted and rejected id; ids in neither list stay queued.
    case success(BatchResponse)
    /// 400 and unlisted 4xx: drop the batch. 401/403 also stop sending until the next launch.
    case drop(code: String, stopUntilNextLaunch: Bool)
    /// 408, 429, 404, 5xx, network errors, an unreadable 200: retry later. `retryAfter` is the
    /// server's `Retry-After`, which wins over the back-off.
    case retry(retryAfter: TimeInterval?)
    /// 413: split the batch in half and retry; a single event still too large is dropped.
    case split
}

enum DeliveryPolicy {
    /// - Parameters:
    ///   - status: the HTTP status, nil for a network error.
    static func classify(status: Int?, headers: [String: String], body: Data, now: Date) -> DeliveryOutcome {
        guard let status else { return .retry(retryAfter: nil) }
        let code = errorCode(body) ?? "http_\(status)"
        switch status {
        case 200..<300:
            guard let response = BatchResponse.parse(body) else { return .retry(retryAfter: nil) }
            return .success(response)
        case 401, 403:
            return .drop(code: code, stopUntilNextLaunch: true)
        case 408, 429:
            return .retry(retryAfter: retryAfter(headers: headers, now: now))
        case 413:
            return .split
        case 404:
            // A missing route is a deployment or endpoint problem, not a bad batch: keep the events.
            return .retry(retryAfter: retryAfter(headers: headers, now: now))
        case 400..<500:
            return .drop(code: code, stopUntilNextLaunch: false)
        default:
            return .retry(retryAfter: retryAfter(headers: headers, now: now))
        }
    }

    /// The `code` of an error body `{"error": …, "code": …}`.
    static func errorCode(_ body: Data) -> String? {
        JSONValue.parse(body)?["code"]?.stringValue
    }

    /// `Retry-After` in seconds (delta-seconds or an HTTP date), clamped to [0, 1 h]. Header names
    /// are expected lowercased.
    static func retryAfter(headers: [String: String], now: Date) -> TimeInterval? {
        guard let raw = headers["retry-after"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        let seconds: TimeInterval
        if let value = Double(raw) {
            seconds = value
        } else if let date = httpDate(raw) {
            seconds = date.timeIntervalSince(now)
        } else {
            return nil
        }
        guard seconds.isFinite else { return nil }
        return min(max(seconds, 0), 3_600)
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
