import Foundation

/// Everything the SDK remembers between launches (`Application Support/afr/state.json`).
///
/// The file is included in device backups, so a backup restored onto another phone brings it back
/// along with the UserDefaults copy of the id, and the restore mints a new install id. Fields are
/// therefore split: install-scoped ones reset whenever the install id changes (and at every
/// `$install`); user-scoped ones (the app's user id, consent and ids) carry over.
struct PersistedState: Codable, Equatable, Sendable {
    var installId: String

    // MARK: Install-scoped

    /// The last `seq` used; the next event gets `seq + 1`.
    var seq: Int64 = 0
    /// ms; the launch that enqueued this install's `$install`.
    var firstLaunchAt: Int64?
    /// ms; the Documents directory's creation date.
    var installedAt: Int64?
    var lastAckedContextHash: String?
    /// Original transaction ids (and notify-only transaction ids) already sent as `$purchase_link`.
    var reportedPurchaseIds: [String] = []
    /// AdServices token signals enqueued for this install (at most 3).
    var asaAttempts = 0
    /// A token signal is wanted: from the `$install` launch until one is sent (within 48 h of the
    /// first launch), or a response's `needs`.
    var asaDue = false
    /// Failed token requests in the current round (a launch or a foreground); the round gives up
    /// after 3, and the next launch or foreground starts another.
    var asaFailures = 0
    var appTransactionSent = false
    /// Highest SKAN fine value Apple accepted.
    var skanFloor: Int?
    /// Attribution-bearing `$deeplink` events not yet accepted by the server.
    var pendingDeepLinks: [QueuedEvent] = []
    var attribution: JSONValue?
    var lastAttStatus: String?
    /// SHA-256 of the last IDFA sent, so it is signalled only when it changes.
    var idfaHash: String?
    var backoffAttempt = 0
    /// ms; no automatic flush before this.
    var retryAt: Int64?
    /// `retryAt` came from the server's `Retry-After` (an explicit `flush()` honours it too).
    var retryAtFromServer = false
    /// Deferred deep links: asked only for an install whose `$install` was fresh or a
    /// reinstall, never a restore.
    var ddlEligible = false
    /// Per network (`meta`, `tiktok`): the answer is in, or how many tries failed in transit.
    var ddl: [String: DdlNetworkState] = [:]

    // MARK: User-scoped

    var userId: String?
    var consentAnalytics = true
    var consentAds = true
    /// Lowercase UUID string.
    var appAccountToken: String?
    var partnerIds: [String: String] = [:]

    init(installId: String) {
        self.installId = installId
    }

    /// Keeps the user-scoped fields, resets the rest for `installId`.
    func reset(for installId: String) -> PersistedState {
        var next = PersistedState(installId: installId)
        next.userId = userId
        next.consentAnalytics = consentAnalytics
        next.consentAds = consentAds
        next.appAccountToken = appAccountToken
        next.partnerIds = partnerIds
        return next
    }

    static let maxReportedPurchaseIds = 500
    static let maxPendingDeepLinks = 20

    mutating func markReported(_ keys: [String]) {
        for key in keys where !reportedPurchaseIds.contains(key) {
            reportedPurchaseIds.append(key)
        }
        if reportedPurchaseIds.count > Self.maxReportedPurchaseIds {
            reportedPurchaseIds.removeFirst(reportedPurchaseIds.count - Self.maxReportedPurchaseIds)
        }
    }

    enum CodingKeys: String, CodingKey {
        case installId = "install_id"
        case seq
        case firstLaunchAt = "first_launch_at"
        case installedAt = "installed_at"
        case lastAckedContextHash = "last_acked_context_hash"
        case reportedPurchaseIds = "reported_purchase_ids"
        case asaAttempts = "asa_attempts"
        case asaDue = "asa_due"
        case asaFailures = "asa_failures"
        case appTransactionSent = "app_transaction_sent"
        case skanFloor = "skan_floor"
        case pendingDeepLinks = "pending_deep_links"
        case attribution
        case lastAttStatus = "last_att_status"
        case idfaHash = "idfa_hash"
        case backoffAttempt = "backoff_attempt"
        case retryAt = "retry_at"
        case retryAtFromServer = "retry_at_from_server"
        case ddlEligible = "ddl_eligible"
        case ddl
        case userId = "user_id"
        case consentAnalytics = "consent_analytics"
        case consentAds = "consent_ads"
        case appAccountToken = "app_account_token"
        case partnerIds = "partner_ids"
    }

    /// Lenient: a missing or unreadable field takes its default, so a newer or older file still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        installId = try c.decode(String.self, forKey: .installId)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        seq = get(.seq, 0)
        firstLaunchAt = get(.firstLaunchAt, nil)
        installedAt = get(.installedAt, nil)
        lastAckedContextHash = get(.lastAckedContextHash, nil)
        reportedPurchaseIds = get(.reportedPurchaseIds, [])
        asaAttempts = get(.asaAttempts, 0)
        asaDue = get(.asaDue, false)
        asaFailures = get(.asaFailures, 0)
        appTransactionSent = get(.appTransactionSent, false)
        skanFloor = get(.skanFloor, nil)
        pendingDeepLinks = get(.pendingDeepLinks, [])
        attribution = get(.attribution, nil)
        lastAttStatus = get(.lastAttStatus, nil)
        idfaHash = get(.idfaHash, nil)
        backoffAttempt = get(.backoffAttempt, 0)
        retryAt = get(.retryAt, nil)
        retryAtFromServer = get(.retryAtFromServer, false)
        ddlEligible = get(.ddlEligible, false)
        ddl = get(.ddl, [:])
        userId = get(.userId, nil)
        consentAnalytics = get(.consentAnalytics, true)
        consentAds = get(.consentAds, true)
        appAccountToken = get(.appAccountToken, nil)
        partnerIds = get(.partnerIds, [:])
    }
}

/// One network's deferred-link progress for this install.
struct DdlNetworkState: Codable, Equatable, Sendable {
    /// The network answered (a link, none, a refusal) or the SDK gave up: never asked again.
    var done = false
    /// Tries that failed in transit (no answer, 429, 5xx); the SDK gives up after 3.
    var failures = 0
}

/// The queue file (`Application Support/afr/queue.json`), tagged with the install id it belongs to.
struct QueueFile: Codable, Equatable, Sendable {
    var version = 1
    var installId: String
    var events: [QueuedEvent]

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case installId = "install_id"
        case events
    }
}

/// Where the SDK's files live, and how they are read and written.
enum StateFiles {
    static let state = "state.json"
    static let queue = "queue.json"
    static let config = "config.json"
}
