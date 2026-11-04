package com.kerdly.sdk.internal

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID

/** Files in one directory, each replaced atomically (write a temp file, fsync, rename). On
 * Android the directory is `noBackupFilesDir/afr/`, which Auto Backup never copies, so a
 * restore cannot bring back an old install id. */
internal class FileStore(private val dir: File) : Store {
    override fun read(name: String): String? {
        val f = File(dir, name)
        if (!f.exists()) return null
        return f.readText(Charsets.UTF_8) // throws when it exists but cannot be read
    }

    override fun write(name: String, content: String): Boolean = try {
        if (!dir.isDirectory && !dir.mkdirs() && !dir.isDirectory) throw IOException("cannot create $dir")
        val target = File(dir, name)
        val tmp = File(dir, "$name.tmp")
        FileOutputStream(tmp).use { out ->
            out.write(content.toByteArray(Charsets.UTF_8))
            out.fd.sync()
        }
        if (!tmp.renameTo(target)) {
            target.delete()
            if (!tmp.renameTo(target)) throw IOException("cannot replace $target")
        }
        true
    } catch (e: Exception) {
        false
    }

    override fun delete(name: String) {
        try {
            File(dir, name).delete()
        } catch (_: Exception) {
        }
    }
}

internal object StoreFiles {
    const val INSTALL_ID = "install_id"
    const val QUEUE = "queue.json"
    const val STATE = "state.json"
    const val CONFIG = "config.json"
    const val PENDING_LINKS = "pending_links.json"
    const val PURCHASES = "purchases.json"
    const val ATTRIBUTION = "attribution.json"
}

/** The install id: a lowercase UUIDv4 in its own file, created on the first
 * `configure` of an install and never changed. No file → a new id and `$install fresh`.
 *
 * `configure` only reads (cheap, on the caller's thread); a new id is written by the launch
 * task before anything is sent, so an id that never reached the disk was never used either. */
internal object InstallId {
    private val UUID_PATTERN = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

    class Result(val id: String, val created: Boolean)

    fun isValid(id: String): Boolean = UUID_PATTERN.matches(id)

    fun newId(): String = UUID.randomUUID().toString().lowercase()

    /** Throws when the id file exists but cannot be read: a new id then would fake an install. */
    @Throws(IOException::class)
    fun load(store: Store, newId: () -> String = ::newId): Result {
        val existing = store.read(StoreFiles.INSTALL_ID)?.trim()?.lowercase()
        if (existing != null && isValid(existing)) return Result(existing, created = false)
        return Result(newId(), created = true)
    }

    fun persist(store: Store, id: String): Boolean = store.write(StoreFiles.INSTALL_ID, id)
}

/** Everything the SDK remembers about this install besides the queue (`state.json`). */
internal class SdkState {
    var userId: String? = null
    var analytics: Boolean = true
    var ads: Boolean = true
    var appAccountToken: String? = null
    var partner: Map<String, String> = emptyMap()
    var firstLaunchAt: Long? = null
    var installedAt: Long? = null
    var installEventId: String? = null
    var installAcked: Boolean = false
    var referrerDone: Boolean = false
    var referrerAttempts: Int = 0
    var metaDone: Boolean = false
    var adIdReadAt: Long? = null
    /** sha1 of the last advertising-ids signal sent: a new one goes out only on change. */
    var adIdHash: String? = null
    var lat: Boolean? = null
    /** Deferred deep links: this install's launch enqueued `$install`. */
    var ddlEligible: Boolean = false
    /** TikTok answered, refused, or the SDK gave up after 3 failures in transit. */
    var ddlTiktokDone: Boolean = false
    var ddlTiktokFailures: Int = 0
    /** Play's raw referrer, kept for TikTok's request (it decodes the referrer on its side). */
    var ddlReferrer: String? = null
    /** sha1 of the last context the collector stored (sent in a batch with an accepted event). */
    var contextHash: String? = null
    var retryAttempt: Int = 0
    var retryNextAt: Long = 0
    /** A copy of the queue's counter, so a lost queue file can never make a `seq` repeat. */
    var nextSeq: Long = 1

    fun serialize(installId: String): String {
        val partnerJson = JSONObject()
        for ((k, v) in partner) partnerJson.put(k, v)
        return JSONObject()
            .put("v", 1)
            .put("install_id", installId)
            .putNullable("user_id", userId)
            .put("consent", JSONObject().put("analytics", analytics).put("ads", ads))
            .putNullable("app_account_token", appAccountToken)
            .put("partner", partnerJson)
            .putNullable("first_launch_at", firstLaunchAt)
            .putNullable("installed_at", installedAt)
            .putNullable("install_event_id", installEventId)
            .put("install_acked", installAcked)
            .put("referrer_done", referrerDone)
            .put("referrer_attempts", referrerAttempts)
            .put("meta_done", metaDone)
            .putNullable("ad_id_read_at", adIdReadAt)
            .putNullable("ad_id_hash", adIdHash)
            .putNullable("lat", lat)
            .put("ddl_eligible", ddlEligible)
            .put("ddl_tiktok_done", ddlTiktokDone)
            .put("ddl_tiktok_failures", ddlTiktokFailures)
            .putNullable("ddl_referrer", ddlReferrer)
            .putNullable("context_hash", contextHash)
            .put("retry_attempt", retryAttempt)
            .put("retry_next_at", retryNextAt)
            .put("next_seq", nextSeq)
            .toString()
    }

    companion object {
        /** Null when [text] is absent, unreadable, or belongs to another install id. */
        fun parse(text: String?, installId: String): SdkState? {
            val o = parseObject(text) ?: return null
            if (o.stringOrNull("install_id") != installId) return null
            val s = SdkState()
            s.userId = o.stringOrNull("user_id")
            o.optJSONObject("consent")?.let { c ->
                s.analytics = c.boolOrNull("analytics") ?: true
                s.ads = c.boolOrNull("ads") ?: true
            }
            s.appAccountToken = o.stringOrNull("app_account_token")
            o.optJSONObject("partner")?.let { p ->
                val map = LinkedHashMap<String, String>()
                for (k in p.keys()) p.stringOrNull(k)?.let { map[k] = it }
                s.partner = map
            }
            s.firstLaunchAt = o.longOrNull("first_launch_at")
            s.installedAt = o.longOrNull("installed_at")
            s.installEventId = o.stringOrNull("install_event_id")
            s.installAcked = o.boolOrNull("install_acked") ?: false
            s.referrerDone = o.boolOrNull("referrer_done") ?: false
            s.referrerAttempts = o.intOrNull("referrer_attempts") ?: 0
            s.metaDone = o.boolOrNull("meta_done") ?: false
            s.adIdReadAt = o.longOrNull("ad_id_read_at")
            s.adIdHash = o.stringOrNull("ad_id_hash")
            s.lat = o.boolOrNull("lat")
            s.ddlEligible = o.boolOrNull("ddl_eligible") ?: false
            s.ddlTiktokDone = o.boolOrNull("ddl_tiktok_done") ?: false
            s.ddlTiktokFailures = o.intOrNull("ddl_tiktok_failures") ?: 0
            s.ddlReferrer = o.stringOrNull("ddl_referrer")
            s.contextHash = o.stringOrNull("context_hash")
            s.retryAttempt = o.intOrNull("retry_attempt") ?: 0
            s.retryNextAt = o.longOrNull("retry_next_at") ?: 0
            s.nextSeq = o.longOrNull("next_seq") ?: 1
            return s
        }
    }
}

/** Attribution-bearing `$deeplink` events not yet accepted. Each is re-enqueued,
 * same id, on the next launch until the collector answers for it. Bounded: [MAX] entries,
 * [TTL_MS] old at most. */
internal class PendingLinks {
    class Entry(val addedAt: Long, val event: JSONObject) {
        val id: String? = event.stringOrNull("id")
    }

    private val entries = ArrayList<Entry>()

    fun entries(): List<Entry> = entries

    fun isEmpty(): Boolean = entries.isEmpty()

    fun maxSeq(): Long = entries.maxOfOrNull { it.event.longOrNull("seq") ?: 0 } ?: 0

    fun add(eventJson: String, now: Long) {
        val o = parseObject(eventJson) ?: return
        val entry = Entry(now, o)
        if (entry.id == null || entries.any { it.id == entry.id }) return
        entries.add(entry)
        while (entries.size > MAX) entries.removeAt(0)
    }

    /** True when something was removed. */
    fun remove(ids: Collection<String>): Boolean = entries.removeAll { it.id in ids }

    /** Drops entries older than [TTL_MS] (or from a clock far in the future); true when any went. */
    fun expire(now: Long): Boolean = entries.removeAll { now - it.addedAt > TTL_MS || it.addedAt - now > TTL_MS }

    fun serialize(): String {
        val arr = JSONArray()
        for (e in entries) arr.put(JSONObject().put("added_at", e.addedAt).put("event", e.event))
        return JSONObject().put("v", 1).put("links", arr).toString()
    }

    companion object {
        const val MAX = 20
        const val TTL_MS = 30L * 86_400_000L

        fun parse(text: String?): PendingLinks {
            val p = PendingLinks()
            val arr = parseObject(text)?.optJSONArray("links") ?: return p
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val event = o.optJSONObject("event") ?: continue
                val entry = Entry(o.longOrNull("added_at") ?: 0, event)
                if (entry.id != null) p.entries.add(entry)
            }
            return p
        }
    }
}

/** sha1 of every purchase token already reported as `$purchase_link`. */
internal class ReportedPurchases {
    private val hashes = LinkedHashSet<String>()

    fun contains(hash: String): Boolean = hash in hashes

    fun add(hash: String) {
        hashes.add(hash)
        while (hashes.size > MAX) hashes.remove(hashes.first())
    }

    fun serialize(): String = JSONObject().put("v", 1).put("sha1", JSONArray(hashes.toList())).toString()

    companion object {
        const val MAX = 1_000

        fun tokenHash(purchaseToken: String): String = sha1Hex(purchaseToken)

        fun parse(text: String?): ReportedPurchases {
            val r = ReportedPurchases()
            parseObject(text)?.optJSONArray("sha1")?.strings()?.forEach { r.hashes.add(it) }
            return r
        }
    }
}
