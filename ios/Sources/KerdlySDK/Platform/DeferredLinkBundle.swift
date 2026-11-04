import Foundation

/// What the deferred-link requests read from the app bundle: the Facebook SDK's own config
/// (`FacebookAppID`, `FacebookClientToken`, both public) and the app's URL schemes.
struct DeferredLinkBundle: Sendable {
    var metaAppId: String?
    var metaClientToken: String?
    var urlSchemes: [String]
    var appName: String
    var regionCode: String

    static func read(_ bundle: Bundle = .main) -> DeferredLinkBundle {
        let info = bundle.infoDictionary ?? [:]
        let nonEmpty = { (key: String) -> String? in
            (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let types = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return DeferredLinkBundle(
            metaAppId: nonEmpty("FacebookAppID"),
            metaClientToken: nonEmpty("FacebookClientToken"),
            urlSchemes: types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] },
            appName: nonEmpty("CFBundleDisplayName") ?? nonEmpty("CFBundleName") ?? "",
            regionCode: (Locale.current as NSLocale).countryCode ?? "")
    }
}
