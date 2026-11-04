import Foundation

/// Reserved event names. Apps cannot `track` a `$` name.
enum ReservedEvent {
    static let install = "$install"
    static let open = "$open"
    static let signal = "$signal"
    static let deeplink = "$deeplink"
    static let identify = "$identify"
    static let consent = "$consent"
    static let ids = "$ids"
    static let purchaseLink = "$purchase_link"
    static let skan = "$skan"
    static let networkSend = "$network_send"

    /// What is still enqueued with `analytics == false`. Everything else, custom
    /// events included, is dropped before enqueue.
    static let allowedWithoutAnalyticsConsent: Set<String> = [
        install, open, signal, consent, identify, ids, purchaseLink, skan,
    ]

    static func isReserved(_ name: String) -> Bool { name.hasPrefix("$") }
}

/// One queued event: the wire envelope plus its encoded size, which the queue's
/// 1 MB bound and the batch's 256 KB bound are computed from.
struct QueuedEvent: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let ts: Int64
    let seq: Int64
    let userId: String?
    let props: [String: JSONValue]
    let size: Int

    enum CodingKeys: String, CodingKey {
        case id, name, ts, seq, props, size
        case userId = "user_id"
    }

    init(id: String, name: String, ts: Int64, seq: Int64, userId: String?, props: [String: JSONValue]) {
        self.init(id: id, name: name, ts: ts, seq: seq, userId: userId, props: props, size: nil)
    }

    private init(id: String, name: String, ts: Int64, seq: Int64, userId: String?,
                 props: [String: JSONValue], size: Int?) {
        self.id = id
        self.name = name
        self.ts = ts
        self.seq = seq
        self.userId = userId
        self.props = props
        self.size = size ?? KerdlyJSON.encode(
            WireEvent(id: id, name: name, ts: ts, seq: seq, userId: userId, props: props)
        )?.count ?? 256
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            ts: try c.decode(Int64.self, forKey: .ts),
            seq: try c.decode(Int64.self, forKey: .seq),
            userId: try c.decodeIfPresent(String.self, forKey: .userId),
            props: try c.decodeIfPresent([String: JSONValue].self, forKey: .props) ?? [:],
            size: try c.decodeIfPresent(Int.self, forKey: .size)
        )
    }

    var isReserved: Bool { ReservedEvent.isReserved(name) }

    var wire: WireEvent {
        WireEvent(id: id, name: name, ts: ts, seq: seq, userId: userId, props: props)
    }
}

/// The event as it goes on the wire: `user_id` is omitted when there is none.
struct WireEvent: Encodable, Equatable, Sendable {
    let id: String
    let name: String
    let ts: Int64
    let seq: Int64
    let userId: String?
    let props: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case id, name, ts, seq, props
        case userId = "user_id"
    }
}

enum Clocks {
    /// Milliseconds since the epoch.
    static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(ms: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}
