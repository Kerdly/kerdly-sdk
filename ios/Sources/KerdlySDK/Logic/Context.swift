import Foundation

/// App identity from the main bundle.
struct AppInfo: Equatable, Sendable {
    var bundle: String
    var version: String
    var build: String
}

/// Device facts that need the main thread (UIKit), captured once and refreshed on activation.
struct DeviceSnapshot: Equatable, Sendable {
    var idfv: String?
    var screenWidth: Int
    var screenHeight: Int
    var screenScale: Double
    /// `applicationState != .background`.
    var isForeground: Bool
}

/// Device facts readable from any thread.
struct DeviceFacts: Equatable, Sendable {
    var os: String
    var model: String
    var locale: String
    var languages: [String]
    var timeZone: String
}

enum ContextBuilder {
    /// The batch `context`: the device fields plus `consent`. `lat` is Android-only.
    static func context(facts: DeviceFacts, snapshot: DeviceSnapshot?, att: KerdlyAttStatus,
                        analytics: Bool, ads: Bool, app: AppInfo) -> JSONValue {
        var object = deviceFields(facts: facts, snapshot: snapshot, att: att, app: app)
        object["consent"] = .object(["analytics": .bool(analytics), "ads": .bool(ads)])
        return .object(object)
    }

    /// `$install`'s `device`: the context's fields without `consent`, built by the
    /// same code so the two never differ.
    static func device(facts: DeviceFacts, snapshot: DeviceSnapshot?, att: KerdlyAttStatus,
                       app: AppInfo) -> JSONValue {
        .object(deviceFields(facts: facts, snapshot: snapshot, att: att, app: app))
    }

    /// `screen` and `idfv` come from the UIKit snapshot and are omitted while there is none; `idfv`
    /// also when UIKit does not know it yet.
    private static func deviceFields(facts: DeviceFacts, snapshot: DeviceSnapshot?, att: KerdlyAttStatus,
                                     app: AppInfo) -> [String: JSONValue] {
        var object: [String: JSONValue] = [
            "platform": .string("ios"),
            "os": .string(facts.os),
            "model": .string(facts.model),
            "manufacturer": .string("Apple"),
            "locale": .string(facts.locale),
            "languages": .array(facts.languages.prefix(5).map { .string($0) }),
            "tz": .string(facts.timeZone),
            "att": .string(att.rawValue),
            "app_version": .string(app.version),
            "app_build": .string(app.build),
        ]
        if let snapshot {
            object["screen"] = .object([
                "w": .int(Int64(snapshot.screenWidth)),
                "h": .int(Int64(snapshot.screenHeight)),
                "scale": .number(snapshot.screenScale),
            ])
            if let idfv = snapshot.idfv {
                object["idfv"] = .string(idfv)
            }
        }
        return object
    }

    /// `Locale.current.identifier` without `@…` keywords (e.g. `en_US@calendar=japanese` → `en_US`).
    static func localeIdentifier(_ identifier: String) -> String {
        String(identifier.split(separator: "@", maxSplits: 1).first ?? Substring(identifier))
    }

    /// "26.0.1"; the patch is omitted when 0, as `UIDevice.systemVersion` does.
    static func osVersion(_ v: OperatingSystemVersion) -> String {
        v.patchVersion > 0
            ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            : "\(v.majorVersion).\(v.minorVersion)"
    }
}
