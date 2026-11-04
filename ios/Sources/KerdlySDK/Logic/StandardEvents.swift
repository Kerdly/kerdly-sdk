import Foundation

/// Standard events: ordinary event names whose typed props are checked the same way
/// whether they come from the typed methods or from `track`. The other props follow the custom rules
/// (`EventValidator`), and the typed ones count toward the 25. A bad typed prop drops only that prop.
enum StandardEvent {
    static let registration = "registration"
    static let startTrial = "start_trial"
    static let subscribe = "subscribe"
    static let purchase = "purchase"

    static let maxIdLength = 128
    static let maxMethodLength = 64

    private static let money = ["product_id", "value", "currency", "transaction_id"]

    /// Each standard event's typed keys.
    static let typedKeys: [String: [String]] = [
        registration: ["method"],
        startTrial: money,
        subscribe: money,
        purchase: ["product_id", "value", "currency", "quantity", "transaction_id"],
    ]

    // MARK: The typed methods' arguments, as props (nil arguments are left out)

    static func arguments(method: String?) -> [String: Any] {
        var args: [String: Any] = [:]
        if let method { args["method"] = method }
        return args
    }

    static func arguments(productId: String?, value: Double?, currency: String?, quantity: Int? = nil,
                          transactionId: String?) -> [String: Any] {
        var args: [String: Any] = [:]
        if let productId { args["product_id"] = productId }
        if let value { args["value"] = value }
        if let currency { args["currency"] = currency }
        if let quantity { args["quantity"] = quantity }
        if let transactionId { args["transaction_id"] = transactionId }
        return args
    }

    /// A typed method's props: its arguments, then `properties` for every key no argument set. The
    /// keys an argument kept `properties` from setting come back as `ignored`.
    static func merge(_ arguments: [String: Any], _ properties: [String: Any]) -> (props: [String: Any], ignored: [String]) {
        var merged = arguments
        var ignored: [String] = []
        for (key, value) in properties {
            if arguments[key] != nil { ignored.append(key) } else { merged[key] = value }
        }
        return (merged, ignored.sorted())
    }

    // MARK: Validation

    /// The props of an event named `name`: the typed checks for a standard name, then the custom
    /// rules for the rest (only the custom rules for any other name).
    static func sanitize(_ name: String, _ properties: [String: Any]) -> EventValidator.Sanitized {
        guard let keys = typedKeys[name] else { return EventValidator.sanitize(properties) }
        var props: [String: JSONValue] = [:]
        var issues: [String] = []
        var custom = properties
        for key in keys {
            guard let raw = custom.removeValue(forKey: key) else { continue }
            switch typed(key, raw) {
            case .kept(let value):
                props[key] = value
            case .truncated(let value, let max):
                props[key] = value
                issues.append("prop '\(key)' truncated to \(max) characters")
            case .dropped(let reason):
                issues.append("prop '\(key)' dropped: \(reason)")
            }
        }
        // A value without a currency means nothing to a network.
        if props["value"] != nil && props["currency"] == nil {
            props["value"] = nil
            issues.append("prop 'value' dropped: no valid currency")
        }
        let rest = EventValidator.sanitize(custom, limit: EventValidator.maxProps - props.count)
        props.merge(rest.props) { current, _ in current }
        return EventValidator.Sanitized(props: props, issues: issues + rest.issues)
    }

    private enum Typed {
        case kept(JSONValue)
        /// The value cut to the length limit given.
        case truncated(JSONValue, Int)
        case dropped(String)
    }

    private static func typed(_ key: String, _ raw: Any) -> Typed {
        let value = JSONValue(any: raw)
        switch key {
        case "product_id", "transaction_id", "method":
            guard let s = value?.stringValue else { return .dropped("not a string") }
            let max = key == "method" ? maxMethodLength : maxIdLength
            if let cut = EventValidator.truncated(s, to: max) { return .truncated(.string(cut), max) }
            return .kept(.string(s))
        case "currency":
            guard let code = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                  isCurrencyCode(code)
            else { return .dropped("not a three-letter ISO 4217 code") }
            return .kept(.string(code))
        case "value":
            switch value {
            case .int(let i) where i >= 0: return .kept(.int(i))
            case .double(let d) where d.isFinite && d >= 0: return .kept(.number(d))
            default: return .dropped("not a finite number ≥ 0")
            }
        case "quantity":
            // `JSONValue` stores an integral double (2.0) as an integer, so 2.0 counts and 2.5 does not.
            guard case .int(let q) = value, q >= 1 else { return .dropped("not an integer ≥ 1") }
            return .kept(.int(q))
        default:
            return .dropped("not a typed prop")
        }
    }

    /// `^[A-Z]{3}$`, byte by byte.
    static func isCurrencyCode(_ code: String) -> Bool {
        let bytes = Array(code.utf8)
        return bytes.count == 3 && bytes.allSatisfy { $0 >= 0x41 && $0 <= 0x5A }
    }
}
