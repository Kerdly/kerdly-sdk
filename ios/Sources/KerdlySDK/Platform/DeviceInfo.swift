import Foundation
import UIKit

/// Bundle, file-system and UIKit facts. Never collects disk space or boot time.
final class SystemDeviceInfo: DeviceInfoProviding {
    func appInfo() -> AppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppInfo(
            bundle: Bundle.main.bundleIdentifier ?? "unknown",
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? "")
    }

    func facts() -> DeviceFacts {
        DeviceFacts(
            os: ContextBuilder.osVersion(ProcessInfo.processInfo.operatingSystemVersion),
            model: Self.modelIdentifier(),
            locale: ContextBuilder.localeIdentifier(Locale.current.identifier),
            languages: Array(Locale.preferredLanguages.prefix(5)),
            timeZone: TimeZone.current.identifier)
    }

    /// `utsname.machine`, e.g. `iPhone17,1`; the simulated model in the simulator.
    static func modelIdentifier() -> String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        #endif
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    @MainActor
    func snapshot() -> DeviceSnapshot {
        let screen = UIScreen.main
        let bounds = screen.nativeBounds
        return DeviceSnapshot(
            idfv: UIDevice.current.identifierForVendor?.uuidString,
            screenWidth: Int(bounds.width.rounded()),
            screenHeight: Int(bounds.height.rounded()),
            screenScale: Double(screen.nativeScale),
            isForeground: UIApplication.shared.applicationState != .background)
    }

    /// The Documents directory's creation date (FileTimestamp, reason C617.1): the moment the app's
    /// container was created by this install.
    func installedAt() -> Date? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let attributes = try? FileManager.default.attributesOfItem(atPath: documents.path),
              let created = attributes[.creationDate] as? Date
        else { return nil }
        return created
    }

    func deferredLinkBundle() -> DeferredLinkBundle {
        DeferredLinkBundle.read()
    }

    func environmentInputs() -> EnvironmentInputs {
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
        return EnvironmentInputs(
            isSimulator: simulator,
            isDebugBuild: debug,
            isDevelopmentSigned: profile.map(EnvironmentResolver.profileAllowsDebugging) ?? false,
            receiptName: Bundle.main.appStoreReceiptURL?.lastPathComponent)
    }
}
