import Foundation
import StoreKit

/// StoreKit 2. Reads only: the SDK never purchases, never finishes a transaction (the paywall SDK
/// does) and never calls `AppTransaction.refresh()` (it can show a sign-in prompt).
final class SystemStoreKit: StoreKitProviding {
    static let maxHistoryScan = 200

    func appTransaction(_ completion: @escaping @Sendable (Result<AppTransactionInfo, KerdlyAdapterError>) -> Void) {
        guard #available(iOS 16.0, *) else {
            completion(.failure(KerdlyAdapterError("AppTransaction needs iOS 16")))
            return
        }
        Task.detached(priority: .utility) {
            do {
                let result = try await AppTransaction.shared
                // Verified or not, the server re-derives every field it trusts from the JWS.
                let transaction = result.unsafePayloadValue
                completion(.success(AppTransactionInfo(
                    jws: result.jwsRepresentation,
                    appTransactionId: Self.appTransactionId(transaction),
                    originalPurchaseDate: transaction.originalPurchaseDate,
                    originalAppVersion: transaction.originalAppVersion,
                    environment: transaction.environment.rawValue,
                    deviceVerificationNonce: transaction.deviceVerificationNonce.uuidString.lowercased(),
                    deviceVerification: transaction.deviceVerification.base64EncodedString())))
            } catch {
                completion(.failure(KerdlyAdapterError(String(describing: error))))
            }
        }
    }

    func currentEntitlements(_ completion: @escaping @Sendable ([PurchaseInfo]) -> Void) {
        Task.detached(priority: .utility) {
            var infos: [PurchaseInfo] = []
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result {
                    infos.append(Self.info(transaction))
                }
            }
            completion(infos)
        }
    }

    func findTransaction(transactionId: String?, originalTransactionId: String?, productId: String?,
                         _ completion: @escaping @Sendable (PurchaseInfo?) -> Void) {
        Task.detached(priority: .utility) {
            // The exact transaction wins; a transaction of the same subscription is the fallback.
            func exact(_ transaction: Transaction) -> Bool {
                transactionId.map { String(transaction.id) == $0 } ?? false
            }
            func sameOriginal(_ transaction: Transaction) -> Bool {
                originalTransactionId.map { String(transaction.originalID) == $0 } ?? false
            }
            var fallback: PurchaseInfo?
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result else { continue }
                if exact(transaction) { return completion(Self.info(transaction)) }
                if fallback == nil && sameOriginal(transaction) { fallback = Self.info(transaction) }
            }
            if let productId, let result = await Transaction.latest(for: productId),
               case .verified(let transaction) = result {
                if exact(transaction) { return completion(Self.info(transaction)) }
                if fallback == nil && sameOriginal(transaction) { fallback = Self.info(transaction) }
            }
            if transactionId != nil {
                var scanned = 0
                for await result in Transaction.all {
                    scanned += 1
                    if scanned > Self.maxHistoryScan { break }
                    if case .verified(let transaction) = result, exact(transaction) {
                        return completion(Self.info(transaction))
                    }
                }
            }
            completion(fallback)
        }
    }

    func observeUpdates(_ handler: @escaping @Sendable (PurchaseInfo) -> Void) {
        Task.detached(priority: .utility) {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    handler(Self.info(transaction))
                }
            }
        }
    }

    // MARK: - Mapping

    static func info(_ transaction: Transaction) -> PurchaseInfo {
        PurchaseInfo(
            originalTransactionId: String(transaction.originalID),
            transactionId: String(transaction.id),
            productId: transaction.productID,
            appAccountToken: transaction.appAccountToken?.uuidString.lowercased(),
            appTransactionId: appTransactionId(transaction),
            purchaseDate: transaction.purchaseDate,
            originalPurchaseDate: transaction.originalPurchaseDate,
            offerType: offerTypeName(transaction),
            isFreeTrial: isFreeTrial(transaction),
            environment: environment(transaction),
            isRenewal: isRenewal(transaction),
            revoked: transaction.revocationDate != nil)
    }

    /// `Transaction.offer` from iOS 17.2, the deprecated `offerType` before.
    static func offerType(_ transaction: Transaction) -> Transaction.OfferType? {
        if #available(iOS 17.2, *) {
            return transaction.offer?.type
        }
        return transaction.offerType
    }

    static func offerTypeName(_ transaction: Transaction) -> String? {
        guard let type = offerType(transaction) else { return nil }
        switch type {
        case .introductory: return "introductory"
        case .promotional: return "promotional"
        case .code: return "offer_code"
        case .winBack: return "win_back"
        default: return nil
        }
    }

    /// An introductory offer whose payment mode is free trial (an introductory offer of unknown mode
    /// counts as a trial: the lower rung, which a later conversion still raises).
    static func isFreeTrial(_ transaction: Transaction) -> Bool {
        guard offerType(transaction) == .introductory else { return false }
        let mode: String?
        if #available(iOS 17.2, *) {
            mode = transaction.offer?.paymentMode?.rawValue
        } else {
            mode = transaction.offerPaymentModeStringRepresentation
        }
        return mode == nil || mode == "FREE_TRIAL"
    }

    static func environment(_ transaction: Transaction) -> String? {
        let value: String
        if #available(iOS 16.0, *) {
            value = transaction.environment.rawValue
        } else {
            value = transaction.environmentStringRepresentation
        }
        return value.isEmpty ? nil : value
    }

    static func isRenewal(_ transaction: Transaction) -> Bool? {
        let reason: String
        if #available(iOS 17.0, *) {
            reason = transaction.reason.rawValue
        } else {
            reason = transaction.reasonStringRepresentation
        }
        switch reason {
        case "RENEWAL": return true
        case "PURCHASE": return false
        default: return nil
        }
    }

    /// `appTransactionID` is read where this SDK's headers have it (Xcode 16.3+ / iOS 18.4 SDK,
    /// back-deployed by StoreKit to iOS 15/16 for `Transaction`/`AppTransaction`); empty → nil.
    /// The server re-derives it from the verified JWS anyway.
    static func appTransactionId(_ transaction: Transaction) -> String? {
        #if compiler(>=6.1)
        let id = transaction.appTransactionID
        return id.isEmpty ? nil : id
        #else
        return nil
        #endif
    }

    @available(iOS 16.0, *)
    static func appTransactionId(_ transaction: AppTransaction) -> String? {
        #if compiler(>=6.1)
        let id = transaction.appTransactionID
        return id.isEmpty ? nil : id
        #else
        return nil
        #endif
    }
}
