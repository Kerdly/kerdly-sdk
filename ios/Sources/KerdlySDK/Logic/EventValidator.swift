import Foundation

/// Custom event rules: names and keys match `^[a-z][a-z0-9_]{0,39}$`, at most 25
/// props, values are strings (truncated to 256 characters), finite numbers or booleans. Anything
/// else is dropped before enqueue; the caller logs the issues at debug level.
enum EventValidator {
    static let maxProps = 25
    static let maxStringLength = 256
    static let maxNameLength = 40

    /// `^[a-z][a-z0-9_]{0,39}$`, checked byte by byte (no regex engine on the hot path).
    static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...maxNameLength).contains(bytes.count) else { return false }
        guard let first = bytes.first, first >= 0x61, first <= 0x7A else { return false }
        for b in bytes.dropFirst() {
            let lower = b >= 0x61 && b <= 0x7A
            let digit = b >= 0x30 && b <= 0x39
            if !(lower || digit || b == 0x5F) { return false }
        }
        return true
    }

    struct Sanitized: Equatable {
        var props: [String: JSONValue]
        var issues: [String]
    }

    /// Keeps the valid props. Keys are visited in sorted order, so which ones survive is stable.
    /// - Parameter limit: how many props may be kept (a standard event's typed props use up part of
    ///   the 25).
    static func sanitize(_ properties: [String: Any], limit: Int = maxProps) -> Sanitized {
        var props: [String: JSONValue] = [:]
        var issues: [String] = []
        for key in properties.keys.sorted() {
            guard isValidName(key) else {
                issues.append("prop key '\(key)' is invalid")
                continue
            }
            guard let value = sanitizeValue(properties[key] as Any) else {
                issues.append("prop '\(key)' has an unsupported value")
                continue
            }
            if props.count >= limit {
                issues.append("prop '\(key)' is over the \(maxProps)-prop limit")
                continue
            }
            if case .string(let s) = value, let cut = truncated(s, to: maxStringLength) {
                issues.append("prop '\(key)' truncated to \(maxStringLength) characters")
                props[key] = .string(cut)
            } else {
                props[key] = value
            }
        }
        return Sanitized(props: props, issues: issues)
    }

    /// A string, a finite number or a boolean; nil for anything else (nested values included).
    static func sanitizeValue(_ value: Any) -> JSONValue? {
        guard let v = JSONValue(any: value) else { return nil }
        switch v {
        case .string, .bool, .int:
            return v
        case .double(let d):
            return d.isFinite ? v : nil
        case .null, .array, .object:
            return nil
        }
    }

    /// `s` cut to at most `max` UTF-16 units (how the collector, Kotlin and JavaScript count string
    /// length) without splitting a character; nil when it already fits.
    static func truncated(_ s: String, to max: Int) -> String? {
        guard s.utf16.count > max else { return nil }
        var units = 0
        var end = s.startIndex
        for character in s {
            units += character.utf16.count
            if units > max { break }
            end = s.index(after: end)
        }
        return String(s[..<end])
    }
}
