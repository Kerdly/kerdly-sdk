import Foundation

// Deferred deep links: the SDK asks Meta and TikTok, from the device, for the deep
// link of the ad that led to this install, and reports each answer as `$signal deferred_link`.
// Everything here runs on `queue`.
extension KerdlyCore {
    static let maxDdlFailures = 3

    /// One network to ask, with what its request needs.
    struct DdlTarget: Sendable {
        let network: String
        let request: HTTPRequest
    }

    /// Asks each configured network once per install: on the launch collectors, when the ATT status
    /// changes, and on a foreground (a retry after a failure in transit). Only while the config's
    /// `ddl` block is on, the install is fresh or a reinstall, it is younger than `max_age_h` and the
    /// `ads` consent is on; and with tracking authorized (the request gives the network the IDFA) or,
    /// under `require_att: false`, denied or restricted (no IDFA; Meta through `ep2`). Never while
    /// the ATT prompt is still to come, so a user who then allows tracking is asked with the IDFA.
    func askDeferredLinks() {
        guard launchCollectorsStarted, !ddlInFlight, let ddl = config.ddl, ddl.enabled, state.ddlEligible else { return }
        guard let first = state.firstLaunchAt, now.timeIntervalSince(Clocks.date(ms: first)) <= ddl.maxAge else { return }
        let att = deps.tracking.status()
        guard state.consentAds, Self.ddlMayAsk(att: att, requireAtt: ddl.requireAtt) else { return }
        let bundle = deps.device.deferredLinkBundle()
        let metaDue = ddl.meta != nil && state.ddl[MetaDdl.network]?.done != true
        let tiktokDue = ddl.tiktok != nil && state.ddl[TikTokDdl.network]?.done != true
        guard metaDue || tiktokDue else { return }
        if metaDue, let meta = ddl.meta, (meta.appId ?? bundle.metaAppId) == nil || (meta.clientToken ?? bundle.metaClientToken) == nil {
            finishDeferredLink(.skipped(MetaDdl.network, .notConfigured, "no Facebook app id or client token"), attempt: 1)
            if !tiktokDue { return }
        }
        ddlInFlight = true
        guard att == .authorized else { return sendDeferredLinks(idfa: nil, att: att, ddl: ddl, bundle: bundle) }
        let provider = deps.advertisingId
        deps.workQueue.async { [self] in
            let idfa = provider.advertisingId()
            queue.async { self.sendDeferredLinks(idfa: idfa, att: att, ddl: ddl, bundle: bundle) }
        }
    }

    /// Tracking authorized, or, when the config does not require it, denied or restricted.
    static func ddlMayAsk(att: KerdlyAttStatus, requireAtt: Bool) -> Bool {
        att == .authorized || (!requireAtt && (att == .denied || att == .restricted))
    }

    /// `idfa`: read when tracking is authorized, nil otherwise.
    private func sendDeferredLinks(idfa: String?, att: KerdlyAttStatus, ddl: DdlConfig, bundle: DeferredLinkBundle) {
        // Tracking is authorized but iOS gave no IDFA: try again on a later foreground.
        if att == .authorized, idfa?.isEmpty != false {
            ddlInFlight = false
            return
        }
        let current = snapshot ?? DeviceSnapshot(idfv: nil, screenWidth: 0, screenHeight: 0, screenScale: 0, isForeground: true)
        let targets = ddlTargets(idfa: idfa ?? "", att: att, snapshot: current, bundle: bundle,
                                 meta: state.ddl[MetaDdl.network]?.done == true ? nil : ddl.meta,
                                 tiktok: state.ddl[TikTokDdl.network]?.done == true ? nil : ddl.tiktok)
        guard !targets.isEmpty else {
            ddlInFlight = false
            return
        }
        send(targets) { [self] answers in
            ddlInFlight = false
            answers.forEach { recordDeferredLink($0) }
        }
    }

    /// A transit failure counts towards giving up; any answer, a refusal included, is final.
    private func recordDeferredLink(_ answer: DdlAnswer) {
        var progress = state.ddl[answer.network] ?? DdlNetworkState()
        guard answer.isTransient else { return finishDeferredLink(answer, attempt: progress.failures + 1) }
        progress.failures += 1
        state.ddl[answer.network] = progress
        if progress.failures >= Self.maxDdlFailures {
            finishDeferredLink(answer, attempt: progress.failures)
        } else {
            saveState()
            log.info("deferred link: \(answer.network) did not answer (\(answer.detail ?? "")); retried on a later foreground")
        }
    }

    /// `attempt`: which try this answer came from (1-based).
    private func finishDeferredLink(_ answer: DdlAnswer, attempt: Int) {
        var progress = state.ddl[answer.network] ?? DdlNetworkState()
        progress.done = true
        state.ddl[answer.network] = progress
        saveState()
        enqueue(ReservedEvent.signal, deferredLinkProps(answer, attempt: attempt))
        log.info("deferred link: \(answer.network) \(answer.status.rawValue)")
    }

    func deferredLinkProps(_ answer: DdlAnswer, attempt: Int) -> [String: JSONValue] {
        let parsed = answer.url.flatMap(URL.init(string:)).flatMap(DeepLinkParser.parse)
        return [
            "kind": .string("deferred_link"),
            "network": .string(answer.network),
            "status": .string(answer.status.rawValue),
            "url": .string(answer.url.map { String($0.prefix(DeepLinkParser.maxUrlLength)) }),
            "click_ts": .int(answer.clickTimeMs),
            "cpp": .string(parsed?.cpp),
            "ppid": .string(parsed?.ppid),
            "afr_c": .string(parsed?.afrC),
            "afr_v": .string(parsed?.afrV),
            "campaign_ids": .string(parsed?.campaignIds),
            "http_status": .int(answer.httpStatus.map(Int64.init)),
            "detail": .string(answer.detail.map { String($0.prefix(300)) }),
            "attempt": .int(Int64(attempt)),
            "att": .string(deps.tracking.status().rawValue),
        ]
    }

    /// The requests for the networks given, built from the device and the bundle, each shaped for the
    /// ATT status: the IDFA goes only with tracking authorized, and Meta without it goes to `ep2`.
    func ddlTargets(idfa: String, att: KerdlyAttStatus, snapshot: DeviceSnapshot, bundle: DeferredLinkBundle,
                    meta: DdlConfig.Meta?, tiktok: DdlConfig.TikTok?) -> [DdlTarget] {
        let tracking = att == .authorized && !idfa.isEmpty
        let facts = ddlFacts(idfa: tracking ? idfa : "", snapshot: snapshot, bundle: bundle)
        var targets: [DdlTarget] = []
        if let meta, let appId = meta.appId ?? bundle.metaAppId, let token = meta.clientToken ?? bundle.metaClientToken {
            let installId = state.installId.isEmpty ? deps.newId() : state.installId
            let anonId = state.partnerIds["meta_anon_id"] ?? "XZ\(installId.uppercased())"
            if let request = MetaDdl.request(appId: appId, clientToken: token, anonId: anonId, facts: facts,
                                             trackingAuthorized: tracking) {
                targets.append(DdlTarget(network: MetaDdl.network, request: request))
            }
        }
        if let tiktok, let request = TikTokDdl.request(tiktokAppId: tiktok.appId, storeAppId: tiktok.storeAppId,
                                                       facts: facts, att: att, now: now) {
            targets.append(DdlTarget(network: TikTokDdl.network, request: request))
        }
        return targets
    }

    /// Sends every target at once; `completion` runs on `queue` with the answers in target order.
    func send(_ targets: [DdlTarget], completion: @escaping @Sendable ([DdlAnswer]) -> Void) {
        let answers = Locked<[String: DdlAnswer]>([:])
        let group = DispatchGroup()
        for target in targets {
            group.enter()
            log.debug("deferred link: asking \(target.network) at \(target.request.url.host ?? "")")
            let network = target.network
            deps.transport.send(target.request) { result in
                let answer = network == MetaDdl.network ? MetaDdl.parse(result) : TikTokDdl.parse(result)
                answers.update { $0[network] = answer }
                group.leave()
            }
        }
        group.notify(queue: queue) {
            let all = answers.get()
            completion(targets.compactMap { all[$0.network] })
        }
    }

    // MARK: - Debug

    /// Debug: asks Meta and TikTok for this device's deferred deep link and hands back their raw
    /// answers. Enqueues nothing and ignores the config's `ddl` block. Asks only with the `ads`
    /// consent on, and with tracking authorized unless `ignoreAtt`: then it asks whatever the ATT
    /// status, without the IDFA (Meta through `ep2`) unless tracking is authorized and iOS gives it.
    ///
    /// Not behind `run`: it works before, or without, `configure`, so a build with no Kerdly key can
    /// still test the networks.
    func apiDebugFetchDeferredLinks(tiktokAppId: String?, storeAppId: String?, ignoreAtt: Bool = false,
                                    completion: @escaping @Sendable ([DdlAnswer]) -> Void) {
        let device = deps.device
        DispatchQueue.main.async { [self] in
            let fresh = MainActor.assumeIsolated { device.snapshot() }
            queue.async { [self] in
                let networks = [MetaDdl.network, TikTokDdl.network]
                let att = deps.tracking.status()
                guard att == .authorized || ignoreAtt else {
                    completion(networks.map { DdlAnswer.skipped($0, .skippedAtt) })
                    return
                }
                guard state.consentAds else {
                    completion(networks.map { DdlAnswer.skipped($0, .skippedConsent) })
                    return
                }
                let ask = { @Sendable (idfa: String) in
                    let bundle = self.deps.device.deferredLinkBundle()
                    let targets = self.ddlTargets(idfa: idfa, att: att, snapshot: fresh, bundle: bundle,
                                                  meta: DdlConfig.Meta(appId: nil, clientToken: nil),
                                                  tiktok: tiktokAppId.map { DdlConfig.TikTok(appId: $0, storeAppId: storeAppId) })
                    let asked = Set(targets.map(\.network))
                    self.send(targets) { answers in
                        completion(answers + networks.filter { !asked.contains($0) }.map { DdlAnswer.skipped($0, .notConfigured) })
                    }
                }
                guard att == .authorized else { return ask("") }
                let provider = deps.advertisingId
                deps.workQueue.async { [self] in
                    let idfa = provider.advertisingId()
                    queue.async {
                        if let idfa, !idfa.isEmpty { return ask(idfa) }
                        if ignoreAtt { return ask("") }
                        completion(networks.map { DdlAnswer.skipped($0, .skippedAtt, "no IDFA") })
                    }
                }
            }
        }
    }

    private func ddlFacts(idfa: String, snapshot: DeviceSnapshot, bundle: DeferredLinkBundle) -> DdlDeviceFacts {
        let facts = deps.device.facts()
        let app = deps.device.appInfo()
        let scale = snapshot.screenScale
        let points = { (pixels: Int) -> Int in scale > 0 ? Int((Double(pixels) / scale).rounded()) : 0 }
        return DdlDeviceFacts(
            bundleId: app.bundle, appName: bundle.appName, appVersion: app.version, appBuild: app.build,
            os: facts.os, model: facts.model, localeIdentifier: facts.locale,
            preferredLanguage: facts.languages.first ?? "", regionCode: bundle.regionCode,
            timeZoneName: facts.timeZone, timeZoneAbbrev: TimeZone.current.abbreviation() ?? "",
            screenWidth: points(snapshot.screenWidth), screenHeight: points(snapshot.screenHeight),
            screenScale: scale, coreCount: ProcessInfo.processInfo.activeProcessorCount,
            idfa: idfa.uppercased(), idfv: snapshot.idfv, urlSchemes: bundle.urlSchemes)
    }
}
