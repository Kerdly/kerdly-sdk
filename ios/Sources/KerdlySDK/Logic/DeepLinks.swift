import Foundation

/// The params `handleUrl` reads. They come from the query string whatever the
/// scheme, host or path, e.g. `myapp://onboarding?cpp=<slug>`.
struct ParsedDeepLink: Equatable, Sendable {
    /// The URL as given, truncated to `DeepLinkParser.maxUrlLength`.
    let url: String
    let cpp: String?
    let ppid: String?
    /// A Kerdly link's click id (`kerdly_c`).
    let clickId: String?
    /// The web visit the link continues (`kerdly_v`).
    let visitId: String?
    let campaignIds: String?

    /// Carries an attribution tag, so it is kept pending until a batch containing it is accepted.
    var isAttributionBearing: Bool {
        cpp != nil || ppid != nil || clickId != nil || visitId != nil
    }

    var props: [String: JSONValue] {
        [
            "url": .string(url),
            "cpp": .string(cpp),
            "ppid": .string(ppid),
            "kerdly_c": .string(clickId),
            "kerdly_v": .string(visitId),
            "campaign_ids": .string(campaignIds),
        ]
    }
}

enum DeepLinkParser {
    static let maxUrlLength = 4_096

    static func parse(_ url: URL) -> ParsedDeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            ?? URLComponents(string: url.absoluteString)
        else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            for item in items where item.name == name {
                if let v = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                    return v
                }
            }
            return nil
        }
        return ParsedDeepLink(
            url: String(url.absoluteString.prefix(maxUrlLength)),
            cpp: value("cpp"),
            ppid: value("ppid"),
            // Links made before 0.1.0 spell these `afr_c` and `afr_v`.
            clickId: value("kerdly_c") ?? value("afr_c"),
            visitId: value("kerdly_v") ?? value("afr_v"),
            campaignIds: value("campaign_ids")
        )
    }
}

/// Decides `$deeplink.source`. A caller that knows it (the Expo bridge: React Native's initial URL
/// vs its `url` events) passes `"initial"` or `"runtime"`, which wins. Otherwise it is inferred: the
/// first URL handled in this process, within a minute of `configure` and before the app has gone to
/// the background, is the launch URL (`initial`); everything else is `runtime`. Any handled URL, an
/// explicit `"initial"` included, uses up the inferred initial.
struct DeepLinkSourceTracker: Sendable {
    static let initialWindow: TimeInterval = 60
    static let sources: Set<String> = ["initial", "runtime"]

    private(set) var handledAny = false
    private(set) var backgroundedSinceConfigure = false
    let configuredAt: Date

    init(configuredAt: Date) {
        self.configuredAt = configuredAt
    }

    mutating func didEnterBackground() {
        backgroundedSinceConfigure = true
    }

    /// - Parameter explicit: the caller's `source`; any value other than `"initial"` / `"runtime"`
    ///   (or nil) falls back to the inference.
    mutating func source(at now: Date, explicit: String? = nil) -> String {
        defer { handledAny = true }
        if let explicit, Self.sources.contains(explicit) {
            return explicit
        }
        let initial = !handledAny && !backgroundedSinceConfigure
            && now.timeIntervalSince(configuredAt) <= Self.initialWindow
        return initial ? "initial" : "runtime"
    }
}
