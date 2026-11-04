import Foundation

/// What `environment: .auto` is decided from.
struct EnvironmentInputs: Equatable, Sendable {
    var isSimulator: Bool
    /// The SDK was compiled in a debug configuration (`DEBUG`); SPM and CocoaPods build it from
    /// source with the app's configuration.
    var isDebugBuild: Bool
    /// The app is development-signed: its `embedded.mobileprovision` grants `get-task-allow`
    /// (a build run from Xcode, debug or not).
    var isDevelopmentSigned: Bool
    /// `Bundle.main.appStoreReceiptURL?.lastPathComponent`.
    var receiptName: String?
}

enum EnvironmentResolver {
    /// `development` for a debug build or the simulator; else `sandbox` for a sandbox receipt
    /// (TestFlight); else `production`. An explicit option wins.
    static func resolve(option: KerdlyEnvironment, inputs: EnvironmentInputs) -> String {
        if option != .auto { return option.rawValue }
        if inputs.isSimulator || inputs.isDebugBuild || inputs.isDevelopmentSigned {
            return KerdlyEnvironment.development.rawValue
        }
        if inputs.receiptName == "sandboxReceipt" {
            return KerdlyEnvironment.sandbox.rawValue
        }
        return KerdlyEnvironment.production.rawValue
    }

    /// Whether provisioning-profile bytes grant `get-task-allow`. The profile is a CMS envelope around
    /// a plain-text plist, so the entitlement can be found without decoding the signature.
    static func profileAllowsDebugging(_ profile: Data) -> Bool {
        guard let text = String(data: profile, encoding: .isoLatin1),
              let key = text.range(of: "<key>get-task-allow</key>")
        else { return false }
        let rest = text[key.upperBound...].drop(while: { $0.isWhitespace })
        return rest.hasPrefix("<true/>")
    }
}
