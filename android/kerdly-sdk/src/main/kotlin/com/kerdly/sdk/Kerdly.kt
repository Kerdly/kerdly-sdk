package com.kerdly.sdk

import android.app.Application
import android.content.Context
import android.os.StrictMode
import com.kerdly.sdk.internal.Clock
import com.kerdly.sdk.internal.Core
import com.kerdly.sdk.internal.CoreConfig
import com.kerdly.sdk.internal.DeepLinkSources
import com.kerdly.sdk.internal.DeepLinks
import com.kerdly.sdk.internal.FileStore
import com.kerdly.sdk.internal.InstallId
import com.kerdly.sdk.internal.Launch
import com.kerdly.sdk.internal.Logger
import com.kerdly.sdk.internal.OptionRules
import com.kerdly.sdk.internal.Scheduler
import com.kerdly.sdk.internal.StandardEvents
import com.kerdly.sdk.internal.android.AndroidLogSink
import com.kerdly.sdk.internal.android.AndroidPlatform
import com.kerdly.sdk.internal.android.ExecutorScheduler
import com.kerdly.sdk.internal.android.HttpUrlTransport
import com.kerdly.sdk.internal.android.LifecycleTracker
import com.kerdly.sdk.internal.android.MainThreadDispatcher
import java.io.File

/** The Kerdly SDK (protocol v1). Call [configure] once, in `Application.onCreate`.
 *
 * Every method is safe from any thread, returns at once and never throws: work runs on the
 * SDK's own background thread. Calls made before [configure] are held (up to 100) and run right
 * after it. */
object Kerdly {
    private const val MAX_BUFFERED_CALLS = 100

    private val lock = Any()
    private val log = Logger(KerdlyLogLevel.WARN, AndroidLogSink)
    private val deepLinkSources = DeepLinkSources()
    private val buffered = ArrayList<(Core) -> Unit>()

    @Volatile private var core: Core? = null

    @Volatile private var scheduler: Scheduler? = null

    @Volatile private var currentInstallId: String? = null

    /** Loads or creates the install id and enqueues `$install` (first launch) and `$open`; the
     * rest happens on the SDK thread. Cheap on the calling thread. A second call is ignored. */
    @JvmStatic
    fun configure(context: Context, options: KerdlyOptions) {
        try {
            synchronized(lock) { configureLocked(context, options) }
        } catch (t: Throwable) {
            log.error("configure failed; the SDK is off for this launch", t)
        }
    }

    private fun configureLocked(context: Context, options: KerdlyOptions) {
        if (core != null) {
            log.info("configure: already configured; this call is ignored")
            return
        }
        log.level = options.logLevel
        val endpoint = OptionRules.endpoint(options.endpoint)
        if (endpoint == null) {
            log.error("configure: endpoint must be an http(s) base URL; the SDK is off")
            return
        }
        val key = options.key.trim()
        when (OptionRules.checkKey(key)) {
            OptionRules.KeyCheck.INVALID -> {
                log.error("configure: the key is empty or malformed; the SDK is off")
                return
            }
            OptionRules.KeyCheck.SECRET -> {
                log.error("configure: that is a server key (sk_…); apps take their public pk_ key. The SDK is off")
                return
            }
            OptionRules.KeyCheck.NOT_PUBLIC -> log.warn("configure: app keys start with pk_live_ or pk_test_")
            OptionRules.KeyCheck.OK -> Unit
        }
        val appContext = context.applicationContext ?: context
        // Without an explicit metaAppId, the manifest's `com.kerdly.sdk.META_APP_ID` meta-data
        // (what the Expo config plugin writes) turns the Meta Install Referrer read on.
        val (metaAppId, metaAppIdValid) = OptionRules.metaAppId(options.metaAppId ?: AndroidPlatform.manifestMetaAppId(appContext))
        if (!metaAppIdValid) log.warn("configure: metaAppId must be the numeric Facebook app id; the Meta Install Referrer is off")

        val now = System.currentTimeMillis()
        val (store, identity) = withDiskAccess {
            // All SDK state lives in noBackupFilesDir/afr/: Auto Backup never copies it. Only the
            // id is read here; a new one is written by the launch task.
            val s = FileStore(File(appContext.noBackupFilesDir, "afr"))
            s to InstallId.load(s)
        }

        val sdkScheduler = ExecutorScheduler(log)
        val engine = Core(
            cfg = CoreConfig(
                key = key,
                endpoint = endpoint,
                environment = OptionRules.environment(options.environment, AndroidPlatform.isDebuggable(appContext)),
                collectAdvertisingId = options.collectAdvertisingId,
                metaAppId = metaAppId,
                wrapper = OptionRules.wrapper(options.wrapper),
            ),
            platform = AndroidPlatform(appContext, sdkScheduler, log),
            transport = HttpUrlTransport(),
            store = store,
            scheduler = sdkScheduler,
            clock = Clock { System.currentTimeMillis() },
            log = log,
            main = MainThreadDispatcher,
        )
        val foreground = AndroidPlatform.isProcessForeground()
        val replay = ArrayList(buffered)
        buffered.clear()
        // The launch task is the first task on the SDK thread; every later call queues behind it.
        sdkScheduler.execute { engine.start(Launch(identity.id, identity.created, now, foreground), replay) }
        currentInstallId = identity.id
        scheduler = sdkScheduler
        core = engine

        val application = appContext as? Application
        if (application != null) {
            application.registerActivityLifecycleCallbacks(
                LifecycleTracker(
                    initialForeground = foreground,
                    onForeground = {
                        val ts = System.currentTimeMillis()
                        sdkScheduler.execute { engine.onForeground(ts) }
                    },
                    onBackground = {
                        deepLinkSources.onBackground()
                        val ts = System.currentTimeMillis()
                        sdkScheduler.execute { engine.onBackground(ts) }
                    },
                ),
            )
        } else {
            log.warn("configure: no Application context; foreground and background are not tracked")
        }
        log.info("configured; install ${identity.id}${if (identity.created) " (new)" else ""}")
    }

    /** This install's id (lowercase UUIDv4); null before [configure]. */
    @JvmStatic
    val installId: String?
        get() = currentInstallId

    /** Sets (or, with null, clears) the user id stamped on later events; `$identify` on change. */
    @JvmStatic
    fun setUserId(userId: String?) = call("setUserId") { ts ->
        submit { it.setUserId(userId, ts) }
    }

    /** A custom event: name and keys `[a-z][a-z0-9_]{0,39}`, ≤ 25 props of string, number or
     * boolean. Invalid props are dropped; an invalid name drops the event. A standard event's name
     * (`registration`, `start_trial`, `subscribe`, `purchase`) gets its typed checks too; prefer
     * the typed methods below. */
    @JvmStatic
    @JvmOverloads
    fun track(name: String, properties: Map<String, Any?> = emptyMap()) = call("track") { ts ->
        val props = LinkedHashMap(properties)
        submit { it.track(name, props, ts) }
    }

    // Standard events: ordinary events with typed props. Each argument is
    // optional; `properties` adds custom props under the `track` rules and never replaces an
    // argument. `product_id` and `transaction_id` are cut at 128 characters; `value` is the price
    // paid in `currency` (0 for a free trial), dropped unless it is a finite number ≥ 0 with a
    // three-letter ISO 4217 currency (upper-cased by the SDK).

    /** `registration`: [method] is how the user signed up (`anonymous`, `apple`, `google`,
     * `email`, …; ≤ 64 characters). */
    @JvmStatic
    @JvmOverloads
    fun trackRegistration(method: String? = null, properties: Map<String, Any?> = emptyMap()) = call("trackRegistration") { ts ->
        val args = StandardEvents.registration(method)
        val props = copyOf(properties)
        submit { it.trackStandard(StandardEvents.REGISTRATION, args, props, ts) }
    }

    /** `start_trial`: a trial began (`value` 0 for a free trial). */
    @JvmStatic
    @JvmOverloads
    fun trackStartTrial(
        productId: String? = null,
        value: Double? = null,
        currency: String? = null,
        transactionId: String? = null,
        properties: Map<String, Any?> = emptyMap(),
    ) = call("trackStartTrial") { ts ->
        val args = StandardEvents.money(productId, value, currency, transactionId)
        val props = copyOf(properties)
        submit { it.trackStandard(StandardEvents.START_TRIAL, args, props, ts) }
    }

    /** `subscribe`: a paid subscription began. */
    @JvmStatic
    @JvmOverloads
    fun trackSubscribe(
        productId: String? = null,
        value: Double? = null,
        currency: String? = null,
        transactionId: String? = null,
        properties: Map<String, Any?> = emptyMap(),
    ) = call("trackSubscribe") { ts ->
        val args = StandardEvents.money(productId, value, currency, transactionId)
        val props = copyOf(properties)
        submit { it.trackStandard(StandardEvents.SUBSCRIBE, args, props, ts) }
    }

    /** `purchase`: a one-time purchase; [quantity] is an integer ≥ 1. */
    @JvmStatic
    @JvmOverloads
    fun trackPurchase(
        productId: String? = null,
        value: Double? = null,
        currency: String? = null,
        quantity: Int? = null,
        transactionId: String? = null,
        properties: Map<String, Any?> = emptyMap(),
    ) = call("trackPurchase") { ts ->
        val args = StandardEvents.money(productId, value, currency, transactionId, quantity)
        val props = copyOf(properties)
        submit { it.trackStandard(StandardEvents.PURCHASE, args, props, ts) }
    }

    /** Null leaves a flag unchanged. `analytics = false` keeps only the SDK's attribution events;
     * `ads = false` stops advertising-id reads. `$consent` on change. */
    @JvmStatic
    @JvmOverloads
    fun setConsent(analytics: Boolean? = null, ads: Boolean? = null) = call("setConsent") { ts ->
        submit { it.setConsent(analytics, ads, ts) }
    }

    /** Records a URL the app was opened with (`$deeplink`) and returns its parsed params; null
     * for a blank string. Call it from every URL entry point (onCreate / onNewIntent).
     * `source` is `"initial"` for the URL that launched the app and `"runtime"` for one that
     * arrived while it ran; a caller that knows (the Expo bridge) passes it, otherwise the SDK
     * infers it (the first URL before the app first went to the background is `initial`). */
    @JvmStatic
    @JvmOverloads
    fun handleUrl(url: String, source: String? = null): KerdlyDeepLink? = try {
        val link = DeepLinks.parse(url)
        if (link != null) {
            val source = deepLinkSources.next(source)
            val ts = System.currentTimeMillis()
            submit { it.handleUrl(link, source, ts) }
        }
        link
    } catch (t: Throwable) {
        log.error("handleUrl failed", t)
        null
    }

    /** The account token purchases carry: a UUID, or Superwall's `$SuperwallAlias:<uuid>`
     * obfuscated account id before identify. `$ids` on change. */
    @JvmStatic
    fun setAppAccountToken(token: String?) = call("setAppAccountToken") { ts ->
        submit { it.setAppAccountToken(token, ts) }
    }

    /** Ids other SDKs own (e.g. `meta_anon_id`, `superwall_alias`), merged into the stored set;
     * an empty value removes its key. `$ids` on change. */
    @JvmStatic
    fun setPartnerIds(ids: Map<String, String>) = call("setPartnerIds") { ts ->
        val copy = LinkedHashMap(ids)
        submit { it.setPartnerIds(copy, ts) }
    }

    /** A Play purchase the paywall completed: `$purchase_link`, once per purchase token. */
    @JvmStatic
    fun notifyPurchase(purchase: KerdlyPurchase) = call("notifyPurchase") { ts ->
        val copy = purchase.copy(products = purchase.products.toList())
        submit { it.notifyPurchase(copy, ts) }
    }

    /** An event the app just sent to an ad network through that network's SDK (`$network_send`). */
    @JvmStatic
    fun recordNetworkSend(send: KerdlyNetworkSend) = call("recordNetworkSend") { ts ->
        submit { it.recordNetworkSend(send, ts) }
    }

    /** The cached attribution; null until the collector decides one. */
    @JvmStatic
    val attribution: KerdlyAttribution?
        get() = core?.attribution

    /** Called on the main thread with the attribution now (if known) and whenever it changes. */
    @JvmStatic
    fun onAttribution(listener: (KerdlyAttribution) -> Unit) = call("onAttribution") { _ ->
        submit { it.addAttributionListener(listener) }
    }

    /** Sends what is queued now (subject to back-off). */
    @JvmStatic
    fun flush() = call("flush") { _ ->
        submit { it.flush() }
    }

    private inline fun call(what: String, block: (Long) -> Unit) {
        try {
            block(System.currentTimeMillis())
        } catch (t: Throwable) {
            log.error("$what failed", t)
        }
    }

    /** A copy taken on the caller's thread; a Java caller's null map is empty, so the typed
     * arguments still go out. */
    private fun copyOf(properties: Map<String, Any?>?): Map<String, Any?> =
        if (properties == null) emptyMap() else LinkedHashMap(properties)

    private fun submit(op: (Core) -> Unit) {
        val c = core
        val s = scheduler
        if (c != null && s != null) {
            s.execute { op(c) }
            return
        }
        synchronized(lock) {
            val c2 = core
            val s2 = scheduler
            if (c2 != null && s2 != null) {
                s2.execute { op(c2) }
            } else if (buffered.size < MAX_BUFFERED_CALLS) {
                buffered.add(op)
            } else {
                log.warn("called before configure: call dropped (over $MAX_BUFFERED_CALLS waiting)")
            }
        }
    }

    /** The id file is tiny; reading it here keeps [installId] valid as soon as configure returns.
     * Lifted out of the app's StrictMode disk policy for that one read. */
    private inline fun <T> withDiskAccess(block: () -> T): T {
        val policy = StrictMode.allowThreadDiskWrites()
        try {
            return block()
        } finally {
            StrictMode.setThreadPolicy(policy)
        }
    }
}
