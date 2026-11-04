import Foundation
import AdServices
import AdSupport

/// `AAAttribution.attributionToken()` (iOS 14.3+). It can throw and may block: callers run it off
/// the main thread.
final class SystemAdServices: AdServicesTokenProviding {
    func attributionToken() throws -> String {
        try AAAttribution.attributionToken()
    }
}

/// The IDFA. The core reads it only when ATT = authorized and `ads` consent is on.
final class SystemAdvertisingId: AdvertisingIdProviding {
    func advertisingId() -> String? {
        let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        return idfa == "00000000-0000-0000-0000-000000000000" ? nil : idfa
    }
}
