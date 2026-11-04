package com.kerdly.sdk.internal

import com.kerdly.sdk.KerdlyAttribution
import com.kerdly.sdk.KerdlyLogLevel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.PriorityQueue
import kotlin.random.Random

internal class FakeClock(var now: Long = 1_760_400_000_100L) : Clock {
    override fun now(): Long = now
}

/** Virtual time: tasks run only when the test says so, in (time, submission) order. */
internal class FakeScheduler(private val clock: FakeClock) : Scheduler {
    private class Task(val at: Long, val order: Long, val fn: () -> Unit) {
        var cancelled = false
    }

    private val tasks = PriorityQueue<Task>(compareBy<Task>({ it.at }, { it.order }))
    private var counter = 0L

    override fun execute(task: () -> Unit) {
        schedule(0, task)
    }

    override fun schedule(delayMs: Long, task: () -> Unit): Cancellable {
        val t = Task(clock.now + maxOf(0, delayMs), counter++, task)
        tasks.add(t)
        return Cancellable { t.cancelled = true }
    }

    /** Runs every task due now, including the ones they schedule for now. */
    fun runDue() {
        while (true) {
            val t = tasks.peek() ?: return
            if (t.at > clock.now) return
            tasks.poll()
            if (!t.cancelled) t.fn()
        }
    }

    /** Moves the clock forward by [ms], running each task at its own time. */
    fun advance(ms: Long) {
        val target = clock.now + ms
        while (true) {
            val t = tasks.peek() ?: break
            if (t.at > target) break
            tasks.poll()
            if (t.at > clock.now) clock.now = t.at
            if (!t.cancelled) t.fn()
        }
        clock.now = target
    }
}

internal class MemoryStore : Store {
    val files = HashMap<String, String>()

    override fun read(name: String): String? = files[name]

    override fun write(name: String, content: String): Boolean {
        files[name] = content
        return true
    }

    override fun delete(name: String) {
        files.remove(name)
    }
}

/** Answers like the collector: by default every batch is accepted and the config is the fixture. */
internal class FakeTransport : Transport {
    val requests = ArrayList<HttpRequest>()
    var offline = false
    /** Only batches fail in transit; the config and the rest still answer. */
    var offlineBatches = false
    var batchHandler: (JSONObject) -> HttpResponse = { ackAll(it) }
    var configHandler: (HttpRequest) -> HttpResponse = {
        HttpResponse(200, Spec.text("config.response.json"), etag = CONFIG_ETAG)
    }
    var attributionHandler: (HttpRequest) -> HttpResponse = {
        HttpResponse(404, """{"error":"unknown install","code":"not_found"}""")
    }
    /** TikTok's deferred-deep-link endpoint; by default it has no link for the device. */
    var ddlHandler: (HttpRequest) -> HttpResponse = {
        HttpResponse(200, """{"code":0,"message":"OK","data":{"ddl":""}}""")
    }

    /** [requests] is what reached the server: an offline attempt is not in it. */
    override fun execute(request: HttpRequest): HttpResponse {
        if (offline || (offlineBatches && request.url.endsWith("/v1/sdk/batch"))) throw IOException("offline")
        requests.add(request)
        return when {
            request.url.endsWith("/v1/sdk/batch") -> batchHandler(JSONObject(String(request.body!!, Charsets.UTF_8)))
            request.url.endsWith("/v1/sdk/config") -> configHandler(request)
            request.url.contains("/v1/sdk/attribution") -> attributionHandler(request)
            request.url == TikTokDdl.URL -> ddlHandler(request)
            else -> HttpResponse(404, "")
        }
    }

    fun batchRequests(): List<HttpRequest> = requests.filter { it.method == "POST" && it.url.endsWith("/v1/sdk/batch") }

    fun batches(): List<JSONObject> = batchRequests().map { JSONObject(String(it.body!!, Charsets.UTF_8)) }

    fun configRequests(): List<HttpRequest> = requests.filter { it.url.endsWith("/v1/sdk/config") }

    fun attributionRequests(): List<HttpRequest> = requests.filter { it.url.contains("/v1/sdk/attribution") }

    fun ddlRequests(): List<HttpRequest> = requests.filter { it.url == TikTokDdl.URL }

    /** Every event of every batch, in send order. */
    fun sentEvents(): List<JSONObject> = batches().flatMap { b -> b.getJSONArray("events").objects() }

    companion object {
        const val CONFIG_ETAG = "\"1-5e1a\""

        fun ackAll(body: JSONObject, attribution: JSONObject? = null, etag: String = CONFIG_ETAG): HttpResponse {
            val ids = body.getJSONArray("events").objects().map { it.getString("id") }
            return ack(accepted = ids, attribution = attribution, etag = etag)
        }

        fun ack(
            accepted: List<String>,
            rejected: List<Pair<String, String>> = emptyList(),
            attribution: JSONObject? = null,
            etag: String = CONFIG_ETAG,
        ): HttpResponse {
            val rej = JSONArray()
            for ((id, reason) in rejected) rej.put(JSONObject().put("id", id).put("reason", reason))
            val o = JSONObject()
                .put("accepted", JSONArray(accepted))
                .put("rejected", rej)
                .put("config_etag", etag)
                .put("attribution", attribution ?: JSONObject.NULL)
                .put("needs", JSONArray())
                .put("cv_hints", JSONArray())
            return HttpResponse(200, o.toString())
        }
    }
}

internal class FakePlatform : Platform {
    var app = AppInfo("com.acme.other", "5.12", "1310")
    var install = InstallInfo(installedAt = 1_760_399_960_000L, installer = "com.android.vending")
    var device = DeviceContext(
        os = "15",
        model = "SM-S921B",
        manufacturer = "samsung",
        locale = "es_US",
        languages = listOf("es-US", "en-US"),
        tz = "America/Los_Angeles",
        screenW = 1080,
        screenH = 2340,
        scale = 2.625,
        testLab = false,
    )
    /** The device read throws (no display, a platform bug). */
    var deviceFails = false
    var adId: AdIdResult? = AdIdResult("38400000-8cf0-11bd-b23e-10b96e40000d", false)
    var adIdReads = 0
    var metaRows: List<MetaReferrerRow> = emptyList()
    var metaReads = 0
    /** The echo's `ip`, answered at once; null is no answer (an IPv4-only network, the timeout). */
    var publicIp: String? = null
    /** True holds the callback in [heldPublicIp] for the test to answer. */
    var holdPublicIp = false
    var heldPublicIp: ((String?) -> Unit)? = null
    /** Each lookup's echo URL and timeout, in order. */
    val publicIpLookups = ArrayList<Pair<String, Long>>()
    /** Runs as each lookup starts, to see what had happened by then. */
    var onPublicIpLookup: () -> Unit = {}

    /** Answered at once; null holds the callback in [heldReferrer] for the test to answer. */
    var referrerResult: PlayReferrerResult? = PlayReferrerResult.Transient("not set in the test")
    var referrerStarts = 0
    var heldReferrer: ((PlayReferrerResult) -> Unit)? = null

    override fun appInfo(): AppInfo = app
    override fun installInfo(): InstallInfo = install
    override fun deviceContext(): DeviceContext {
        if (deviceFails) throw IllegalStateException("no display")
        return device
    }

    override fun readAdvertisingId(): AdIdResult? {
        adIdReads++
        return adId
    }

    override fun readMetaReferrer(metaAppId: String): List<MetaReferrerRow> {
        metaReads++
        return metaRows
    }

    override fun startPublicIpv6Lookup(echoUrl: String, timeoutMs: Long, onResult: (String?) -> Unit) {
        publicIpLookups.add(echoUrl to timeoutMs)
        onPublicIpLookup()
        if (holdPublicIp) heldPublicIp = onResult else onResult(publicIp)
    }

    override fun startPlayReferrer(timeoutMs: Long, onResult: (PlayReferrerResult) -> Unit) {
        referrerStarts++
        val r = referrerResult
        if (r == null) heldReferrer = onResult else onResult(r)
    }

    companion object {
        /** The fixture's referrer, as Play reports it. */
        val FIXTURE_REFERRER = PlayReferrerDetails.of(
            referrer = "afr_c=k3f9q2xab7mn&utm_source=meta&utm_medium=web2app&utm_campaign=failed3&afr_l=lnk_01&w2a_id=abcd1234efgh5678&lp=failing-exam&cpp=web-meta",
            clickTs = 1_760_399_890,
            installBeginTs = 1_760_399_930,
            clickServerTs = 1_760_399_891,
            installBeginServerTs = 1_760_399_931,
            installVersion = "5.12",
            instant = false,
        )
    }
}

internal class CollectingSink : LogSink {
    val lines = ArrayList<String>()

    override fun write(level: KerdlyLogLevel, message: String, error: Throwable?) {
        lines.add("$level $message")
    }
}

/** One Core per "process"; [relaunch] starts a new one on the same disk, clock and server. */
internal class Harness(
    val store: MemoryStore = MemoryStore(),
    val clock: FakeClock = FakeClock(),
    val platform: FakePlatform = FakePlatform(),
    val transport: FakeTransport = FakeTransport(),
    var cfg: CoreConfig = CoreConfig(
        key = "pk_test_123",
        endpoint = "https://sdk.example.com",
        environment = "production",
        collectAdvertisingId = true,
        metaAppId = null,
        wrapper = null,
    ),
) {
    var scheduler = FakeScheduler(clock)
    val sink = CollectingSink()
    val log = Logger(KerdlyLogLevel.DEBUG, sink)
    val delivered = ArrayList<KerdlyAttribution>()
    lateinit var core: Core
    lateinit var installId: String
    private var eventIds = 0

    /** configure(): id file, then the launch task (run with [runDue]). */
    fun launch(foreground: Boolean = true, buffered: List<(Core) -> Unit> = emptyList()): Core {
        scheduler = FakeScheduler(clock)
        val identity = InstallId.load(store) { FIXTURE_INSTALL_ID }
        installId = identity.id
        val c = Core(
            cfg,
            platform,
            transport,
            store,
            scheduler,
            clock,
            log,
            MainDispatcher { it() },
            Random(7),
            newEventId = { "00000000-0000-4000-8000-%012d".format(++eventIds) },
        )
        core = c
        val ts = clock.now
        scheduler.execute { c.start(Launch(identity.id, identity.created, ts, foreground), buffered) }
        return c
    }

    fun relaunch(foreground: Boolean = true): Core = launch(foreground)

    /** Queues [block] on the SDK thread, as the public API does. */
    fun on(block: (Core) -> Unit) {
        val c = core
        scheduler.execute { block(c) }
    }

    /** Queues [block] and runs everything due now. */
    fun run(block: (Core) -> Unit) {
        on(block)
        runDue()
    }

    fun runDue() = scheduler.runDue()

    fun advance(ms: Long) = scheduler.advance(ms)

    fun queued(): List<JSONObject> =
        parseObject(store.files[StoreFiles.QUEUE])?.getJSONArray("events")?.objects() ?: emptyList()

    fun state(): JSONObject = JSONObject(store.files[StoreFiles.STATE]!!)

    companion object {
        const val FIXTURE_INSTALL_ID = "4d5e6f7a-8b9c-4d0e-9f1a-2b3c4d5e6f71"
    }
}

internal object Spec {
    val dir: File = File(System.getProperty("kerdly.specDir") ?: "../../spec")

    fun text(fixture: String): String {
        val f = File(dir, "fixtures/$fixture")
        check(f.isFile) { "spec fixture missing: ${f.absolutePath}" }
        return f.readText()
    }

    fun json(fixture: String): JSONObject = JSONObject(text(fixture))
}

internal fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }

internal fun JSONObject.keyList(): Set<String> {
    val out = LinkedHashSet<String>()
    val it = keys()
    while (it.hasNext()) out.add(it.next())
    return out
}

internal fun List<JSONObject>.named(name: String): List<JSONObject> = filter { it.getString("name") == name }

internal fun List<JSONObject>.signal(kind: String): JSONObject? =
    firstOrNull { it.getString("name") == EventNames.SIGNAL && it.getJSONObject("props").optString("kind") == kind }
