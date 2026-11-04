package com.kerdly.sdk.internal

import com.kerdly.sdk.KerdlyAttribution
import com.kerdly.sdk.KerdlyDeepLink
import com.kerdly.sdk.KerdlyNetworkSend
import com.kerdly.sdk.KerdlyPurchase
import org.json.JSONObject
import java.net.URLEncoder
import kotlin.random.Random

internal class CoreConfig(
    val key: String,
    /** Base URL without a trailing slash. */
    val endpoint: String,
    /** `production` | `sandbox` | `development`, already resolved from AUTO. */
    val environment: String,
    val collectAdvertisingId: Boolean,
    val metaAppId: String?,
    val wrapper: String?,
)

internal class Launch(
    val installId: String,
    /** No install-id file existed: this launch enqueues `$install`. */
    val fresh: Boolean,
    val ts: Long,
    /** Whether the process was in the foreground when `configure` ran. */
    val foreground: Boolean,
)

/** The SDK engine: protocol v1 client rules over the ports in Ports.kt.
 *
 * Threading: every method runs on [scheduler]'s single thread, in submission order. Only
 * [attribution] is read from other threads. Blocking calls (HTTP, the advertising id, the Meta
 * providers) run on that thread too; events submitted meanwhile wait in the executor. */
internal class Core(
    private val cfg: CoreConfig,
    private val platform: Platform,
    private val transport: Transport,
    private val store: Store,
    private val scheduler: Scheduler,
    private val clock: Clock,
    private val log: Logger,
    private val main: MainDispatcher,
    private val random: Random = Random.Default,
    private val newEventId: () -> String = InstallId::newId,
) {
    companion object {
        const val FOREGROUND_OPEN_AFTER_MS = 30 * 60_000L
        const val CONFIG_MAX_AGE_MS = 6 * 3_600_000L
        /** A changed `config_etag` refetches at most this often (guards against a server loop). */
        const val CONFIG_MIN_INTERVAL_MS = 60_000L
        /** Waits between config fetches while no config for this app version is in. */
        val CONFIG_RETRY_MS = longArrayOf(5_000, 15_000, 30_000, 60_000, 120_000, 300_000)
        const val REFERRER_TIMEOUT_MS = 10_000L
        const val MAX_DDL_FAILURES = 3
        const val REFERRER_WINDOW_MS = 90L * 86_400_000L
        const val AD_ID_REFRESH_MS = 86_400_000L
        const val PUBLIC_IP_TIMEOUT_MS = 3_000L
        /** `GET /v1/sdk/attribution`: at most 3 polls in the first minute of a fresh install, only
         * while nothing is known; afterwards batch responses carry it. */
        val ATTRIBUTION_POLLS_MS = longArrayOf(5_000, 20_000, 50_000)
        /** One event can never fill a 256 KB batch; anything this big is a bug upstream. */
        const val MAX_EVENT_BYTES = 128 * 1024
        /** The collector's `user_id` limit. */
        const val MAX_USER_ID = 128
        /** The collector's `$ids` limits. */
        const val MAX_TOKEN = 64
        const val MAX_PARTNER_KEY = 64
        const val MAX_PARTNER_VALUE = 256
        const val MAX_PARTNER_IDS = 50
    }

    private var installId = ""
    private var state = SdkState()
    private var queue = EventQueue()
    private var configCache = ConfigCache.EMPTY
    private var config = RemoteConfig.DEFAULT
    private var pending = PendingLinks()
    private var purchases = ReportedPurchases()
    private var app = AppInfo("", null, null)
    private val listeners = ArrayList<(KerdlyAttribution) -> Unit>()

    /** Cached attribution; null until the collector decides one. */
    @Volatile
    var attribution: KerdlyAttribution? = null
        private set

    private var started = false
    /** 401/403: nothing more is sent until the next launch. */
    private var stopped = false
    private var sdkTooOld = false
    private var foreground = false
    private var backgroundedAt: Long? = null
    private var queueDirty = false
    private var persistScheduled = false
    private var flushScheduled = false
    private var timer: Cancellable? = null
    private var retryTask: Cancellable? = null
    /** After a 413: the batch size that last fit. */
    private var batchLimit: Int? = null
    private var referrerInFlight = false
    private var lastConfigAttemptAt: Long? = null
    private var etagHint: String? = null
    /** While no config for this app version is in: the next fetch, backing off. */
    private var configRetryTask: Cancellable? = null
    private var configRetryAttempt = 0
    /** This launch enqueued `$install`: the public IPv6 and the attribution polls are due. */
    private var launchFresh = false
    /** The launch's collectors ran (they wait for this version's config). */
    private var launchWorkDone = false
    /** TikTok's deferred link failed in transit: asked again at the next foreground, not before. */
    private var ddlWaitsForForeground = false
    private var loggedDrop = false

    // --- Launch ------------------------------------------------------------

    /** The launch task: the first thing on the executor after `configure`. Calls the app made
     * before `configure` ([buffered]) run after `$install` / `$open`, before anything is sent. */
    fun start(launch: Launch, buffered: List<(Core) -> Unit> = emptyList()) {
        installId = launch.installId
        foreground = launch.foreground
        if (!launch.foreground) backgroundedAt = launch.ts
        load(launch.fresh)
        app = safely("reading the app version", AppInfo("", null, null)) { platform.appInfo() }
        if (launch.fresh) {
            val info = safely("reading the install info", InstallInfo(null, null)) { platform.installInfo() }
            // The device snapshot is always sent: the context's fields at enqueue.
            val device = safely("reading the device context", null) { platform.deviceContext() } ?: DeviceContext.UNKNOWN
            state.firstLaunchAt = launch.ts
            state.installedAt = info.installedAt
            state.ddlEligible = true
            val install = enqueue(
                EventNames.INSTALL,
                ReservedProps.install(info.installedAt, launch.ts, info.installer, null, ContextJson.device(device, app.version, app.build)),
                launch.ts,
            )
            state.installEventId = install?.id
        } else if (state.firstLaunchAt == null) {
            state.firstLaunchAt = launch.ts
        }
        enqueue(EventNames.OPEN, ReservedProps.open("launch"), launch.ts)
        restorePendingLinks()
        started = true
        for (op in buffered) {
            try {
                op(this)
            } catch (t: Throwable) {
                log.error("a call made before configure failed", t)
            }
        }
        saveState()
        // Nothing but the config fetch goes out, and no collector runs, until the config for this
        // app version is in: Kerdly may have switched this version off. With it cached,
        // the launch flush goes out at once, so the `$install` request IP is the first-launch IP;
        // otherwise it follows the fetch.
        launchFresh = launch.fresh
        requestFlush()
        if (configReady) {
            if (config.off) switchOff() else startLaunchWork()
        }
        scheduler.execute { maybeFetchConfig(force = false) }
    }

    /** The config in use was fetched for this app version. */
    private val configReady: Boolean
        get() = configCache.config != null && configCache.appVersion == app.version

    /** Kerdly is off for this app version: nothing is recorded, collected or sent. */
    private val kerdlyOff: Boolean
        get() = configReady && config.off

    /** Collectors run only with this version's config in, and Kerdly on for it. */
    private fun collecting(): Boolean = configReady && !config.off

    /** The launch's collectors, once per launch: the public IPv6 lookup and the attribution
     * polls on the launch with `$install`, then the referrers, GAID and deferred links. */
    private fun startLaunchWork() {
        if (launchWorkDone || !collecting()) return
        launchWorkDone = true
        if (launchFresh) {
            scheduler.execute { collectPublicIp() }
            scheduleAttributionPolls()
        }
        startCollectors()
    }

    /** After every config fetch, whatever its outcome. This version's config releases the launch
     * (or, when Kerdly is off for it, empties the queue); without it, the SDK asks again, backing off,
     * and on every foreground. There is no timeout: going ahead without the config is what would
     * let a switched-off version send. */
    private fun afterConfigFetch() {
        if (stopped || !started) return
        if (!configReady) return scheduleConfigRetry()
        configRetryTask?.cancel()
        configRetryTask = null
        configRetryAttempt = 0
        if (config.off) return switchOff()
        // The launch flush first, so the `$install` batch leaves before the collectors' signals.
        requestFlush()
        startLaunchWork()
    }

    private fun scheduleConfigRetry() {
        if (configRetryTask != null) return
        val delay = CONFIG_RETRY_MS[minOf(configRetryAttempt, CONFIG_RETRY_MS.size - 1)]
        configRetryAttempt++
        configRetryTask = scheduler.schedule(delay) {
            configRetryTask = null
            if (!configReady) maybeFetchConfig(force = false)
        }
    }

    /** A foreground asks at once when this version's config is still missing. */
    private fun retryConfigNowIfMissing() {
        if (!started || stopped || configReady) return
        configRetryTask?.cancel()
        configRetryTask = null
        scheduler.execute { maybeFetchConfig(force = false) }
    }

    /** Kerdly is off for this app version: what the device holds is dropped, and nothing
     * more is recorded ([enqueue]), collected ([collecting]) or sent ([canSend]). The config fetch
     * goes on, so a later config can switch it back on. */
    private fun switchOff() {
        val dropped = queue.remove(queue.events().map { it.id })
        if (!pending.isEmpty()) {
            pending.remove(pending.entries().mapNotNull { it.id })
            savePending()
        }
        markQueueDirty()
        log.info("Kerdly is off for this app version: $dropped queued event(s) dropped, nothing is recorded or sent")
    }

    private fun load(fresh: Boolean) {
        configCache = ConfigCache.parse(readFile(StoreFiles.CONFIG))
        config = configCache.config ?: RemoteConfig.DEFAULT
        applyConfig()
        if (fresh) {
            // The new id reaches the disk before any event that carries it can be sent.
            if (!InstallId.persist(store, installId)) log.error("could not store the install id; it lasts only for this launch")
            // A new install id starts clean: anything left on disk belonged to an id that is gone.
            for (f in listOf(StoreFiles.QUEUE, StoreFiles.STATE, StoreFiles.PENDING_LINKS, StoreFiles.PURCHASES, StoreFiles.ATTRIBUTION)) {
                store.delete(f)
            }
            return
        }
        state = SdkState.parse(readFile(StoreFiles.STATE), installId) ?: SdkState()
        queue = EventQueue.parse(readFile(StoreFiles.QUEUE), installId) ?: EventQueue()
        pending = PendingLinks.parse(readFile(StoreFiles.PENDING_LINKS))
        purchases = ReportedPurchases.parse(readFile(StoreFiles.PURCHASES))
        attribution = AttributionParser.fromJson(parseObject(readFile(StoreFiles.ATTRIBUTION)))
        // `seq` is never reused, whichever file survived.
        queue.nextSeq = maxOf(queue.nextSeq, state.nextSeq, pending.maxSeq() + 1)
        // A persisted retry time beyond the longest back-off means the clock moved: retry now.
        if (state.retryNextAt - clock.now() > BatchResponses.MAX_RETRY_AFTER_S * 1000) {
            state.retryNextAt = 0
            state.retryAttempt = 0
        }
    }

    private fun readFile(name: String): String? = try {
        store.read(name)
    } catch (e: Exception) {
        log.warn("could not read $name", e)
        null
    }

    // --- Public operations (each already on the executor) ----------------------------------

    fun track(name: String, properties: Map<String, Any?>, ts: Long) {
        if (EventNames.isReserved(name)) {
            log.warn("track(\"${name.take(64)}\"): \$ names are reserved for the SDK; event dropped")
            return
        }
        if (!CustomEvents.isValidName(name)) {
            log.warn("track(\"${name.take(64)}\"): names must match [a-z][a-z0-9_]{0,39}; event dropped")
            return
        }
        if (!state.analytics) {
            log.debug { "analytics consent is off: $name dropped" }
            return
        }
        // Before this version's config is in, events are kept: that config decides.
        if (configReady && (!config.enabled || sdkTooOld)) {
            log.debug { "sending is paused: $name dropped" }
            return
        }
        if (name in config.blocked) {
            log.debug { "$name is blocked by the remote config" }
            return
        }
        // A standard name gets its typed checks here too, whoever called.
        val props = StandardEvents.sanitize(name, properties)
        if (props.dropped.isNotEmpty()) log.debug { "$name: dropped props ${props.dropped.joinToString()}" }
        enqueue(name, props.json, ts)
    }

    /** A typed standard-event method: its non-null [args] win over the same keys in [properties]. */
    fun trackStandard(name: String, args: Map<String, Any?>, properties: Map<String, Any?>, ts: Long) {
        val (props, ignored) = StandardEvents.merge(args, properties)
        if (ignored.isNotEmpty()) log.debug { "$name: dropped props ${ignored.joinToString { "$it (set by the typed argument)" }}" }
        track(name, props, ts)
    }

    fun setUserId(userId: String?, ts: Long) {
        val id = userId?.takeIf { it.isNotEmpty() }
        if (id != null && id.length > MAX_USER_ID) {
            log.error("setUserId: ids over $MAX_USER_ID characters are not supported; ignored")
            return
        }
        if (id == state.userId) return
        val previous = state.userId
        state.userId = id // before the enqueue: `$identify` carries the new id as its user_id
        enqueue(EventNames.IDENTIFY, ReservedProps.identify(id, previous), ts)
        saveState()
    }

    fun setConsent(analytics: Boolean?, ads: Boolean?, ts: Long) {
        val nextAnalytics = analytics ?: state.analytics
        val nextAds = ads ?: state.ads
        if (nextAnalytics == state.analytics && nextAds == state.ads) return
        val adsGranted = nextAds && !state.ads
        state.analytics = nextAnalytics
        state.ads = nextAds
        enqueue(EventNames.CONSENT, ReservedProps.consent(nextAnalytics, nextAds), ts)
        saveState()
        if (adsGranted && started) scheduler.execute { collectAdvertisingId(force = true) }
    }

    fun handleUrl(link: KerdlyDeepLink, source: String, ts: Long) {
        val event = enqueue(EventNames.DEEPLINK, ReservedProps.deeplink(link, source), ts) ?: return
        if (DeepLinks.isAttributionBearing(link)) {
            pending.add(event.json, clock.now())
            savePending()
        }
    }

    fun setAppAccountToken(token: String?, ts: Long) {
        // Any string: a UUID, or Superwall's `$SuperwallAlias:<uuid>` obfuscated account id.
        val t = token?.trim()?.takeIf { it.isNotEmpty() }
        if (t != null && t.length > MAX_TOKEN) {
            log.error("setAppAccountToken: tokens over $MAX_TOKEN characters are not supported; ignored")
            return
        }
        if (t == state.appAccountToken) return
        state.appAccountToken = t
        enqueue(EventNames.IDS, ReservedProps.ids(t, state.partner), ts)
        saveState()
    }

    /** Merges into the stored map; an empty value removes its key. `$ids` carries the whole map. */
    fun setPartnerIds(ids: Map<String, String>, ts: Long) {
        val merged = LinkedHashMap(state.partner)
        for ((k, v) in ids) {
            if (k.isEmpty() || k.length > MAX_PARTNER_KEY) {
                log.warn("setPartnerIds: key \"${k.take(64)}\" must be 1–$MAX_PARTNER_KEY characters; ignored")
                continue
            }
            when {
                v.isEmpty() -> merged.remove(k)
                v.length > MAX_PARTNER_VALUE -> log.warn("setPartnerIds: $k is over $MAX_PARTNER_VALUE characters; ignored")
                else -> merged[k] = v
            }
        }
        if (merged.size > MAX_PARTNER_IDS) {
            log.warn("setPartnerIds: at most $MAX_PARTNER_IDS ids are kept")
            val keep = merged.entries.take(MAX_PARTNER_IDS)
            merged.clear()
            for ((k, v) in keep) merged[k] = v
        }
        if (merged == state.partner) return
        state.partner = merged
        enqueue(EventNames.IDS, ReservedProps.ids(state.appAccountToken, merged), ts)
        saveState()
    }

    fun notifyPurchase(purchase: KerdlyPurchase, ts: Long) {
        if (purchase.purchaseToken.isBlank()) {
            log.warn("notifyPurchase: purchaseToken is empty; ignored")
            return
        }
        if (!config.collectPurchases) {
            log.debug { "purchases are off in the remote config" }
            return
        }
        val hash = ReportedPurchases.tokenHash(purchase.purchaseToken)
        if (purchases.contains(hash)) {
            log.debug { "purchase already reported" }
            return
        }
        enqueue(EventNames.PURCHASE_LINK, ReservedProps.purchaseLink(purchase), ts) ?: return
        purchases.add(hash)
        if (!store.write(StoreFiles.PURCHASES, purchases.serialize())) log.warn("could not write the reported purchases")
    }

    fun recordNetworkSend(send: KerdlyNetworkSend, ts: Long) {
        if (send.network.isBlank() || send.event.isBlank()) {
            log.warn("recordNetworkSend: network and event are required; ignored")
            return
        }
        enqueue(EventNames.NETWORK_SEND, ReservedProps.networkSend(send), ts)
    }

    fun flush() = requestFlush()

    fun addAttributionListener(listener: (KerdlyAttribution) -> Unit) {
        listeners.add(listener)
        attribution?.let { deliver(listener, it) }
    }

    // --- Lifecycle ---------------------------------------------------------------------------

    fun onForeground(ts: Long) {
        if (foreground) return
        foreground = true
        val since = backgroundedAt
        backgroundedAt = null
        if (since != null && ts - since >= FOREGROUND_OPEN_AFTER_MS) {
            enqueue(EventNames.OPEN, ReservedProps.open("foreground"), ts)
        }
        retryConfigNowIfMissing()
        ddlWaitsForForeground = false
        startPlayReferrer()
        scheduler.execute { collectAdvertisingId(force = false) }
        scheduler.execute { askDeferredLinks() }
        requestFlush()
    }

    fun onBackground(ts: Long) {
        if (!foreground) return
        foreground = false
        backgroundedAt = ts
        timer?.cancel()
        timer = null
        requestFlush()
    }

    // --- Queue -------------------------------------------------------------------------------

    /** Stamps id, seq and user_id; null when consent or a limit kept the event out. */
    private fun enqueue(name: String, props: JSONObject, ts: Long): QueuedEvent? {
        if (kerdlyOff) {
            log.debug { "Kerdly is off for this app version: $name not recorded" }
            return null
        }
        if (!state.analytics && name !in EventNames.ANALYTICS_OFF_ALLOWED) {
            log.debug { "analytics consent is off: $name not recorded" }
            return null
        }
        val id = newEventId()
        val seq = queue.nextSeq
        val o = JSONObject().put("id", id).put("name", name).put("ts", ts).put("seq", seq)
        state.userId?.let { o.put("user_id", it) }
        o.put("props", props)
        val event = QueuedEvent(id, name, seq, o.toString())
        if (event.bytes > MAX_EVENT_BYTES) {
            log.error("$name dropped: ${event.bytes} bytes is over the $MAX_EVENT_BYTES-byte event limit")
            return null
        }
        queue.nextSeq = seq + 1
        val dropped = queue.add(event)
        if (dropped.isNotEmpty()) log.warn("queue full: dropped ${dropped.size} event(s): ${dropped.joinToString { it.name }}")
        markQueueDirty()
        log.debug { "enqueued $name #$seq" }
        if (event.reserved || queue.size >= config.queueFlushAt) requestFlush() else armTimer()
        return event.takeIf { queue.contains(it.id) }
    }

    /** Writes are coalesced: one write after the burst of calls already on the executor. */
    private fun markQueueDirty() {
        queueDirty = true
        if (persistScheduled) return
        persistScheduled = true
        scheduler.execute {
            persistScheduled = false
            persistQueue()
        }
    }

    private fun persistQueue() {
        if (!queueDirty) return
        queueDirty = false
        if (!store.write(StoreFiles.QUEUE, queue.serialize(installId))) log.warn("could not write the event queue")
        saveState()
    }

    private fun saveState() {
        state.nextSeq = maxOf(state.nextSeq, queue.nextSeq)
        if (!store.write(StoreFiles.STATE, state.serialize(installId))) log.warn("could not write the SDK state")
    }

    private fun savePending() {
        if (!store.write(StoreFiles.PENDING_LINKS, pending.serialize())) log.warn("could not write the pending deep links")
    }

    private fun restorePendingLinks() {
        val expired = pending.expire(clock.now())
        var restored = 0
        for (entry in pending.entries()) {
            val event = QueuedEvent.fromJson(entry.event) ?: continue
            if (queue.contains(event.id)) continue
            queue.add(event) // same id and seq: the collector dedupes it
            restored++
        }
        if (restored > 0) {
            log.debug { "re-enqueued $restored pending deep link(s)" }
            markQueueDirty()
            requestFlush()
        }
        if (expired) savePending()
    }

    // --- Delivery ----------------------------------------------------

    private fun canSend(): Boolean = started && !stopped && configReady && !config.off && config.enabled && !sdkTooOld

    private fun requestFlush() {
        if (flushScheduled) return
        flushScheduled = true
        scheduler.execute {
            flushScheduled = false
            flushNow()
        }
    }

    private fun armTimer() {
        if (!foreground || timer != null || !canSend()) return
        timer = scheduler.schedule(config.intervalS * 1000L) {
            timer = null
            flushNow()
        }
    }

    private fun flushNow() {
        timer?.cancel()
        timer = null
        persistQueue() // a batch's events are on disk before they go out
        if (!canSend() || queue.isEmpty()) return
        val now = clock.now()
        if (state.retryNextAt > now) {
            scheduleRetry(state.retryNextAt - now)
            return
        }
        sendBatch()
    }

    private fun sendBatch() {
        val device = safely("reading the device context", null) { platform.deviceContext() }
        val context = device?.let { ContextJson.build(it, state.analytics, state.ads, state.lat, app.version, app.build) }
        val contextHash = context?.let { sha1Hex(it.toString()) }
        // The context goes out when it changed since the collector last stored one.
        val sentContextHash = contextHash?.takeIf { it != state.contextHash }
        val envelope = BatchBody.envelope(envelopeInfo(), clock.now(), if (sentContextHash != null) context else null)
        val maxCount = minOf(config.maxBatch, batchLimit ?: BatchBody.MAX_EVENTS).coerceAtLeast(1)
        val batch = BatchBody.select(queue.events(), maxCount, BatchBody.eventBudget(envelope))
        if (batch.isEmpty()) {
            val head = queue.events().first()
            queue.remove(listOf(head.id))
            markQueueDirty()
            log.error("${head.name} dropped: too large for a batch")
            requestFlush()
            return
        }
        val request = HttpRequest(
            "POST",
            url("/v1/sdk/batch"),
            headers(json = true),
            BatchBody.join(envelope, batch).toByteArray(Charsets.UTF_8),
        )
        val response = try {
            transport.execute(request)
        } catch (e: Exception) {
            log.debug { "batch not sent: ${e.javaClass.simpleName}: ${e.message}" }
            null
        }
        val outcome = response?.let { BatchResponses.classify(it.status, it.body, it.retryAfter) }
            ?: SendOutcome.Retry(null, null)
        handle(outcome, batch, sentContextHash)
    }

    private fun handle(outcome: SendOutcome, batch: List<QueuedEvent>, sentContextHash: String?) {
        when (outcome) {
            is SendOutcome.Acked -> onAcked(outcome.ack, batch, sentContextHash)
            is SendOutcome.Drop -> {
                queue.remove(batch.map { it.id })
                markQueueDirty()
                resetRetry()
                if (outcome.stop) {
                    stop(outcome.status, outcome.code)
                    log.error("${batch.size} event(s) dropped")
                } else if (!loggedDrop) {
                    loggedDrop = true
                    log.error("HTTP ${outcome.status}${outcome.code?.let { " ($it)" } ?: ""}: the collector refused a batch; ${batch.size} event(s) dropped")
                } else {
                    log.debug { "HTTP ${outcome.status}: ${batch.size} event(s) dropped" }
                }
                saveState()
            }
            SendOutcome.Split -> {
                if (batch.size > 1) {
                    batchLimit = batch.size / 2
                    log.debug { "HTTP 413: retrying with batches of ${batch.size / 2}" }
                } else {
                    queue.remove(listOf(batch[0].id))
                    markQueueDirty()
                    log.error("${batch[0].name} dropped: the collector says it is too large")
                }
                requestFlush()
            }
            is SendOutcome.Retry -> backOff(outcome.status, outcome.retryAfterMs)
        }
    }

    private fun onAcked(ack: BatchAck, batch: List<QueuedEvent>, sentContextHash: String?) {
        val names = batch.associate { it.id to it.name }
        val answered = HashSet<String>(ack.accepted)
        for (r in ack.rejected) r.id?.let { answered.add(it) }
        if (queue.remove(answered) > 0) markQueueDirty()
        for (r in ack.rejected) {
            log.warn("the collector rejected ${r.id?.let { names[it] } ?: "an event"} (${r.reason}); it is not resent")
        }
        if (pending.remove(answered)) savePending()
        val installEventId = state.installEventId
        if (!state.installAcked && installEventId != null && installEventId in ack.accepted) state.installAcked = true
        if (sentContextHash != null && ack.accepted.isNotEmpty()) state.contextHash = sentContextHash
        ack.configEtag?.let(::onConfigEtag)
        AttributionParser.fromJson(ack.attribution)?.let(::updateAttribution)
        val leftover = batch.count { it.id !in answered }
        if (leftover > 0) {
            // Ids in neither list stay queued; back off instead of resending at once.
            log.debug { "$leftover event(s) neither accepted nor rejected; retrying later" }
            backOff(200, null)
        } else {
            resetRetry()
            batchLimit = batchLimit?.let { limit -> (limit * 2).takeIf { it < config.maxBatch } }
            if (!queue.isEmpty()) requestFlush()
        }
        saveState()
    }

    private fun backOff(status: Int?, retryAfterMs: Long?) {
        state.retryAttempt += 1
        val delay = retryAfterMs?.coerceAtLeast(Backoff.BASE_MS) ?: Backoff.delayMs(state.retryAttempt, random)
        state.retryNextAt = clock.now() + delay
        saveState()
        log.debug { "batch not delivered (${status?.let { "HTTP $it" } ?: "network error"}); retry #${state.retryAttempt} in $delay ms" }
        scheduleRetry(delay)
    }

    private fun scheduleRetry(delayMs: Long) {
        retryTask?.cancel()
        retryTask = scheduler.schedule(delayMs) {
            retryTask = null
            flushNow()
        }
    }

    private fun resetRetry() {
        state.retryAttempt = 0
        state.retryNextAt = 0
        retryTask?.cancel()
        retryTask = null
    }

    private fun stop(status: Int, code: String?) {
        if (stopped) return
        stopped = true
        timer?.cancel()
        timer = null
        retryTask?.cancel()
        retryTask = null
        log.error("HTTP $status${code?.let { " ($it)" } ?: ""}: the collector refused the key or the package name; sending stops until the next launch")
    }

    private fun envelopeInfo() = BatchBody.Envelope(
        sdkName = SdkInfo.NAME,
        sdkVersion = SdkInfo.VERSION,
        wrapper = cfg.wrapper,
        bundle = app.bundle,
        appVersion = app.version?.take(32),
        appBuild = app.build?.take(32),
        environment = cfg.environment,
        installId = installId,
    )

    private fun url(path: String): String = cfg.endpoint + path

    private fun headers(json: Boolean): MutableMap<String, String> {
        val h = LinkedHashMap<String, String>()
        h["Authorization"] = "Bearer ${cfg.key}"
        h["X-Afr-Bundle"] = app.bundle
        h["X-Afr-Sdk"] = SdkInfo.header(cfg.wrapper)
        // The app's version picks the config Kerdly serves (its version rules).
        app.version?.takeIf { it.isNotEmpty() }?.let { h["X-Afr-App-Version"] = it }
        app.build?.takeIf { it.isNotEmpty() }?.let { h["X-Afr-App-Build"] = it }
        h["Accept"] = "application/json"
        if (json) h["Content-Type"] = "application/json"
        return h
    }

    // --- Remote config --------------------------------------------------------

    private fun onConfigEtag(etag: String) {
        etagHint = etag
        if (etag != configCache.etag) scheduler.execute { maybeFetchConfig(force = true) }
    }

    /**
     * At launch when the cache is ≥ 6 h old or was fetched for another app version (the first launch
     * after an update) ([force] false); when a batch names another ETag.
     */
    private fun maybeFetchConfig(force: Boolean) {
        if (stopped) return
        val now = clock.now()
        if (force) {
            if (configCache.etag != null && configCache.etag == etagHint) return
        } else {
            val fetchedAt = configCache.fetchedAt
            val fresh = fetchedAt != null && now >= fetchedAt && now - fetchedAt < CONFIG_MAX_AGE_MS
            if (configCache.config != null && fresh && configCache.appVersion == app.version) return
        }
        val last = lastConfigAttemptAt
        // Rate-limited once this version's config is in; before, the back-off paces the asks.
        if (configReady && last != null && now >= last && now - last < CONFIG_MIN_INTERVAL_MS) return
        lastConfigAttemptAt = now
        fetchConfig(now)
        afterConfigFetch()
    }

    private fun fetchConfig(now: Long) {
        val headers = headers(json = false)
        val etag = configCache.etag
        if (etag != null && configCache.config != null) headers["If-None-Match"] = etag
        val response = try {
            transport.execute(HttpRequest("GET", url("/v1/sdk/config"), headers, null))
        } catch (e: Exception) {
            log.debug { "config not fetched: ${e.javaClass.simpleName}: ${e.message}" }
            return
        }
        when (response.status) {
            200 -> {
                val raw = parseObject(response.body)
                if (raw == null) {
                    log.warn("ignored an unreadable remote config")
                    return
                }
                configCache = ConfigCache(response.etag ?: etagHint, now, raw, app.version)
                if (!store.write(StoreFiles.CONFIG, configCache.serialize())) log.warn("could not write the remote config")
                setConfig(configCache.config ?: RemoteConfig.DEFAULT)
                log.debug { "remote config ${configCache.etag ?: "(no etag)"} applied" }
            }
            304 -> {
                // Unchanged for the version the request named: the cached body is this version's too.
                configCache = ConfigCache(configCache.etag, now, configCache.raw, app.version)
                store.write(StoreFiles.CONFIG, configCache.serialize())
            }
            401, 403 -> stop(response.status, BatchResponses.errorCode(response.body))
            else -> log.debug { "config fetch: HTTP ${response.status}" }
        }
    }

    private fun setConfig(next: RemoteConfig) {
        val couldSend = canSend()
        config = next
        applyConfig()
        if (!couldSend && canSend() && !queue.isEmpty()) requestFlush()
        // A later config may switch deferred links on; the launch's first config starts the
        // collectors itself (afterConfigFetch).
        if (launchWorkDone) scheduler.execute { askDeferredLinks() }
    }

    private fun applyConfig() {
        val tooOld = config.minSupportedSdk?.let { Semver.compare(SdkInfo.VERSION, it) < 0 } ?: false
        if (tooOld && !sdkTooOld) {
            log.warn("this SDK (${SdkInfo.VERSION}) is older than min_supported_sdk ${config.minSupportedSdk}; sending is paused")
        }
        sdkTooOld = tooOld
        if (!config.enabled) log.info("sending is paused by the remote config")
        log.verbose = installId.isNotEmpty() && installId in config.debugDevices
    }

    // --- Attribution --------------------------------------------------------

    private fun scheduleAttributionPolls() {
        for (delay in ATTRIBUTION_POLLS_MS) scheduler.schedule(delay) { pollAttribution() }
    }

    private fun pollAttribution() {
        // Polls only help while nothing is known and the collector has the install.
        if (attribution != null || !canSend() || !state.installAcked) return
        val url = url("/v1/sdk/attribution?install_id=" + URLEncoder.encode(installId, "UTF-8"))
        val response = try {
            transport.execute(HttpRequest("GET", url, headers(json = false), null))
        } catch (e: Exception) {
            log.debug { "attribution poll failed: ${e.javaClass.simpleName}" }
            return
        }
        when (response.status) {
            200 -> AttributionParser.fromPollBody(response.body)?.let(::updateAttribution)
            401, 403 -> stop(response.status, BatchResponses.errorCode(response.body))
            else -> log.debug { "attribution poll: HTTP ${response.status}" }
        }
    }

    private fun updateAttribution(next: KerdlyAttribution) {
        val current = attribution
        if (current != null && jsonEquals(parseObject(current.raw), parseObject(next.raw))) return
        attribution = next
        if (!store.write(StoreFiles.ATTRIBUTION, next.raw)) log.warn("could not write the attribution")
        log.debug { "attribution: ${next.network} / ${next.method} (${next.state})" }
        for (l in listeners) deliver(l, next)
    }

    private fun deliver(listener: (KerdlyAttribution) -> Unit, value: KerdlyAttribution) {
        main.post {
            try {
                listener(value)
            } catch (t: Throwable) {
                log.error("an onAttribution listener threw", t)
            }
        }
    }

    // --- Collectors ---------------------------------------------------

    private fun startCollectors() {
        if (cfg.metaAppId != null && !state.metaDone) scheduler.execute { collectMetaReferrer() }
        scheduler.execute { collectAdvertisingId(force = false) }
        startPlayReferrer()
        scheduler.execute { askDeferredLinks() }
    }

    /** GAID + LAT: read at launch when the last read is ≥ 24 h old, sent only when it changed. */
    private fun collectAdvertisingId(force: Boolean) {
        if (!collecting()) return
        if (!cfg.collectAdvertisingId || !state.ads || !config.collectAdvertisingId) return
        val now = clock.now()
        val last = state.adIdReadAt
        if (!force && last != null && now >= last && now - last < AD_ID_REFRESH_MS) return
        val result = safely("reading the advertising id", null) { platform.readAdvertisingId() } ?: return
        state.adIdReadAt = now
        state.lat = result.lat
        val hash = sha1Hex("${result.gaid ?: ""}|${result.lat}")
        if (hash != state.adIdHash) {
            if (enqueue(EventNames.SIGNAL, Signals.advertisingIds(result.gaid, result.lat), now) != null) state.adIdHash = hash
            log.debug { "advertising id ${maskId(result.gaid)} (lat ${result.lat})" }
        }
        saveState()
    }

    /** Once per install, on the launch with `$install`. The answer comes back to this
     * thread, where the gates are checked again: consent withdrawn or a fetched config with
     * `collect.public_ip: false` in the meantime drops it. No answer, or one that is not a global
     * unicast IPv6 address, sends nothing and is never retried. */
    private fun collectPublicIp() {
        if (!collecting() || !publicIpAllowed()) return
        try {
            platform.startPublicIpv6Lookup(config.ipv6EchoUrl, PUBLIC_IP_TIMEOUT_MS) { answer ->
                scheduler.execute { publicIpFinished(answer) }
            }
        } catch (t: Throwable) {
            log.debug { "public IPv6 lookup: ${t.javaClass.simpleName}" }
        }
    }

    private fun publicIpAllowed(): Boolean = state.ads && config.collectPublicIp

    private fun publicIpFinished(answer: String?) {
        if (!publicIpAllowed()) {
            log.debug { "public IPv6 answer dropped: ads consent or collect.public_ip is off now" }
            return
        }
        val ipv6 = PublicIp.globalIpv6(answer)
        if (ipv6 == null) {
            log.debug { if (answer == null) "no public IPv6" else "the public IPv6 lookup answered something else; dropped" }
            return
        }
        enqueue(EventNames.SIGNAL, Signals.publicIp(ipv6), clock.now())
        log.info("public IPv6 ${maskId(ipv6)}")
    }

    /** Once per install, when `metaAppId` is set: the freshest row of the three Meta apps. */
    private fun collectMetaReferrer() {
        if (!collecting()) return
        val appId = cfg.metaAppId ?: return
        if (state.metaDone || !config.collectMetaInstallReferrer) return
        val rows = safely("reading the Meta install referrer", emptyList()) { platform.readMetaReferrer(appId) }
        val best = MetaReferrer.freshest(rows)
        if (best != null) {
            enqueue(EventNames.SIGNAL, Signals.metaInstallReferrer(best), clock.now())
            log.debug { "Meta install referrer from ${best.source}" }
        } else {
            log.debug { "no Meta install referrer" }
        }
        state.metaDone = true
        saveState()
    }

    /** Until it answers OK or a permanent code; transient failures retry at the next foreground
     * and launch, for 90 days after the install (the first attempt always runs). */
    private fun startPlayReferrer() {
        if (!collecting()) return
        if (!config.collectInstallReferrer || state.referrerDone || referrerInFlight) return
        val since = state.installedAt ?: state.firstLaunchAt
        if (state.referrerAttempts > 0 && since != null && clock.now() - since > REFERRER_WINDOW_MS) {
            state.referrerDone = true
            saveState()
            log.debug { "Play install referrer: no answer within 90 days of the install; giving up" }
            return
        }
        referrerInFlight = true
        state.referrerAttempts += 1
        try {
            platform.startPlayReferrer(REFERRER_TIMEOUT_MS) { result -> scheduler.execute { onPlayReferrer(result) } }
        } catch (t: Throwable) {
            referrerInFlight = false
            log.debug { "Play install referrer: ${t.javaClass.simpleName}" }
        }
    }

    private fun onPlayReferrer(result: PlayReferrerResult) {
        referrerInFlight = false
        if (state.referrerDone) return
        when (result) {
            is PlayReferrerResult.Ok -> {
                enqueue(EventNames.SIGNAL, Signals.installReferrerOk(result.details), clock.now())
                state.referrerDone = true
                if (state.ddlEligible && !state.ddlTiktokDone) state.ddlReferrer = result.details.referrer
            }
            is PlayReferrerResult.Permanent -> {
                enqueue(EventNames.SIGNAL, Signals.installReferrerUnavailable(result.code), clock.now())
                state.referrerDone = true
                log.debug { "Play install referrer unavailable (code ${result.code}): not installed from Play" }
            }
            is PlayReferrerResult.Transient -> log.debug { "Play install referrer: ${result.reason}; retrying at the next foreground or launch" }
        }
        saveState()
        askDeferredLinks()
    }

    // --- Deferred deep links -------------------------------------------------

    /** TikTok, once per install: on the collectors, a fetched config, the Play referrer's answer
     * (TikTok's request carries it, so the SDK waits for Play's first answer) and a foreground (a
     * retry after a failure in transit). Only while the config's `ddl` block is on, the install is
     * younger than `max_age_h` and the `ads` consent is on. The GAID goes only without
     * limit-ad-tracking. Blocking, like the batch: it runs on the SDK's own thread. */
    private fun askDeferredLinks() {
        if (!collecting()) return
        val ddl = config.ddl ?: return
        val appId = ddl.tiktokAppId ?: return
        if (!ddl.enabled || !state.ddlEligible || state.ddlTiktokDone || !state.ads || stopped || ddlWaitsForForeground) return
        val first = state.firstLaunchAt ?: return
        if (clock.now() - first > ddl.maxAgeMs) return
        if (config.collectInstallReferrer && !state.referrerDone && (referrerInFlight || state.referrerAttempts == 0)) return
        val adId = if (cfg.collectAdvertisingId && config.collectAdvertisingId) safely("reading the advertising id", null) { platform.readAdvertisingId() } else null
        val device = safely("reading the device context", null) { platform.deviceContext() } ?: DeviceContext.UNKNOWN
        val request = TikTokDdl.request(
            appId, ddl.storeAppId, app, device, adId?.takeIf { !it.lat }?.gaid, state.ddlReferrer,
            safely("reading the user agent", null) { System.getProperty("http.agent") }, clock.now(),
        )
        val answer = try {
            TikTokDdl.parse(transport.execute(request))
        } catch (e: Exception) {
            DdlAnswer(TikTokDdl.NETWORK, "error", null, null, "${e.javaClass.simpleName}: ${e.message}")
        }
        if (answer.transient) {
            state.ddlTiktokFailures += 1
            if (state.ddlTiktokFailures < MAX_DDL_FAILURES) {
                ddlWaitsForForeground = true
                saveState()
                log.debug { "deferred link: TikTok did not answer (${answer.detail}); retried at the next foreground" }
                return
            }
        }
        val attempt = if (answer.transient) state.ddlTiktokFailures else state.ddlTiktokFailures + 1
        state.ddlTiktokDone = true
        state.ddlReferrer = null
        saveState()
        enqueue(EventNames.SIGNAL, Signals.deferredLink(answer, attempt), clock.now())
        log.info("deferred link: TikTok ${answer.status}")
    }

    private inline fun <T> safely(what: String, fallback: T, block: () -> T): T = try {
        block()
    } catch (t: Throwable) {
        log.warn("$what failed", t)
        fallback
    }
}
