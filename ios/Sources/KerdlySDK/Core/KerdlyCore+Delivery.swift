import Foundation

// Batches, retries, the remote config and the attribution poll. Everything here runs on `queue`.
extension KerdlyCore {
    static let attributionPollOffsets: [TimeInterval] = [10, 30, 55]
    /// Waits between config fetches while no config for this app version is in.
    static let configRetryDelays: [TimeInterval] = [5, 15, 30, 60, 120, 300]

    func endpointURL(_ path: String) -> URL? {
        options?.endpoint.appendingPathComponent(path)
    }

    /// The headers every request carries. The app's version picks the config Kerdly
    /// serves (its version rules).
    func baseHeaders() -> [String: String] {
        var sdk = "\(Self.sdkName)/\(Self.sdkVersion)"
        if let wrapper = options?.wrapper?.trimmingCharacters(in: .whitespaces), !wrapper.isEmpty {
            sdk += " \(wrapper)"
        }
        var headers = [
            "Authorization": "Bearer \(options?.key.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")",
            "X-Afr-Bundle": appInfo.bundle,
            "X-Afr-Sdk": sdk,
            "Content-Type": "application/json",
            "Accept": "application/json",
        ]
        if !appInfo.version.isEmpty { headers["X-Afr-App-Version"] = appInfo.version }
        if !appInfo.build.isEmpty { headers["X-Afr-App-Build"] = appInfo.build }
        return headers
    }

    func makeEnvelope() -> BatchEnvelope {
        let wrapper = options?.wrapper?.trimmingCharacters(in: .whitespaces)
        return BatchEnvelope(
            sdkName: Self.sdkName, sdkVersion: Self.sdkVersion,
            wrapper: (wrapper?.isEmpty ?? true) ? nil : wrapper,
            bundle: appInfo.bundle, appVersion: appInfo.version, appBuild: appInfo.build,
            environment: environment, installId: state.installId)
    }

    func currentContext() -> JSONValue {
        ContextBuilder.context(facts: facts ?? deps.device.facts(), snapshot: snapshot,
                               att: deps.tracking.status(), analytics: state.consentAnalytics,
                               ads: state.consentAds, app: appInfo)
    }

    /// `$install`'s `device`: the same inputs as `currentContext`, without consent.
    func currentDevice() -> JSONValue {
        ContextBuilder.device(facts: facts ?? deps.device.facts(), snapshot: snapshot,
                              att: deps.tracking.status(), app: appInfo)
    }

    // MARK: - Flush

    /// Coalesces flush triggers that arrive together into one attempt.
    func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.async { [self] in
            flushScheduled = false
            flushNow(explicit: false)
        }
    }

    /// Sends the next batch, if one is due. One request in flight at a time.
    /// - Parameter explicit: `flush()` from the app: skips the client back-off (not a server
    ///   `Retry-After`).
    func flushNow(explicit: Bool) {
        guard started, launchFlushReleased, options != nil else { return }
        guard !stoppedUntilRelaunch, configReady, sendingEnabled, !config.off else { return endBackgroundTaskIfIdle() }
        guard !eventQueue.isEmpty else { return endBackgroundTaskIfIdle() }
        if inFlight {
            flushAfterInFlight = true
            return
        }
        let at = now
        if let retryAt = state.retryAt {
            let wait = Clocks.date(ms: retryAt).timeIntervalSince(at)
            if wait > 3_600 {
                // A clock that jumped back would otherwise park the queue: forget the deadline.
                state.retryAt = nil
            } else if wait > 0 && (!explicit || state.retryAtFromServer) {
                armRetryTimer()
                return endBackgroundTaskIfIdle()
            }
        }
        guard let url = endpointURL("v1/sdk/batch") else { return }
        let envelope = makeEnvelope()
        let context = currentContext()
        let contextHash = Hashing.sha256(KerdlyJSON.encode(context) ?? Data())
        let sendContext: JSONValue? = contextHash == state.lastAckedContextHash ? nil : context
        let limit = min(config.maxBatch, batchLimitOverride ?? BatchBuilder.maxEvents)
        let batch = eventQueue.nextBatch(
            maxEvents: limit, maxBytes: BatchBuilder.maxBodyBytes,
            overheadBytes: BatchBuilder.overheadBytes(envelope: envelope, context: sendContext))
        guard !batch.isEmpty,
              let body = BatchBuilder.body(envelope: envelope, sentAt: Clocks.ms(at), context: sendContext, events: batch)
        else { return }
        inFlight = true
        let ids = batch.map(\.id)
        let ackContextHash = sendContext == nil ? nil : contextHash
        log.debug("sending \(ids.count) event(s), \(body.count) bytes\(sendContext == nil ? "" : " with context")")
        deps.transport.send(HTTPRequest(method: "POST", url: url, headers: baseHeaders(), body: body)) { [self] result in
            queue.async { self.handleBatchResult(result, ids: ids, contextHash: ackContextHash) }
        }
    }

    func handleBatchResult(_ result: HTTPResult, ids: [String], contextHash: String?) {
        inFlight = false
        let at = now
        let outcome: DeliveryOutcome
        switch result {
        case .failure(let reason):
            log.debug("batch not delivered: \(reason)")
            outcome = .retry(retryAfter: nil)
        case .response(let status, let headers, let body):
            outcome = DeliveryPolicy.classify(status: status, headers: headers, body: body, now: at)
        }
        apply(outcome, ids: ids, contextHash: contextHash, at: at)
        if flushAfterInFlight {
            flushAfterInFlight = false
            if state.retryAt == nil && !stoppedUntilRelaunch { scheduleFlush() }
        }
        endBackgroundTaskIfIdle()
    }

    func apply(_ outcome: DeliveryOutcome, ids: [String], contextHash: String?, at: Date) {
        let sent = Set(ids)
        switch outcome {
        case .success(let response):
            let settled = response.settledIds
            eventQueue.remove(ids: settled)
            state.pendingDeepLinks.removeAll { settled.contains($0.id) }
            for rejected in response.rejected where sent.contains(rejected.id) {
                log.warn("event \(rejected.id) rejected: \(rejected.reason)")
            }
            if let contextHash { state.lastAckedContextHash = contextHash }
            if settled.isDisjoint(with: sent) {
                // Nothing of this batch was settled: back off rather than resend it at once.
                scheduleRetry(retryAfter: nil, at: at)
            } else {
                clearBackoff()
                if let limit = batchLimitOverride {
                    batchLimitOverride = limit * 2 >= BatchBuilder.maxEvents ? nil : limit * 2
                }
            }
            saveQueue()
            saveState()
            process(response)
            if !eventQueue.isEmpty && state.retryAt == nil { scheduleFlush() }
        case .drop(let code, let stop):
            eventQueue.remove(ids: sent)
            saveQueue()
            if loggedDropCodes.insert(code).inserted {
                log.error("batch of \(ids.count) event(s) dropped: \(code)")
            }
            clearBackoff()
            saveState()
            if stop {
                stoppedUntilRelaunch = true
                log.error("sending stopped until the next launch (\(code))")
            } else if !eventQueue.isEmpty {
                scheduleFlush()
            }
        case .retry(let retryAfter):
            scheduleRetry(retryAfter: retryAfter, at: at)
        case .split:
            // The server answered: the halved batch goes at once.
            clearBackoff()
            saveState()
            if ids.count <= 1 {
                eventQueue.remove(ids: sent)
                saveQueue()
                log.error("an event was dropped: too large even alone (413)")
            } else {
                batchLimitOverride = max(1, ids.count / 2)
                log.debug("413: retrying with batches of \(ids.count / 2)")
            }
            scheduleFlush()
        }
    }

    /// What a 200 carries besides the acks.
    func process(_ response: BatchResponse) {
        if let attribution = response.attribution {
            updateAttribution(attribution)
        }
        if let etag = response.configEtag, etag != configCache?.etag {
            fetchConfig()
        }
        if response.needs.contains("asa_token") {
            state.asaDue = state.asaAttempts < 3
            saveState()
            requestAsaToken()
        }
        if !response.cvHints.isEmpty {
            log.debug("cv_hints received; server hints are not used by this SDK version")
        }
    }

    func scheduleRetry(retryAfter: TimeInterval?, at: Date) {
        let delay: TimeInterval
        if let retryAfter {
            delay = retryAfter
            state.retryAtFromServer = true
        } else {
            delay = BackoffPolicy().delay(attempt: state.backoffAttempt, unitRandom: deps.unitRandom())
            state.retryAtFromServer = false
        }
        state.backoffAttempt += 1
        state.retryAt = Clocks.ms(at.addingTimeInterval(delay))
        saveState()
        log.debug("next attempt in \(Int(delay.rounded())) s")
        armRetryTimer()
    }

    func clearBackoff() {
        state.backoffAttempt = 0
        state.retryAt = nil
        state.retryAtFromServer = false
        retryTimer?.cancel()
        retryTimer = nil
    }

    func armRetryTimer() {
        retryTimer?.cancel()
        guard let retryAt = state.retryAt else { return }
        let delay = max(0, Clocks.date(ms: retryAt).timeIntervalSince(now))
        retryTimer = scheduler.schedule(after: delay) { [self] in
            retryTimer = nil
            state.retryAt = nil
            flushNow(explicit: false)
        }
    }

    // MARK: - Foreground timer

    func startForegroundTimer() {
        guard foregroundTimer == nil else { return }
        foregroundTimer = scheduler.schedule(after: config.flushInterval) { [self] in
            foregroundTimer = nil
            guard started, isForeground else { return }
            if !eventQueue.isEmpty { flushNow(explicit: false) }
            startForegroundTimer()
        }
    }

    func stopForegroundTimer() {
        foregroundTimer?.cancel()
        foregroundTimer = nil
    }

    func endBackgroundTaskIfIdle() {
        guard let token = backgroundTaskToken, !inFlight, !flushScheduled else { return }
        backgroundTaskToken = nil
        deps.lifecycle.endBackgroundTask(token)
    }

    // MARK: - Remote config

    /// `GET /v1/sdk/config` with `If-None-Match`. Concurrent calls share one request; `completion`
    /// runs when it settles (whatever the outcome).
    func fetchConfig(then completion: (() -> Void)? = nil) {
        if let completion { configFetchWaiters.append(completion) }
        guard !configFetchInFlight else { return }
        guard !stoppedUntilRelaunch, let url = endpointURL("v1/sdk/config") else {
            return finishConfigFetch()
        }
        configFetchInFlight = true
        var headers = baseHeaders()
        if let etag = configCache?.etag { headers["If-None-Match"] = etag }
        deps.transport.send(HTTPRequest(method: "GET", url: url, headers: headers, body: nil)) { [self] result in
            queue.async { self.handleConfigResult(result) }
        }
    }

    func handleConfigResult(_ result: HTTPResult) {
        configFetchInFlight = false
        let atMs = Clocks.ms(now)
        switch result {
        case .response(let status, let headers, let body) where (200..<300).contains(status):
            if let json = JSONValue.parse(body), json.objectValue != nil {
                let etag = headers["etag"]
                let cache = configCache?.replacing(body: json, etag: etag, fetchedAt: atMs, appVersion: appInfo.version)
                    ?? ConfigCache.first(body: json, etag: etag, fetchedAt: atMs, appVersion: appInfo.version)
                if json["skan"].map({ !$0.isNull && SkanSchema.parse($0) == nil }) == true {
                    log.warn("the config's SKAN ladder is invalid; keeping the last valid one")
                }
                configCache = cache
                store.save(config: cache)
                apply(cache.config)
                log.debug("config \(cache.config.version.map(String.init) ?? "?") loaded")
            } else {
                log.warn("the config response is not a JSON object")
            }
        case .response(304, _, _):
            // Unchanged for the version the request named: the cached body is this version's too.
            if var cache = configCache {
                cache.fetchedAt = atMs
                cache.appVersion = appInfo.version
                configCache = cache
                store.save(config: cache)
            }
        case .response(let status, _, let body) where status == 401 || status == 403:
            stoppedUntilRelaunch = true
            log.error("config refused (\(DeliveryPolicy.errorCode(body) ?? "http_\(status)")); sending stopped until the next launch")
        case .response(let status, _, _):
            log.debug("config fetch failed: HTTP \(status)")
        case .failure(let reason):
            log.debug("config fetch failed: \(reason)")
        }
        finishConfigFetch()
    }

    func finishConfigFetch() {
        let waiters = configFetchWaiters
        configFetchWaiters = []
        waiters.forEach { $0() }
        afterConfigFetch()
    }

    /// After every config fetch, whatever its outcome. This version's config releases the launch
    /// (or, when Kerdly is off for it, empties the queue); without it, the SDK asks again, backing
    /// off, and on every foreground. There is no timeout: going ahead without the
    /// config is what would let a switched-off version send.
    func afterConfigFetch() {
        guard appInfoLoaded, launchPipelineStarted, !stoppedUntilRelaunch else { return }
        guard configReady else { return scheduleConfigRetry() }
        configRetryTimer?.cancel()
        configRetryTimer = nil
        configRetryAttempt = 0
        if config.off { return switchOff() }
        launchConfigReady()
        flushNow(explicit: false)
    }

    func scheduleConfigRetry() {
        guard configRetryTimer == nil, !configFetchInFlight else { return }
        let delay = Self.configRetryDelays[min(configRetryAttempt, Self.configRetryDelays.count - 1)]
        configRetryAttempt += 1
        configRetryTimer = scheduler.schedule(after: delay) { [self] in
            configRetryTimer = nil
            if !configReady { fetchConfig() }
        }
    }

    /// A foreground asks at once when this version's config is still missing.
    func retryConfigNowIfMissing() {
        guard appInfoLoaded, !configReady, !stoppedUntilRelaunch else { return }
        configRetryTimer?.cancel()
        configRetryTimer = nil
        fetchConfig()
    }

    /// Kerdly is off for this app version: what the device holds is dropped and nothing
    /// more is recorded (`enqueue`), collected (the collectors wait for `launchConfigReady`) or
    /// sent (`flushNow`). The config fetch goes on, so a later config can switch it back on.
    func switchOff() {
        let dropped = eventQueue.remove(ids: Set(eventQueue.events.map(\.id)))
        state.pendingDeepLinks = []
        pendingSkanTriggers = []
        saveQueue()
        saveState()
        endBackgroundTaskIfIdle()
        log.info("Kerdly is off for this app version: \(dropped) queued events dropped, nothing is recorded or sent")
    }

    func apply(_ newConfig: RemoteConfig) {
        let wasEnabled = sendingEnabled
        let oldInterval = config.flushInterval
        config = newConfig
        applyLogLevel()
        if wasEnabled && !sendingEnabled {
            log.warn("sending is disabled by the remote config")
        }
        if !wasEnabled && sendingEnabled {
            scheduleFlush()
        }
        if oldInterval != config.flushInterval && foregroundTimer != nil {
            stopForegroundTimer()
            startForegroundTimer()
        }
    }

    // MARK: - Attribution poll

    /// At most 3 polls in the first minute after an install; later, batch responses carry it.
    func scheduleAttributionPolls() {
        guard launchEnqueuedInstall else { return }
        for offset in Self.attributionPollOffsets {
            let delay = max(0, configuredAt.addingTimeInterval(offset).timeIntervalSince(now))
            scheduler.schedule(after: delay) { [self] in pollAttribution() }
        }
    }

    func pollAttribution() {
        guard state.attribution == nil, attributionPolls < Self.attributionPollOffsets.count,
              !stoppedUntilRelaunch, configReady, sendingEnabled,
              let base = endpointURL("v1/sdk/attribution"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return }
        components.queryItems = [URLQueryItem(name: "install_id", value: state.installId)]
        guard let url = components.url else { return }
        attributionPolls += 1
        deps.transport.send(HTTPRequest(method: "GET", url: url, headers: baseHeaders(), body: nil)) { [self] result in
            queue.async { self.handleAttributionPoll(result) }
        }
    }

    /// Accepts the attribution object itself or `{"attribution": {…} | null, …}`.
    func handleAttributionPoll(_ result: HTTPResult) {
        guard case .response(let status, _, let body) = result else { return }
        if status == 401 || status == 403 {
            stoppedUntilRelaunch = true
            return
        }
        guard (200..<300).contains(status), let object = JSONValue.parse(body)?.objectValue else { return }
        if let wrapped = object["attribution"] {
            if let attribution = wrapped.objectValue { updateAttribution(attribution) }
        } else if object["network"] != nil || object["state"] != nil {
            updateAttribution(object)
        }
    }
}
