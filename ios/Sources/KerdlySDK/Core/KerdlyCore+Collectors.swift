import Foundation

// Background collectors, the SKAN glue and app lifecycle. Everything here
// runs on `queue`.
extension KerdlyCore {
    static let maxAsaAttempts = 3
    /// Failed token requests per round (a launch or a foreground) before the round gives up.
    static let maxAsaFailures = 3
    static let asaRetryDelay: TimeInterval = 15
    /// How long after the first launch the SDK keeps asking for the token.
    static let asaWindow: TimeInterval = 48 * 3_600
    static let notifyLookupTimeout: TimeInterval = 5

    // MARK: - Launch pipeline

    /// The config for this app version first: when none is cached (a fresh install, or the first
    /// launch after an update) everything waits for its fetch, the launch batch included, and the
    /// fetch is retried until it arrives (`afterConfigFetch`). Then the public IPv6, the SKAN
    /// baseline, the AdServices token and the other collectors; nothing at all when Kerdly is off for
    /// this version.
    func runLaunchPipeline() {
        guard !launchPipelineStarted else { return }
        launchPipelineStarted = true
        guard configReady else { return fetchConfig() }
        if configCache?.isStale(now: now) == true { fetchConfig() }
        if config.off { return switchOff() }
        launchConfigReady()
    }

    func launchConfigReady() {
        guard !launchConfigResolved, configReady, !config.off else { return }
        launchConfigResolved = true
        // Before the SKAN baseline, and after the replayed calls, so a `setConsent` made before
        // `configure` applies.
        collectPublicIp()
        skanReady = true
        // The baseline goes first: writes it BEFORE the AdServices token.
        skanTrigger(.launch)
        let buffered = pendingSkanTriggers
        pendingSkanTriggers = []
        buffered.forEach { skanTrigger($0) }
        skan.whenIdle { [self] in startLaunchCollectors() }
        scheduler.schedule(after: SkanCoordinator.writeTimeout * 2 + 1) { [self] in startLaunchCollectors() }
    }

    func startLaunchCollectors() {
        guard !launchCollectorsStarted else { return }
        launchCollectorsStarted = true
        retryAsaToken(launch: true)
        collectAppTransaction()
        collectAdvertisingId()
        askDeferredLinks()
        startPurchaseObservation()
        scheduleAttributionPolls()
    }

    // MARK: - AdServices token

    /// A round of token tries while a token is still wanted: each launch, and each foreground once
    /// the last round gave up. A launch is a fresh process, so its round starts from zero.
    func retryAsaToken(launch: Bool) {
        guard state.asaDue else { return }
        if launch || state.asaFailures >= Self.maxAsaFailures {
            state.asaFailures = 0
        }
        requestAsaToken()
    }

    /// From the `$install` launch until a token is sent, within `asaWindow` of the first launch,
    /// and when a response's `needs` asks; at most 3 token signals per install.
    /// `AAAttribution.attributionToken()` blocks, so it runs on the work queue.
    func requestAsaToken() {
        guard launchCollectorsStarted, state.asaDue, !asaInFlight else { return }
        guard config.collectAsaToken else { return }
        guard state.asaAttempts < Self.maxAsaAttempts, !asaWindowClosed else {
            state.asaDue = false
            saveState()
            return
        }
        asaInFlight = true
        let provider = deps.adServices
        deps.workQueue.async { [self] in
            let result: Result<String, KerdlyAdapterError>
            do {
                result = .success(try provider.attributionToken())
            } catch {
                result = .failure(KerdlyAdapterError(String(describing: error)))
            }
            queue.async { self.asaTokenFinished(result) }
        }
    }

    func asaTokenFinished(_ result: Result<String, KerdlyAdapterError>) {
        asaInFlight = false
        switch result {
        case .success(let token) where !token.isEmpty:
            let attempt = state.asaAttempts + 1
            guard enqueue(ReservedEvent.signal, [
                "kind": .string("asa_token"),
                "token": .string(token),
                "attempt": .int(Int64(attempt)),
            ]) != nil else { return }
            state.asaAttempts = attempt
            state.asaDue = false
            saveState()
            log.info("AdServices token \(Redact.short(token)) sent (attempt \(attempt))")
        case .success, .failure:
            state.asaFailures += 1
            if case .failure(let error) = result {
                log.info("AdServices token unavailable: \(error)")
            }
            if state.asaFailures >= Self.maxAsaFailures {
                log.info("AdServices token: \(state.asaFailures) failures; trying again at the next launch or foreground")
            } else {
                scheduler.schedule(after: Self.asaRetryDelay) { [self] in requestAsaToken() }
            }
            saveState()
        }
    }

    /// The install's attribution is settled (`asaWindow` after its first launch).
    var asaWindowClosed: Bool {
        guard let first = state.firstLaunchAt else { return false }
        return Clocks.ms(now) - first > Int64(Self.asaWindow * 1_000)
    }

    // MARK: - AppTransaction

    /// iOS 16+: `AppTransaction.shared`, retried on later launches until one succeeds.
    func collectAppTransaction() {
        guard !state.appTransactionSent, !appTransactionInFlight, config.collectAppTransaction else { return }
        appTransactionInFlight = true
        deps.storeKit.appTransaction { [self] result in
            queue.async { self.appTransactionFinished(result) }
        }
    }

    func appTransactionFinished(_ result: Result<AppTransactionInfo, KerdlyAdapterError>) {
        appTransactionInFlight = false
        switch result {
        case .success(let info):
            guard enqueue(ReservedEvent.signal, [
                "kind": .string("app_transaction"),
                "jws": .string(info.jws),
                "app_transaction_id": .string(info.appTransactionId),
                "original_purchase_date": .int(Clocks.ms(info.originalPurchaseDate)),
                "original_app_version": .string(info.originalAppVersion),
                "environment": .string(info.environment),
                "device_verification_nonce": .string(info.deviceVerificationNonce),
                "device_verification": .string(info.deviceVerification),
            ]) != nil else { return }
            state.appTransactionSent = true
            saveState()
            log.info("AppTransaction sent (\(info.environment))")
        case .failure(let error):
            log.info("AppTransaction unavailable (retried next launch): \(error)")
        }
    }

    // MARK: - IDFA

    /// Only with ATT = authorized, `ads` consent, `collectAdvertisingId` and the config's
    /// `collect.advertising_id`; signalled when it changes.
    func collectAdvertisingId() {
        guard advertisingIdAllowed, !advertisingIdInFlight, launchCollectorsStarted else { return }
        advertisingIdInFlight = true
        let provider = deps.advertisingId
        deps.workQueue.async { [self] in
            let idfa = provider.advertisingId()
            queue.async { self.advertisingIdFinished(idfa) }
        }
    }

    var advertisingIdAllowed: Bool {
        (options?.collectAdvertisingId ?? false) && config.collectAdvertisingId && state.consentAds
            && deps.tracking.status() == .authorized
    }

    func advertisingIdFinished(_ idfa: String?) {
        advertisingIdInFlight = false
        guard advertisingIdAllowed, let idfa, !idfa.isEmpty,
              idfa.contains(where: { $0 != "0" && $0 != "-" })
        else { return }
        let hash = Hashing.sha256(idfa.uppercased())
        guard hash != state.idfaHash else { return }
        guard enqueue(ReservedEvent.signal, ["kind": .string("advertising_ids"), "idfa": .string(idfa)]) != nil
        else { return }
        state.idfaHash = hash
        saveState()
        log.info("IDFA \(Redact.short(idfa)) sent")
    }

    // MARK: - Public IPv6

    /// Once per install, on the launch that enqueued `$install`, started at once
    /// rather than behind the SKAN baseline and the launch collectors. A failure is never retried.
    func collectPublicIp() {
        guard launchEnqueuedInstall, publicIpAllowed else { return }
        let provider = deps.publicIp
        let url = config.ipv6EchoUrl
        deps.workQueue.async { [self] in
            provider.lookup(url) { [self] answer in
                queue.async { self.publicIpFinished(answer) }
            }
        }
    }

    var publicIpAllowed: Bool {
        config.collectPublicIp && state.consentAds
    }

    func publicIpFinished(_ answer: String?) {
        guard publicIpAllowed else { return }
        guard let answer else {
            log.info("public IPv6 unavailable (not retried)")
            return
        }
        guard let ipv6 = PublicIPv6.globalUnicast(answer) else {
            log.info("public IPv6: the echo's answer is not a global IPv6 address; dropped")
            return
        }
        guard enqueue(ReservedEvent.signal, ["kind": .string("public_ip"), "ipv6": .string(ipv6)]) != nil
        else { return }
        log.info("public IPv6 \(Redact.short(ipv6)) sent")
    }

    // MARK: - Purchases

    /// `$purchase_link` (config `collect.purchases`) and the SKAN purchase triggers both need the
    /// StoreKit observation.
    var purchaseObservationWanted: Bool {
        config.collectPurchases || skanEnabled
    }

    func startPurchaseObservation() {
        guard purchaseObservationWanted else { return }
        if !updatesObserved {
            updatesObserved = true
            deps.storeKit.observeUpdates { [self] info in
                queue.async { self.handlePurchase(info, notified: nil, source: .updates) }
            }
        }
        sweepEntitlements()
    }

    /// `Transaction.currentEntitlements`, on launch, every foreground and `notifyPurchase()`.
    func sweepEntitlements() {
        guard launchCollectorsStarted, purchaseObservationWanted, !sweepInFlight else { return }
        sweepInFlight = true
        deps.storeKit.currentEntitlements { [self] infos in
            queue.async {
                self.sweepInFlight = false
                for info in infos {
                    self.handlePurchase(info, notified: nil, source: .entitlements)
                }
            }
        }
    }

    func notifyPurchase(_ purchase: KerdlyPurchase?) {
        guard purchaseObservationWanted else { return }
        guard let purchase, NotifiedPurchase(purchase).hasIds else {
            if launchCollectorsStarted { sweepEntitlements() }
            return
        }
        let notified = NotifiedPurchase(purchase)
        notifyLookupCounter += 1
        let token = notifyLookupCounter
        notifyLookups[token] = notified
        deps.storeKit.findTransaction(transactionId: notified.transactionId,
                                      originalTransactionId: notified.originalTransactionId,
                                      productId: notified.productId) { [self] info in
            queue.async { self.notifyLookupFinished(token, info: info) }
        }
        scheduler.schedule(after: Self.notifyLookupTimeout) { [self] in
            notifyLookupFinished(token, info: nil)
        }
    }

    func notifyLookupFinished(_ token: Int, info: PurchaseInfo?) {
        guard let notified = notifyLookups.removeValue(forKey: token) else { return }
        handlePurchase(info, notified: notified, source: .notify)
    }

    /// One `$purchase_link` per original transaction id; then the SKAN purchase / sweep trigger.
    func handlePurchase(_ info: PurchaseInfo?, notified: NotifiedPurchase?, source: PurchaseSource) {
        if config.collectPurchases {
            let keys = PurchaseLinks.dedupeKeys(info: info, notified: notified)
            if !keys.isEmpty {
                if PurchaseLinks.isReported(keys, in: state.reportedPurchaseIds) {
                    if keys.contains(where: { !state.reportedPurchaseIds.contains($0) }) {
                        state.markReported(keys)
                        saveState()
                    }
                } else if enqueue(ReservedEvent.purchaseLink,
                                  PurchaseLinks.props(info: info, notified: notified, source: source)) != nil {
                    state.markReported(keys)
                    saveState()
                }
            }
        }
        if let info {
            skanTrigger(source == .entitlements ? .sweep(info.facts) : .purchase(info.facts))
        }
    }

    // MARK: - SKAN

    /// Hands a trigger to the writer when SKAN writing is on. Triggers that arrive
    /// before the launch's config is resolved wait for it.
    func skanTrigger(_ trigger: SkanTrigger) {
        guard options?.skanWriter == true else { return }
        guard skanReady else {
            if pendingSkanTriggers.count < 50 { pendingSkanTriggers.append(trigger) }
            return
        }
        guard skanEnabled, let schema = config.skan, let first = state.firstLaunchAt else { return }
        let timeline = SkanTimeline(firstLaunchAt: Clocks.date(ms: first),
                                    installedAt: state.installedAt.map { Clocks.date(ms: $0) })
        skan.submit(.init(trigger: trigger, schema: schema, timeline: timeline))
    }

    // MARK: - ATT

    /// Emits `$consent` when the ATT status differs from the last one seen (the first observation
    /// is recorded silently).
    func checkAttStatus(persist: Bool = true) {
        let status = deps.tracking.status().rawValue
        guard let last = state.lastAttStatus else {
            state.lastAttStatus = status
            if persist { saveState() }
            return
        }
        guard status != last else { return }
        state.lastAttStatus = status
        if persist { saveState() }
        enqueueConsent()
        if status == KerdlyAttStatus.authorized.rawValue {
            collectAdvertisingId()
        }
        askDeferredLinks()
    }

    // MARK: - Lifecycle

    func observeLifecycleOnce() {
        guard !lifecycleObserved else { return }
        lifecycleObserved = true
        let device = deps.device
        let lifecycle = deps.lifecycle
        lifecycle.observe { [self] event in
            let wantsSnapshot = Thread.isMainThread && (event == .didBecomeActive || event == .willEnterForeground)
            let fresh: DeviceSnapshot? = wantsSnapshot ? MainActor.assumeIsolated { device.snapshot() } : nil
            let backgroundTask = event == .didEnterBackground ? lifecycle.beginBackgroundTask() : nil
            queue.async { self.handleLifecycle(event, snapshot: fresh, backgroundTask: backgroundTask) }
        }
    }

    func handleLifecycle(_ event: LifecycleEvent, snapshot fresh: DeviceSnapshot?, backgroundTask: Int?) {
        if let fresh {
            snapshot = fresh
        }
        let at = now
        switch event {
        case .protectedDataAvailable:
            if waitingForProtectedData, options != nil {
                resolveInstall(at: at)
            }
        case .willEnterForeground:
            guard started else { return }
            isForeground = true
            facts = deps.device.facts()
            if let background = lastBackgroundAt, at.timeIntervalSince(background) >= Self.foregroundOpenThreshold {
                enqueue(ReservedEvent.open, ["reason": .string("foreground")], at: at)
            }
            lastBackgroundAt = nil
            retryConfigNowIfMissing()
            sweepEntitlements()
            retryAsaToken(launch: false)
            askDeferredLinks()
            startForegroundTimer()
            scheduleFlush()
        case .didBecomeActive:
            guard started else { return }
            isForeground = true
            if snapshot != nil { releaseLaunchFlush() }
            checkAttStatus()
            startForegroundTimer()
        case .didEnterBackground:
            if let previous = backgroundTaskToken {
                deps.lifecycle.endBackgroundTask(previous)
            }
            backgroundTaskToken = backgroundTask
            guard started else { return endBackgroundTaskIfIdle() }
            isForeground = false
            lastBackgroundAt = at
            deepLinkSources.didEnterBackground()
            stopForegroundTimer()
            flushNow(explicit: false)
            endBackgroundTaskIfIdle()
        }
    }

    /// The app's ATT request settled (through `Kerdly.requestTrackingAuthorization`).
    func trackingDecided() {
        guard started else { return }
        checkAttStatus()
        scheduleFlush()
    }
}
