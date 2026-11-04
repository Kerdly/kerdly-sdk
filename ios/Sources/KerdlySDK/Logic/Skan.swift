import Foundation

enum SkanCoarse: String, Sendable, Equatable {
    case low, medium, high

    var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }
}

/// One rung of the conversion-value ladder (config `skan.rungs`).
struct SkanRung: Equatable, Sendable {
    let event: String
    let fine: Int
    let coarse: SkanCoarse
    /// `launch` | `event` | `purchase` | `sweep` (| `ledger`, server hints, not used in v0.1).
    let on: Set<String>
}

/// The config's `skan` block. `parse` re-checks the ladder rules and returns nil for
/// an invalid ladder, so the caller keeps the last valid one.
struct SkanSchema: Equatable, Sendable {
    let version: Int
    let enabled: Bool
    let rungs: [SkanRung]
    let lockWindow: Bool
    let aakMirror: Bool

    static func parse(_ json: JSONValue?) -> SkanSchema? {
        guard let object = json?.objectValue else { return nil }
        guard let rawRungs = object["rungs"]?.arrayValue else { return nil }
        var rungs: [SkanRung] = []
        for raw in rawRungs {
            guard let event = raw["event"]?.stringValue, !event.isEmpty,
                  let fine = raw["fine"]?.int64Value, (0...63).contains(fine),
                  let coarseName = raw["coarse"]?.stringValue, let coarse = SkanCoarse(rawValue: coarseName)
            else { return nil }
            let on = Set(raw["on"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            rungs.append(SkanRung(event: event, fine: Int(fine), coarse: coarse, on: on))
        }
        // Fine values strictly increase down the ladder, coarse values never go down, events are unique.
        for (previous, next) in zip(rungs, rungs.dropFirst()) {
            if next.fine <= previous.fine || next.coarse.rank < previous.coarse.rank { return nil }
        }
        if Set(rungs.map(\.event)).count != rungs.count { return nil }
        return SkanSchema(
            version: Int(object["version"]?.int64Value ?? 0),
            enabled: object["enabled"]?.boolValue ?? false,
            rungs: rungs,
            lockWindow: object["lock_window"]?.boolValue ?? false,
            aakMirror: object["aak_mirror"]?.boolValue ?? false
        )
    }
}

/// What a StoreKit transaction says, for the `purchase` / `sweep` triggers.
struct PurchaseFacts: Equatable, Sendable {
    /// An introductory offer whose payment mode is free trial.
    let isFreeTrial: Bool
    let purchaseDate: Date
    let originalPurchaseDate: Date
    /// From `Transaction.reason`; nil when unknown.
    let isRenewal: Bool?
    let revoked: Bool
}

enum SkanTrigger: Equatable, Sendable {
    /// The first launch's baseline.
    case launch
    /// A reserved or custom event of the rung's name was enqueued.
    case event(String)
    /// A StoreKit transaction seen on the device (paywall notify, `Transaction.updates`).
    case purchase(PurchaseFacts)
    /// The `Transaction.currentEntitlements` sweep.
    case sweep(PurchaseFacts)
}

/// When this install's conversion clock started.
struct SkanTimeline: Equatable, Sendable {
    /// The install moment: the earlier of `installed_at` (the Documents directory's creation) and
    /// the SDK's first launch. The Documents directory is recreated on a reinstall, so a returning
    /// subscriber's old entitlement still predates it; and when an app update brings the SDK to an
    /// existing install, it keeps the install's real age instead of the update's.
    let start: Date

    init(firstLaunchAt: Date, installedAt: Date?) {
        start = min(installedAt ?? firstLaunchAt, firstLaunchAt)
    }
}

enum SkanPlanner {
    /// SKAN 4's first conversion window. The baseline is written only inside it, and only while
    /// nothing was written yet: an app update that adds the SDK to an old install must not lower a
    /// value the app's previous writer set.
    static let baselineWindow: TimeInterval = 48 * 3_600
    /// Store dates come from Apple's clock, the timeline from the device's.
    static let clockTolerance: TimeInterval = 600

    /// The rung a trigger asks for, or nil.
    static func rung(for trigger: SkanTrigger, schema: SkanSchema, timeline: SkanTimeline,
                     now: Date, floor: Int?) -> SkanRung? {
        switch trigger {
        case .launch:
            guard floor == nil, now.timeIntervalSince(timeline.start) < baselineWindow else { return nil }
            return schema.rungs.first { $0.on.contains("launch") }
        case .event(let name):
            return schema.rungs.first { $0.event == name && $0.on.contains("event") }
        case .purchase(let facts):
            guard let event = purchaseRungEvent(facts, sweep: false, timeline: timeline) else { return nil }
            return schema.rungs.first { $0.event == event && $0.on.contains("purchase") }
        case .sweep(let facts):
            guard let event = purchaseRungEvent(facts, sweep: true, timeline: timeline) else { return nil }
            return schema.rungs.first { $0.event == event && $0.on.contains("sweep") }
        }
    }

    /// `trial_start` for a free-trial offer, `subscribe` for a paid transaction, nil when the
    /// transaction is not this install's conversion:
    /// - sweep: only an entitlement whose subscription began after this install started (the
    ///   reinstall fix: a returning subscriber's old entitlement must not write `subscribe`);
    /// - purchase: only a transaction made after this install started, and for a paid one, either a
    ///   subscription that began after it (a trial converting) or a fresh purchase rather than the
    ///   renewal of an older subscription.
    static func purchaseRungEvent(_ facts: PurchaseFacts, sweep: Bool, timeline: SkanTimeline) -> String? {
        if facts.revoked { return nil }
        let start = timeline.start.addingTimeInterval(-clockTolerance)
        if sweep {
            guard facts.originalPurchaseDate > start else { return nil }
            return facts.isFreeTrial ? "trial_start" : "subscribe"
        }
        guard facts.purchaseDate >= start else { return nil }
        if facts.isFreeTrial { return "trial_start" }
        if facts.originalPurchaseDate >= start || facts.isRenewal == false { return "subscribe" }
        return nil
    }

    /// Monotonic: never write a fine value at or below the floor.
    static func shouldWrite(fine: Int, floor: Int?) -> Bool {
        guard let floor else { return true }
        return fine > floor
    }

    /// The SKAN 4 window the SDK believes it is in: 0 (0–48 h), 1 (to day 7), 2 (to day 35), nil after.
    static func window(since start: Date, now: Date) -> Int? {
        let hours = now.timeIntervalSince(start) / 3_600
        if hours < 48 { return 0 }
        if hours < 168 { return 1 }
        if hours < 840 { return 2 }
        return nil
    }

    /// `$skan` props.
    static func auditProps(rung: SkanRung, coarse: SkanCoarse?, previous: Int?, schemaVersion: Int,
                           window: Int?, api: String, error: String?) -> [String: JSONValue] {
        [
            "fine": .int(Int64(rung.fine)),
            "coarse": .string(coarse?.rawValue),
            "rung": .string(rung.event),
            "previous": .int(previous.map(Int64.init)),
            "schema_version": .int(Int64(schemaVersion)),
            "window": .int(window.map(Int64.init)),
            "api": .string(api),
            "error": .string(error),
        ]
    }
}

/// The outcome of one SKAdNetwork or AdAttributionKit write.
enum SkanWriteResult: Equatable, Sendable {
    /// The API does not exist on this OS (SKAN below 15.4, AdAttributionKit below 17.4): nothing was
    /// written, nothing is audited.
    case unsupported
    /// Apple's completion ran. `api` is `skan4` | `skan3` | `aak`; `error` is nil on success.
    case completed(api: String, error: String?)
}

/// The system calls behind the writer.
protocol SkanWriting: Sendable {
    /// The SKAdNetwork API this OS writes through: `skan4` (16.1+), `skan3` (15.4–16.0), nil below.
    var skanApiName: String? { get }
    func updateSkan(fine: Int, coarse: SkanCoarse, lockWindow: Bool,
                    completion: @escaping @Sendable (SkanWriteResult) -> Void)
    func updateAak(fine: Int, lockPostback: Bool, completion: @escaping @Sendable (SkanWriteResult) -> Void)
}

/// Serialises conversion-value writes and owns the floor. Every method runs on `queue`; Apple's
/// completions hop back onto it. Reading and raising the floor from two concurrent writes would let
/// the lower value win, hence one write at a time.
final class SkanCoordinator: @unchecked Sendable {
    struct Job: Sendable {
        let trigger: SkanTrigger
        let schema: SkanSchema
        let timeline: SkanTimeline
    }

    /// One write in progress: what its `$skan` events carry.
    private struct Write: Sendable {
        let rung: SkanRung
        let schema: SkanSchema
        let previous: Int?
        let window: Int?
    }

    private enum Phase: Sendable {
        case skan, aak
    }

    static let writeTimeout: TimeInterval = 10

    private let timeout: TimeInterval
    private let writer: SkanWriting
    private let queue: DispatchQueue
    private let now: @Sendable () -> Date
    private(set) var floor: Int?
    private var jobs: [Job] = []
    private var busy = false
    /// Bumped at every phase start; a completion or timeout for an older phase is ignored.
    private var phaseToken = 0
    private var idleWaiters: [() -> Void] = []

    /// A `$skan` event to enqueue.
    var onAudit: ([String: JSONValue]) -> Void = { _ in }
    /// The floor rose (persist it).
    var onFloorChange: (Int) -> Void = { _ in }

    init(writer: SkanWriting, queue: DispatchQueue, floor: Int?, timeout: TimeInterval = SkanCoordinator.writeTimeout,
         now: @escaping @Sendable () -> Date) {
        self.timeout = timeout
        self.writer = writer
        self.queue = queue
        self.floor = floor
        self.now = now
    }

    var isIdle: Bool { !busy && jobs.isEmpty }

    func reset(floor: Int?) {
        self.floor = floor
    }

    func submit(_ job: Job) {
        jobs.append(job)
        pump()
    }

    /// Runs `block` once no write is pending or in flight.
    func whenIdle(_ block: @escaping () -> Void) {
        if isIdle { block() } else { idleWaiters.append(block) }
    }

    private func pump() {
        while !busy, !jobs.isEmpty {
            let job = jobs.removeFirst()
            let at = now()
            guard let rung = SkanPlanner.rung(for: job.trigger, schema: job.schema, timeline: job.timeline,
                                              now: at, floor: floor),
                  SkanPlanner.shouldWrite(fine: rung.fine, floor: floor)
            else { continue }
            busy = true
            let write = Write(rung: rung, schema: job.schema, previous: floor,
                              window: SkanPlanner.window(since: job.timeline.start, now: at))
            startSkan(write)
        }
        if isIdle, !idleWaiters.isEmpty {
            let waiters = idleWaiters
            idleWaiters = []
            waiters.forEach { $0() }
        }
    }

    private func beginPhase(_ phase: Phase, _ write: Write) -> Int {
        phaseToken += 1
        let token = phaseToken
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            timedOut(token: token, phase: phase, write)
        }
        return token
    }

    private func startSkan(_ write: Write) {
        let token = beginPhase(.skan, write)
        writer.updateSkan(fine: write.rung.fine, coarse: write.rung.coarse, lockWindow: write.schema.lockWindow) {
            [self] result in
            queue.async { self.skanCompleted(result, token: token, write) }
        }
    }

    private func skanCompleted(_ result: SkanWriteResult, token: Int, _ write: Write) {
        guard phaseToken == token, busy else { return }
        audit(result, write)
        // The floor rises only when Apple reported no error.
        if case .completed(_, nil) = result {
            let raised = max(floor ?? write.rung.fine, write.rung.fine)
            floor = raised
            onFloorChange(raised)
        }
        startMirror(write)
    }

    private func startMirror(_ write: Write) {
        guard write.schema.aakMirror else { return finish() }
        let token = beginPhase(.aak, write)
        writer.updateAak(fine: write.rung.fine, lockPostback: write.schema.lockWindow) { [self] result in
            queue.async { self.aakCompleted(result, token: token, write) }
        }
    }

    private func aakCompleted(_ result: SkanWriteResult, token: Int, _ write: Write) {
        guard phaseToken == token, busy else { return }
        audit(result, write)
        finish()
    }

    private func timedOut(token: Int, phase: Phase, _ write: Write) {
        guard phaseToken == token, busy else { return }
        switch phase {
        case .skan:
            phaseToken += 1
            audit(.completed(api: writer.skanApiName ?? "skan4", error: "timeout"), write)
            startMirror(write)
        case .aak:
            phaseToken += 1
            audit(.completed(api: "aak", error: "timeout"), write)
            finish()
        }
    }

    private func finish() {
        busy = false
        pump()
    }

    private func audit(_ result: SkanWriteResult, _ write: Write) {
        guard case .completed(let api, let error) = result else { return }
        onAudit(SkanPlanner.auditProps(
            rung: write.rung, coarse: api == "skan4" ? write.rung.coarse : nil, previous: write.previous,
            schemaVersion: write.schema.version, window: write.window, api: api, error: error))
    }
}
