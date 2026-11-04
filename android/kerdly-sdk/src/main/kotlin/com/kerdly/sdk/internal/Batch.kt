package com.kerdly.sdk.internal

import org.json.JSONObject
import kotlin.random.Random

/** `POST /v1/sdk/batch` bodies. */
internal object BatchBody {
    const val MAX_EVENTS = 50
    const val MAX_BODY_BYTES = 256 * 1024
    private const val EVENTS_OVERHEAD = 16 // ,"events":[ … ]

    class Envelope(
        val sdkName: String,
        val sdkVersion: String,
        val wrapper: String?,
        val bundle: String,
        val appVersion: String?,
        val appBuild: String?,
        val environment: String,
        val installId: String,
    )

    /** The batch object without `events` (closed with `}`). */
    fun envelope(e: Envelope, sentAt: Long, context: JSONObject?): String {
        val sdk = JSONObject().put("name", e.sdkName).put("version", e.sdkVersion)
        if (e.wrapper != null) sdk.put("wrapper", e.wrapper)
        val app = JSONObject()
            .put("bundle", e.bundle)
            .putNullable("version", e.appVersion)
            .putNullable("build", e.appBuild)
            .put("environment", e.environment)
        val o = JSONObject()
            .put("sdk", sdk)
            .put("app", app)
            .put("install_id", e.installId)
            .put("sent_at", sentAt)
        if (context != null) o.put("context", context)
        return o.toString()
    }

    /** Budget left for the events once [envelope] is in the body. */
    fun eventBudget(envelope: String): Int = MAX_BODY_BYTES - utf8Length(envelope) - EVENTS_OVERHEAD

    /** The head of the queue that fits: at most [maxCount] events and [maxBytes] of event JSON. */
    fun select(events: List<QueuedEvent>, maxCount: Int, maxBytes: Int): List<QueuedEvent> {
        val out = ArrayList<QueuedEvent>()
        var total = 0
        for (e in events) {
            if (out.size >= maxCount) break
            val add = e.bytes + if (out.isEmpty()) 0 else 1
            if (total + add > maxBytes) break
            out.add(e)
            total += add
        }
        return out
    }

    fun join(envelope: String, events: List<QueuedEvent>): String {
        val sb = StringBuilder(envelope.length + events.sumOf { it.json.length + 1 } + EVENTS_OVERHEAD)
        sb.append(envelope, 0, envelope.length - 1)
        sb.append(",\"events\":[")
        events.forEachIndexed { i, e ->
            if (i > 0) sb.append(',')
            sb.append(e.json)
        }
        sb.append("]}")
        return sb.toString()
    }
}

internal class Rejection(val id: String?, val reason: String)

/** A 200 batch response. */
internal class BatchAck(
    val accepted: List<String>,
    val rejected: List<Rejection>,
    val configEtag: String?,
    val attribution: JSONObject?,
    val needs: List<String>,
)

internal sealed class SendOutcome {
    /** 2xx with a readable body: remove what it accepted and rejected. */
    class Acked(val ack: BatchAck) : SendOutcome()

    /** Drop the batch. [stop]: 401/403 — send nothing more until the next launch. */
    class Drop(val status: Int, val code: String?, val stop: Boolean) : SendOutcome()

    /** 413: halve the batch and retry; a single event that is still too large is dropped. */
    object Split : SendOutcome()

    /** 408, 429, 5xx, a network error ([status] null) or an unreadable answer: back off. */
    class Retry(val status: Int?, val retryAfterMs: Long?) : SendOutcome()
}

internal object BatchResponses {
    /** Retry-After is capped at a day; a bigger value is a broken server, not a plan. */
    const val MAX_RETRY_AFTER_S = 86_400L

    fun classify(status: Int, body: String, retryAfter: String?): SendOutcome = when {
        status in 200..299 -> parseAck(body)?.let { SendOutcome.Acked(it) } ?: SendOutcome.Retry(status, null)
        status == 401 || status == 403 -> SendOutcome.Drop(status, errorCode(body), stop = true)
        status == 408 || status == 429 -> SendOutcome.Retry(status, parseRetryAfter(retryAfter))
        status == 413 -> SendOutcome.Split
        // 400 malformed, and any other 4xx: resending the same bytes cannot succeed.
        status in 400..499 -> SendOutcome.Drop(status, errorCode(body), stop = false)
        status >= 500 -> SendOutcome.Retry(status, parseRetryAfter(retryAfter))
        else -> SendOutcome.Retry(status, null) // 1xx / 3xx: redirects are not followed for POSTs
    }

    fun parseAck(body: String): BatchAck? {
        val o = parseObject(body) ?: return null
        val accepted = o.optJSONArray("accepted")?.strings() ?: emptyList()
        val rejected = ArrayList<Rejection>()
        val rej = o.optJSONArray("rejected")
        if (rej != null) {
            for (i in 0 until rej.length()) {
                val r = rej.optJSONObject(i) ?: continue
                rejected.add(Rejection(r.stringOrNull("id"), r.stringOrNull("reason") ?: "unknown"))
            }
        }
        return BatchAck(
            accepted = accepted,
            rejected = rejected,
            configEtag = o.stringOrNull("config_etag"),
            attribution = o.optJSONObject("attribution"),
            needs = o.optJSONArray("needs")?.strings() ?: emptyList(),
        )
    }

    /** `{"error": …, "code": …}` → code. */
    fun errorCode(body: String): String? = parseObject(body)?.stringOrNull("code")

    /** `Retry-After` in seconds → ms. HTTP-date values are not used by the collector. */
    fun parseRetryAfter(value: String?): Long? {
        val s = value?.trim()?.toLongOrNull() ?: return null
        if (s < 0) return null
        return minOf(s, MAX_RETRY_AFTER_S) * 1000
    }
}

/** Exponential back-off with full jitter from 1 s to 5 min. */
internal object Backoff {
    const val BASE_MS = 1_000L
    const val MAX_MS = 300_000L

    /** The cap for retry number [attempt] (1-based): 1 s, 2 s, 4 s … 5 min. */
    fun capMs(attempt: Int): Long {
        val shift = (attempt - 1).coerceIn(0, 20)
        return minOf(MAX_MS, BASE_MS shl shift)
    }

    /** A uniform delay in [1 s, cap]. */
    fun delayMs(attempt: Int, random: Random): Long {
        val cap = capMs(attempt)
        if (cap <= BASE_MS) return BASE_MS
        return BASE_MS + (random.nextDouble() * (cap - BASE_MS)).toLong()
    }
}
