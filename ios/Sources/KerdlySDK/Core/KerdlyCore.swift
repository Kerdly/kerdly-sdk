import Foundation

/// The SDK's engine. All mutable state is confined to `queue`, a private serial queue: the public
/// `Kerdly` facade validates on the caller's thread and hops onto it, and every completion from the
/// system hops back onto it. The few values public getters read from any thread live in `Locked`
/// boxes. Nothing here throws into the app.
final class KerdlyCore: @unchecked Sendable {
    static let sdkName = "kerdly-ios"
    static let sdkVersion = "0.1.0"
    static let defaultsInstallIdKey = "com.kerdly.sdk.install_id"
    static let defaultsKeychainFailedKey = "com.kerdly.sdk.keychain_write_failed"
    /// The same two keys as builds before 0.1.0 named them; `migrateLegacyDefaults` moves them once.
    static let legacyDefaultsInstallIdKey = "com.afr.sdk.install_id"
    static let legacyDefaultsKeychainFailedKey = "com.afr.sdk.keychain_write_failed"
    static let foregroundOpenThreshold: TimeInterval = 30 * 60
    static let maxPreStartCalls = 200
    static let maxEventBytes = 64 * 1_024
    static let maxIdLength = 256

    static let shared = KerdlyCore(dependencies: .system())

    let queue: DispatchQueue
    let deps: KerdlyDependencies
    let log = KerdlyLogger()
    let scheduler: Scheduling
    let store: StateStore
    let skan: SkanCoordinator

    // MARK: Readable from any thread

    let installIdBox = Locked<String?>(nil)
    let attributionBox = Locked<[String: JSONValue]?>(nil)
    let attributionHandlers = Locked<[UncheckedSendable<(KerdlyAttribution) -> Void>]>([])
    let configureCalled = Locked(false)

    // MARK: Confined to `queue`

    var options: KerdlyOptions?
    /// The install id is resolved and the persisted state loaded.
    var started = false
    /// The Keychain was locked at `configure`; start waits for protected data.
    var waitingForProtectedData = false
    /// Calls made before the SDK started, replayed in order once it has.
    var preStartCalls: [@Sendable () -> Void] = []
    /// `afterStart` replayed `preStartCalls`; later calls run directly.
    var callsOpen = false
    var state = PersistedState(installId: "")
    var eventQueue = EventQueue()
    var configCache: ConfigCache?
    var config = RemoteConfig.defaults
    var appInfo = AppInfo(bundle: "unknown", version: "", build: "")
    var facts: DeviceFacts?
    var snapshot: DeviceSnapshot?
    var environment = KerdlyEnvironment.production.rawValue
    var isForeground = true
    var lastBackgroundAt: Date?
    var configuredAt = Date()
    var deepLinkSources = DeepLinkSourceTracker(configuredAt: Date())
    var lifecycleObserved = false
    /// This launch enqueued a `$install`.
    var launchEnqueuedInstall = false

    // Delivery
    var launchFlushReleased = false
    var inFlight = false
    var flushScheduled = false
    var flushAfterInFlight = false
    /// 401/403: nothing is sent until the next launch.
    var stoppedUntilRelaunch = false
    /// After a 413: the halved batch size, growing back after successes.
    var batchLimitOverride: Int?
    var retryTimer: Cancellable?
    var foregroundTimer: Cancellable?
    var backgroundTaskToken: Int?
    var loggedDropCodes: Set<String> = []

    // Config and attribution
    var configFetchInFlight = false
    var configFetchWaiters: [() -> Void] = []
    /// While no config for this app version is in: the next fetch, backing off.
    var configRetryTimer: Cancellable?
    var configRetryAttempt = 0
    /// `afterStart` read the app's version: `configReady` can be decided.
    var appInfoLoaded = false
    var attributionPolls = 0

    // Collectors
    var launchPipelineStarted = false
    var launchConfigResolved = false
    var launchCollectorsStarted = false
    var asaInFlight = false
    var appTransactionInFlight = false
    var advertisingIdInFlight = false
    var ddlInFlight = false
    var updatesObserved = false
    var sweepInFlight = false
    var skanReady = false
    var pendingSkanTriggers: [SkanTrigger] = []
    var notifyLookups: [Int: NotifiedPurchase] = [:]
    var notifyLookupCounter = 0

    init(dependencies: KerdlyDependencies,
         queue: DispatchQueue = DispatchQueue(label: "com.kerdly.sdk", qos: .utility)) {
        self.deps = dependencies
        self.queue = queue
        self.scheduler = dependencies.makeScheduler(queue)
        self.store = StateStore(files: dependencies.files)
        let clock = dependencies.clock
        self.skan = SkanCoordinator(writer: dependencies.skanWriter, queue: queue, floor: nil,
                                    now: { clock.now() })
        skan.onAudit = { [unowned self] props in
            enqueue(ReservedEvent.skan, props)
        }
        skan.onFloorChange = { [unowned self] floor in
            state.skanFloor = floor
            saveState()
        }
    }

    var now: Date { deps.clock.now() }

    /// Sending is on: the kill switch is off and this SDK version is still supported.
    var sendingEnabled: Bool {
        config.enabled && !config.isBelowMinimum(sdkVersion: Self.sdkVersion)
    }

    /// The config in use was fetched for this app version. Until it is, the config
    /// request is the only request the SDK makes and no collector runs: Kerdly may have switched this
    /// version off.
    var configReady: Bool {
        appInfoLoaded && configCache?.isFor(appVersion: appInfo.version) == true
    }

    /// Kerdly is off for this app version: nothing is recorded, collected or sent.
    var kerdlyOff: Bool {
        configReady && config.off
    }

    var skanEnabled: Bool {
        (options?.skanWriter ?? false) && (config.skan?.enabled ?? false)
    }

    // MARK: - configure

    /// Synchronous and cheap: resolves the install id, loads the state and queue, enqueues
    /// `$install` (when due) and `$open`; everything else continues on `queue`.
    func configure(_ options: KerdlyOptions) {
        let already = configureCalled.update { called -> Bool in
            defer { called = true }
            return called
        }
        if already {
            log.warn("configure was called more than once; ignoring the later call")
            return
        }
        log.currentLevel = options.logLevel
        guard Self.validate(options, log: log) else {
            configureCalled.set(false)
            return
        }
        var snapshot: DeviceSnapshot?
        if Thread.isMainThread {
            let device = deps.device
            snapshot = MainActor.assumeIsolated { device.snapshot() }
        }
        queue.sync {
            start(options: options, snapshot: snapshot)
        }
        if snapshot == nil {
            let device = deps.device
            DispatchQueue.main.async { [self] in
                let fresh = MainActor.assumeIsolated { device.snapshot() }
                queue.async { self.receive(snapshot: fresh) }
            }
        }
    }

    static func validate(_ options: KerdlyOptions, log: KerdlyLogger) -> Bool {
        let key = options.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            log.error("configure: the key is empty; the SDK stays off")
            return false
        }
        guard let scheme = options.endpoint.scheme?.lowercased(), scheme == "https" || scheme == "http",
              options.endpoint.host != nil else {
            log.error("configure: the endpoint must be an http(s) URL; the SDK stays off")
            return false
        }
        if key.hasPrefix("sk_") {
            log.error("configure: that is a server key (sk_…); apps take their public pk_ key. The SDK stays off")
            return false
        }
        if !key.hasPrefix("pk_") {
            log.warn("configure: the key does not look like a public SDK key (pk_…)")
        }
        return true
    }

    func start(options: KerdlyOptions, snapshot: DeviceSnapshot?) {
        self.options = options
        let at = now
        configuredAt = at
        deepLinkSources = DeepLinkSourceTracker(configuredAt: at)
        if let snapshot {
            self.snapshot = snapshot
            isForeground = snapshot.isForeground
        }
        observeLifecycleOnce()
        resolveInstall(at: at)
    }

    /// An app updating from a build before 0.1.0 keeps its install id: the UserDefaults copy (and
    /// the Keychain failure flag) move to the current keys once; the current keys win.
    func migrateLegacyDefaults() {
        let defaults = deps.defaults
        if let legacyId = defaults.string(forKey: Self.legacyDefaultsInstallIdKey) {
            if defaults.string(forKey: Self.defaultsInstallIdKey) == nil {
                defaults.set(legacyId, forKey: Self.defaultsInstallIdKey)
            }
            defaults.set(nil as String?, forKey: Self.legacyDefaultsInstallIdKey)
        }
        if defaults.bool(forKey: Self.legacyDefaultsKeychainFailedKey) {
            defaults.set(true, forKey: Self.defaultsKeychainFailedKey)
            defaults.set(nil as String?, forKey: Self.legacyDefaultsKeychainFailedKey)
        }
    }

    /// Install identity and state, then the launch's reserved events.
    func resolveInstall(at: Date) {
        migrateLegacyDefaults()
        let decision = InstallIdentityResolver.decide(
            keychain: deps.keychain.readInstallId(),
            defaults: deps.defaults.string(forKey: Self.defaultsInstallIdKey),
            keychainWriteFailedBefore: deps.defaults.bool(forKey: Self.defaultsKeychainFailedKey),
            newId: deps.newId)
        guard let decision else {
            waitingForProtectedData = true
            log.info("the Keychain is locked (no unlock since boot); starting once protected data is available")
            return
        }
        waitingForProtectedData = false
        let id = decision.installId
        if decision.writeKeychain {
            let written = deps.keychain.writeInstallId(id)
            if written == deps.defaults.bool(forKey: Self.defaultsKeychainFailedKey) {
                deps.defaults.set(!written, forKey: Self.defaultsKeychainFailedKey)
            }
            if !written { log.warn("could not write the install id to the Keychain") }
        }
        if decision.writeDefaults {
            deps.defaults.set(id, forKey: Self.defaultsInstallIdKey)
        }

        let loaded = store.loadState()
        if let loaded, loaded.installId == id {
            state = loaded
        } else {
            state = (loaded ?? PersistedState(installId: id)).reset(for: id)
        }
        if let file = store.loadQueue(), file.installId == id {
            eventQueue = EventQueue(events: file.events)
        } else {
            eventQueue = EventQueue()
        }
        configCache = store.loadConfig()
        config = configCache?.config ?? .defaults
        installIdBox.set(id)
        attributionBox.set(state.attribution?.objectValue)
        started = true
        applyLogLevel()

        let atMs = Clocks.ms(at)
        if let installState = decision.state {
            let installedAt = deps.device.installedAt().map(Clocks.ms)
            state.firstLaunchAt = atMs
            state.installedAt = installedAt
            state.asaDue = state.asaAttempts < 3
            state.asaFailures = 0
            state.ddlEligible = installState != .restore
            state.ddl = [:]
            launchEnqueuedInstall = true
            // `device` is a snapshot taken now, so the app and device facts `afterStart` loads are
            // read here already (both are cheap).
            appInfo = deps.device.appInfo()
            facts = deps.device.facts()
            enqueue(ReservedEvent.install, [
                "install_state": .string(installState.rawValue),
                "restored_from": .string(decision.restoredFrom),
                "installed_at": .int(installedAt),
                "installed_at_source": .string("documents_dir"),
                "first_launch_at": .int(atMs),
                "installer": .null,
                "initial_url": .null,
                "device": currentDevice(),
            ], at: at, persist: false)
            log.info("$install (\(installState.rawValue)) for install \(id)")
        } else if state.firstLaunchAt == nil {
            // The state file was lost: date the install from what is known.
            state.firstLaunchAt = atMs
            state.installedAt = deps.device.installedAt().map(Clocks.ms)
        }
        skan.reset(floor: state.skanFloor)
        enqueue(ReservedEvent.open, ["reason": .string("launch")], at: at, persist: false)
        replayPendingDeepLinks()
        checkAttStatus(persist: false)
        saveQueue()
        saveState()
        queue.async { self.afterStart() }
    }

    /// Re-enqueues attribution-bearing deep links the server has not accepted yet (same event id).
    func replayPendingDeepLinks() {
        for event in state.pendingDeepLinks where !eventQueue.contains(id: event.id) {
            eventQueue.append(event)
            log.debug("re-enqueued pending $deeplink \(event.id)")
        }
    }

    /// The rest of the launch, off the caller's thread.
    func afterStart() {
        guard let options else { return }
        appInfo = deps.device.appInfo()
        appInfoLoaded = true
        facts = deps.device.facts()
        environment = EnvironmentResolver.resolve(option: options.environment, inputs: deps.device.environmentInputs())
        log.debug("environment \(environment), bundle \(appInfo.bundle) \(appInfo.version) (\(appInfo.build))")
        let calls = preStartCalls
        preStartCalls = []
        calls.forEach { $0() }
        callsOpen = true
        if isForeground { startForegroundTimer() }
        if snapshot != nil {
            releaseLaunchFlush()
        } else {
            scheduler.schedule(after: 1.5) { [self] in releaseLaunchFlush() }
        }
        runLaunchPipeline()
    }

    func receive(snapshot: DeviceSnapshot) {
        self.snapshot = snapshot
        isForeground = snapshot.isForeground
        if started { releaseLaunchFlush() }
    }

    /// The launch flush waits for the UIKit snapshot (idfv, screen) so the first batch carries a
    /// complete context; a blocked main thread holds it back at most 1.5 s. It is sent before any
    /// other request of the launch.
    func releaseLaunchFlush() {
        guard !launchFlushReleased else { return }
        launchFlushReleased = true
        flushNow(explicit: false)
    }

    /// Runs `call` on the queue once the SDK has started; earlier calls are kept (bounded) and
    /// replayed in order.
    func run(_ call: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if callsOpen {
                call()
            } else if preStartCalls.count < Self.maxPreStartCalls {
                preStartCalls.append(call)
            } else {
                log.warn("dropped a call made before configure (too many pending)")
            }
        }
    }

    // MARK: - Enqueue

    /// Gates, numbers, stores and (for reserved events) flushes an event. Returns nil when it was
    /// dropped. Queue-confined.
    @discardableResult
    func enqueue(_ name: String, _ props: [String: JSONValue], at date: Date? = nil,
                 persist: Bool = true) -> QueuedEvent? {
        guard started else { return nil }
        if kerdlyOff {
            log.debug("\(name) dropped: Kerdly is off for this app version")
            return nil
        }
        let reserved = ReservedEvent.isReserved(name)
        if !state.consentAnalytics && !ReservedEvent.allowedWithoutAnalyticsConsent.contains(name) {
            log.debug("\(name) dropped: analytics consent is off")
            return nil
        }
        if !reserved {
            // Before this version's config is in, events are kept: that config decides.
            if configReady && !sendingEnabled {
                log.debug("\(name) dropped: the SDK is disabled by its remote config")
                return nil
            }
            if config.blockedEvents.contains(name) {
                log.debug("\(name) dropped: blocked by the remote config")
                return nil
            }
        }
        let event = QueuedEvent(id: deps.newId(), name: name, ts: Clocks.ms(date ?? now), seq: state.seq + 1,
                                userId: state.userId, props: props)
        guard event.size <= Self.maxEventBytes else {
            log.error("\(name) dropped: \(event.size) bytes is over the \(Self.maxEventBytes)-byte event limit")
            return nil
        }
        state.seq = event.seq
        for dropped in eventQueue.append(event) {
            log.warn("queue full: dropped the oldest custom event (\(dropped.name))")
        }
        if persist {
            saveQueue()
            saveState()
        }
        log.debug("enqueued \(name) #\(event.seq)")
        if name != ReservedEvent.skan {
            skanTrigger(.event(name))
        }
        if reserved || eventQueue.count >= config.queueFlushAt {
            scheduleFlush()
        }
        return event
    }

    func saveQueue() {
        guard started else { return }
        if !store.save(queue: eventQueue.events, installId: state.installId) {
            log.warn("could not write the event queue")
        }
    }

    func saveState() {
        guard started else { return }
        if !store.save(state) {
            log.warn("could not write the SDK state")
        }
    }

    func applyLogLevel() {
        guard let options else { return }
        let verbose = config.debugDevices.contains(state.installId)
        log.currentLevel = verbose ? .debug : options.logLevel
    }

    // MARK: - Public operations (called through `run`)

    func setUserId(_ userId: String?, at: Date) {
        guard userId != state.userId else { return }
        let previous = state.userId
        state.userId = userId
        saveState()
        enqueue(ReservedEvent.identify, [
            "user_id": .string(userId),
            "previous_user_id": .string(previous),
        ], at: at)
    }

    func setConsent(analytics: Bool?, ads: Bool?, at: Date) {
        var changed = false
        if let analytics, analytics != state.consentAnalytics {
            state.consentAnalytics = analytics
            changed = true
        }
        if let ads, ads != state.consentAds {
            state.consentAds = ads
            changed = true
        }
        guard changed else { return }
        saveState()
        enqueueConsent(at: at)
        if state.consentAds { collectAdvertisingId() }
    }

    func enqueueConsent(at: Date? = nil) {
        enqueue(ReservedEvent.consent, [
            "att": .string(deps.tracking.status().rawValue),
            "analytics": .bool(state.consentAnalytics),
            "ads": .bool(state.consentAds),
        ], at: at)
    }

    func setAppAccountToken(_ token: String?, at: Date) {
        guard token != state.appAccountToken else { return }
        state.appAccountToken = token
        saveState()
        enqueueIds(at: at)
    }

    /// Merges into the stored map; an empty value removes its key.
    func setPartnerIds(_ ids: [String: String], at: Date) {
        var merged = state.partnerIds
        for (key, value) in ids {
            if value.isEmpty { merged.removeValue(forKey: key) } else { merged[key] = value }
        }
        guard merged != state.partnerIds else { return }
        state.partnerIds = merged
        saveState()
        enqueueIds(at: at)
    }

    func enqueueIds(at: Date) {
        enqueue(ReservedEvent.ids, [
            "app_account_token": .string(state.appAccountToken),
            "partner": .object(state.partnerIds.mapValues { .string($0) }),
        ], at: at)
    }

    func track(_ name: String, props: [String: JSONValue], at: Date) {
        enqueue(name, props, at: at)
    }

    func handleDeepLink(_ link: ParsedDeepLink, source explicit: String?, at: Date) {
        var props = link.props
        props["source"] = .string(deepLinkSources.source(at: at, explicit: explicit))
        guard let event = enqueue(ReservedEvent.deeplink, props, at: at) else { return }
        if link.isAttributionBearing {
            state.pendingDeepLinks.append(event)
            if state.pendingDeepLinks.count > PersistedState.maxPendingDeepLinks {
                state.pendingDeepLinks.removeFirst(state.pendingDeepLinks.count - PersistedState.maxPendingDeepLinks)
            }
            saveState()
        }
    }

    func recordNetworkSend(_ send: KerdlyNetworkSend, at: Date) {
        func clip(_ s: String?) -> JSONValue { .string(s.map { String($0.prefix(Self.maxIdLength)) }) }
        enqueue(ReservedEvent.networkSend, [
            "network": clip(send.network),
            "event": clip(send.event),
            "event_id": clip(send.eventId),
            "value": send.value.flatMap { $0.isFinite ? JSONValue.number($0) : nil } ?? .null,
            "currency": clip(send.currency),
            "flag": clip(send.flag),
        ], at: at)
    }

    // MARK: - Attribution

    func updateAttribution(_ attribution: [String: JSONValue]) {
        guard state.attribution?.objectValue != attribution else { return }
        state.attribution = .object(attribution)
        saveState()
        attributionBox.set(attribution)
        log.info("attribution: \(attribution["network"]?.stringValue ?? "?") (\(attribution["state"]?.stringValue ?? "?"))")
        let handlers = attributionHandlers.get()
        guard !handlers.isEmpty else { return }
        DispatchQueue.main.async {
            let value = KerdlyAttribution(json: attribution)
            handlers.forEach { $0.value(value) }
        }
    }

    func addAttributionHandler(_ handler: UncheckedSendable<(KerdlyAttribution) -> Void>) {
        attributionHandlers.update { $0.append(handler) }
        if let current = attributionBox.get() {
            DispatchQueue.main.async {
                handler.value(KerdlyAttribution(json: current))
            }
        }
    }
}
