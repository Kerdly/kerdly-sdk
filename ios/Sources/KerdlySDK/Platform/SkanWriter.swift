import Foundation
import StoreKit
#if canImport(AdAttributionKit)
import AdAttributionKit
#endif

/// SKAdNetwork and the AdAttributionKit mirror. Only `SkanCoordinator` calls these, and only when
/// both `skanWriter` and the config's `skan.enabled` are on.
final class SystemSkanWriter: SkanWriting {
    var skanApiName: String? {
        if #available(iOS 16.1, *) { return "skan4" }
        if #available(iOS 15.4, *) { return "skan3" }
        return nil
    }

    /// iOS 16.1+: fine + coarse + lockWindow; 15.4–16.0: fine only. Below 15.4 there is no API that
    /// reports an outcome, so nothing is written. (Sequential checks, not `else if #available`: the
    /// chained form warns "unnecessary check" when an app compiles this at a 16.1+ deployment target.)
    func updateSkan(fine: Int, coarse: SkanCoarse, lockWindow: Bool,
                    completion: @escaping @Sendable (SkanWriteResult) -> Void) {
        if #available(iOS 16.1, *) {
            SKAdNetwork.updatePostbackConversionValue(fine, coarseValue: Self.coarseValue(coarse),
                                                      lockWindow: lockWindow) { error in
                completion(.completed(api: "skan4", error: Self.describe(error)))
            }
            return
        }
        if #available(iOS 15.4, *) {
            SKAdNetwork.updatePostbackConversionValue(fine) { error in
                completion(.completed(api: "skan3", error: Self.describe(error)))
            }
            return
        }
        completion(.unsupported)
    }

    /// iOS 17.4+: `Postback.updateConversionValue(_:lockPostback:)`.
    func updateAak(fine: Int, lockPostback: Bool, completion: @escaping @Sendable (SkanWriteResult) -> Void) {
        #if canImport(AdAttributionKit)
        if #available(iOS 17.4, *) {
            Task.detached(priority: .utility) {
                do {
                    try await Postback.updateConversionValue(fine, lockPostback: lockPostback)
                    completion(.completed(api: "aak", error: nil))
                } catch {
                    completion(.completed(api: "aak", error: Self.describe(error)))
                }
            }
            return
        }
        #endif
        completion(.unsupported)
    }

    @available(iOS 16.1, *)
    static func coarseValue(_ coarse: SkanCoarse) -> SKAdNetwork.CoarseConversionValue {
        switch coarse {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }

    /// `"<domain> <code>"`, short and stable for the `$skan.error` prop.
    static func describe(_ error: Error?) -> String? {
        guard let error else { return nil }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}
