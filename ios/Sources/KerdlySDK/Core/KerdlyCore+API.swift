import Foundation

// The public API's work, on any thread: validate here, then hop onto `queue` through `run`.
// `Kerdly` forwards to these on `KerdlyCore.shared`; tests call them on a core built with fakes.
extension KerdlyCore {
    func apiSetUserId(_ userId: String?) {
        let value = userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (value?.isEmpty ?? true) ? nil : value.map { String($0.prefix(Self.maxIdLength)) }
        let at = now
        run { [self] in setUserId(normalized, at: at) }
    }

    func apiTrack(_ name: String, properties: [String: Any]) {
        if ReservedEvent.isReserved(name) {
            log.debug("track: '\(name)' is a reserved name; dropped")
            return
        }
        guard EventValidator.isValidName(name) else {
            log.debug("track: '\(name)' is not a valid event name; dropped")
            return
        }
        // A standard event's typed props are checked here too.
        let sanitized = StandardEvent.sanitize(name, properties)
        for issue in sanitized.issues {
            log.debug("track(\(name)): \(issue)")
        }
        let props = sanitized.props
        let at = now
        run { [self] in track(name, props: props, at: at) }
    }

    func apiTrackRegistration(method: String?, properties: [String: Any]) {
        apiTrackStandard(StandardEvent.registration, StandardEvent.arguments(method: method), properties)
    }

    func apiTrackStartTrial(productId: String?, value: Double?, currency: String?, transactionId: String?,
                            properties: [String: Any]) {
        apiTrackStandard(StandardEvent.startTrial, StandardEvent.arguments(
            productId: productId, value: value, currency: currency, transactionId: transactionId), properties)
    }

    func apiTrackSubscribe(productId: String?, value: Double?, currency: String?, transactionId: String?,
                           properties: [String: Any]) {
        apiTrackStandard(StandardEvent.subscribe, StandardEvent.arguments(
            productId: productId, value: value, currency: currency, transactionId: transactionId), properties)
    }

    func apiTrackPurchase(productId: String?, value: Double?, currency: String?, quantity: Int?,
                          transactionId: String?, properties: [String: Any]) {
        apiTrackStandard(StandardEvent.purchase, StandardEvent.arguments(
            productId: productId, value: value, currency: currency, quantity: quantity,
            transactionId: transactionId), properties)
    }

    /// A typed method: its arguments win over `properties`; then the same checks as `track`.
    private func apiTrackStandard(_ name: String, _ arguments: [String: Any], _ properties: [String: Any]) {
        let merged = StandardEvent.merge(arguments, properties)
        for key in merged.ignored {
            log.debug("track(\(name)): prop '\(key)' ignored: an argument sets it")
        }
        let sanitized = StandardEvent.sanitize(name, merged.props)
        for issue in sanitized.issues {
            log.debug("track(\(name)): \(issue)")
        }
        let props = sanitized.props
        let at = now
        run { [self] in track(name, props: props, at: at) }
    }

    func apiSetConsent(analytics: Bool?, ads: Bool?) {
        let at = now
        run { [self] in setConsent(analytics: analytics, ads: ads, at: at) }
    }

    func apiHandleUrl(_ url: URL, source: String? = nil) -> KerdlyDeepLink? {
        guard let parsed = DeepLinkParser.parse(url) else { return nil }
        let at = now
        run { [self] in handleDeepLink(parsed, source: source, at: at) }
        return KerdlyDeepLink(url: url, cpp: parsed.cpp, ppid: parsed.ppid, clickId: parsed.clickId,
                           visitId: parsed.visitId, campaignIds: parsed.campaignIds)
    }

    func apiSetAppAccountToken(_ token: UUID?) {
        let value = token?.uuidString.lowercased()
        let at = now
        run { [self] in setAppAccountToken(value, at: at) }
    }

    func apiSetPartnerIds(_ ids: [String: String]) {
        var cleaned: [String: String] = [:]
        for (key, value) in ids.sorted(by: { $0.key < $1.key }).prefix(50) {
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { continue }
            cleaned[String(k.prefix(64))] = String(value.prefix(1_024))
        }
        let clean = cleaned
        let at = now
        run { [self] in setPartnerIds(clean, at: at) }
    }

    func apiNotifyPurchase(_ purchase: KerdlyPurchase?) {
        run { [self] in notifyPurchase(purchase) }
    }

    func apiRecordNetworkSend(_ send: KerdlyNetworkSend) {
        let at = now
        run { [self] in recordNetworkSend(send, at: at) }
    }

    var apiAttribution: KerdlyAttribution? {
        attributionBox.get().map { KerdlyAttribution(json: $0) }
    }

    func apiFlush() {
        run { [self] in flushNow(explicit: true) }
    }
}
