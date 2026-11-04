import Foundation

/// A JSON value. Every payload the SDK builds, sends or stores is one of these, so payloads are
/// `Sendable` and integers stay integers on the wire (`ts`, `seq`, ms timestamps).
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    /// A number; integral doubles are stored as integers so `3.0` encodes as `3`.
    static func number(_ value: Double) -> JSONValue {
        if value.isFinite, value.rounded() == value, abs(value) < 9.0e15 {
            return .int(Int64(value))
        }
        return .double(value)
    }

    static func string(_ value: String?) -> JSONValue {
        value.map { JSONValue.string($0) } ?? .null
    }

    static func int(_ value: Int64?) -> JSONValue {
        value.map { JSONValue.int($0) } ?? .null
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// A string, or an integer rendered as one (ids the server might send as numbers).
    var lenientStringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var int64Value: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.isFinite && d.rounded() == d && abs(d) < 9.0e18: return Int64(d)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Foundation form (`NSNull` for null), for the public `KerdlyAttribution.raw`.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.anyValue }
        case .object(let o): return o.mapValues { $0.anyValue }
        }
    }

    /// Converts a Foundation value (from `JSONSerialization` or an app's `[String: Any]`).
    /// `NSNumber` booleans are told apart from numbers; non-finite numbers and other types are nil.
    init?(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let s as String:
            self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                let d = n.doubleValue
                guard d.isFinite else { return nil }
                self = .number(d)
            } else {
                self = .int(n.int64Value)
            }
        case let a as [Any]:
            var out: [JSONValue] = []
            out.reserveCapacity(a.count)
            for item in a {
                guard let v = JSONValue(any: item) else { return nil }
                out.append(v)
            }
            self = .array(out)
        case let o as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, item) in o {
                guard let v = JSONValue(any: item) else { return nil }
                out[k] = v
            }
            self = .object(out)
        default:
            return nil
        }
    }

    /// Parses JSON bytes. Fragments (a bare string or number) are allowed.
    static func parse(_ data: Data) -> JSONValue? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return JSONValue(any: obj)
    }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// One encoder configuration for everything the SDK writes: sorted keys (stable output and stable
/// context hashes) and unescaped slashes (readable URLs).
enum KerdlyJSON {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? encoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
