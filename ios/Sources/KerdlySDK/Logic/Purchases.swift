import Foundation

/// A verified StoreKit 2 transaction, reduced to what `$purchase_link` and the SKAN triggers need.
struct PurchaseInfo: Equatable, Sendable {
    let originalTransactionId: String
    let transactionId: String
    let productId: String
    /// Lowercase UUID string.
    let appAccountToken: String?
    let appTransactionId: String?
    let purchaseDate: Date
    let originalPurchaseDate: Date
    /// `introductory` | `promotional` | `offer_code` | `win_back` | nil.
    let offerType: String?
    let isFreeTrial: Bool
    /// `Production` | `Sandbox` | `Xcode`.
    let environment: String?
    let isRenewal: Bool?
    let revoked: Bool

    var facts: PurchaseFacts {
        PurchaseFacts(isFreeTrial: isFreeTrial, purchaseDate: purchaseDate,
                      originalPurchaseDate: originalPurchaseDate, isRenewal: isRenewal, revoked: revoked)
    }
}

/// Where a purchase link came from (`$purchase_link.source`).
enum PurchaseSource: String, Sendable {
    case notify, entitlements, updates
}

/// The app's `notifyPurchase` ids, in Sendable form.
struct NotifiedPurchase: Equatable, Sendable {
    var originalTransactionId: String?
    var transactionId: String?
    var productId: String?
    var appAccountToken: String?

    init(_ purchase: KerdlyPurchase) {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        originalTransactionId = clean(purchase.originalTransactionId)
        transactionId = clean(purchase.transactionId)
        productId = clean(purchase.productId)
        appAccountToken = purchase.appAccountToken?.uuidString.lowercased()
    }

    var hasIds: Bool { originalTransactionId != nil || transactionId != nil }
}

enum PurchaseLinks {
    /// The ids a link is deduplicated on: its original transaction id (one link per `originalID`),
    /// plus its transaction id, which is all a notify without the original id is known by.
    static func dedupeKeys(info: PurchaseInfo?, notified: NotifiedPurchase?) -> [String] {
        var keys: [String] = []
        for key in [notified?.originalTransactionId, info?.originalTransactionId,
                    notified?.transactionId, info?.transactionId] {
            if let key, !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    static func isReported(_ keys: [String], in reported: [String]) -> Bool {
        keys.contains { reported.contains($0) }
    }

    /// `$purchase_link` props for iOS. The app's notified ids win over what StoreKit reported.
    static func props(info: PurchaseInfo?, notified: NotifiedPurchase?, source: PurchaseSource) -> [String: JSONValue] {
        [
            "store": .string("app_store"),
            "original_transaction_id": .string(notified?.originalTransactionId ?? info?.originalTransactionId),
            "transaction_id": .string(notified?.transactionId ?? info?.transactionId),
            "product_id": .string(notified?.productId ?? info?.productId),
            "app_account_token": .string(notified?.appAccountToken ?? info?.appAccountToken),
            "app_transaction_id": .string(info?.appTransactionId),
            "purchase_date": .int(info.map { Clocks.ms($0.purchaseDate) }),
            "offer_type": .string(info?.offerType),
            "environment": .string(info?.environment),
            "source": .string(source.rawValue),
        ]
    }
}
