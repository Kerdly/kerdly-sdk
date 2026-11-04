package com.kerdly.sdk.internal

import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** The config's `ddl` block. Android asks TikTok only: for Meta, the Play
 * referrer and Meta's Install Referrer already name the ad. The host is the SDK's own. */
internal class DdlConfig(
    val enabled: Boolean,
    val maxAgeMs: Long,
    /** TikTok Events Manager's App ID; null = TikTok is not asked. */
    val tiktokAppId: String?,
    /** What the Business SDK sends as `app.id`: the package. */
    val storeAppId: String?,
) {
    companion object {
        const val DEFAULT_MAX_AGE_H = 47.0

        /** Null when the block is absent; ages are clamped to 1–168 h. */
        fun fromJson(o: JSONObject?): DdlConfig? {
            if (o == null) return null
            val hours = (o.opt("max_age_h") as? Number)?.toDouble()?.takeIf { it.isFinite() } ?: DEFAULT_MAX_AGE_H
            val tiktok = o.optJSONObject("tiktok")
            return DdlConfig(
                enabled = o.boolOrNull("enabled") ?: false,
                maxAgeMs = (hours.coerceIn(1.0, 168.0) * 3_600_000).toLong(),
                tiktokAppId = tiktok?.stringOrNull("app_id")?.takeIf { it.isNotEmpty() },
                storeAppId = tiktok?.stringOrNull("store_app_id")?.takeIf { it.isNotEmpty() },
            )
        }
    }
}

/** One network's answer to a deferred-deep-link request. */
internal class DdlAnswer(
    val network: String,
    /** `link` | `none` | `error`. */
    val status: String,
    val url: String?,
    val httpStatus: Int?,
    val detail: String?,
) {
    /** No answer, a 429 or a 5xx: worth asking again. Any other answer, a refusal included, is final. */
    val transient: Boolean
        get() = status == "error" && (httpStatus == null || httpStatus == 429 || httpStatus >= 500)
}

/** TikTok's deferred-deep-link request, field for field the Business SDK 1.7.0's
 * (`TTRequestBuilder.ddlJson`): unsigned JSON with the GAID and the raw Play referrer, which
 * TikTok decodes on its side. */
internal object TikTokDdl {
    const val NETWORK = "tiktok"
    const val URL = "https://analytics.us.tiktok.com/api/v1/app_sdk/ddl"

    fun request(
        tiktokAppId: String,
        storeAppId: String?,
        app: AppInfo,
        device: DeviceContext,
        gaid: String?,
        referrer: String?,
        userAgent: String?,
        nowMs: Long,
    ): HttpRequest {
        val appJson = JSONObject()
            .put("namespace", app.bundle)
            .putNullable("version", app.version)
            .putNullable("build", app.build)
            .put("tiktok_app_id", tiktokAppId)
            .put("app_session_id", "")
        if (storeAppId != null) appJson.put("id", storeAppId)
        val deviceJson = JSONObject()
            .put("platform", "Android")
            .putNullable("os_version", device.os)
            .putNullable("locale", device.languages.firstOrNull())
            .putNullable("screen_width", device.screenW)
            .putNullable("screen_height", device.screenH)
        if (gaid != null) deviceJson.put("gaid", gaid)
        val context = JSONObject().put("app", appJson).put("device", deviceJson).put("user", JSONObject())
        if (!referrer.isNullOrEmpty()) context.put("ad", JSONObject().put("gp_referrer", referrer))
        val body = JSONObject()
            .put("tiktok_app_id", tiktokAppId)
            .put("context", context)
            .put("timestamp", iso8601(nowMs))
            .put("ip", "")
        if (userAgent != null) body.put("user_agent", userAgent)
        return HttpRequest("POST", URL, mapOf("Content-Type" to "application/json"), body.toString().toByteArray(Charsets.UTF_8))
    }

    /** `{"code": 0, "data": {"ddl": "<url>"}}`; any other code is an error. */
    fun parse(response: HttpResponse): DdlAnswer {
        val o = parseObject(response.body)
        val code = o?.intOrNull("code")
        if (response.status != 200 || code != 0) {
            val message = o?.stringOrNull("message")?.let { "${code ?: "?"} $it" }
            return DdlAnswer(NETWORK, "error", null, response.status, message ?: response.body.take(300))
        }
        val link = o.optJSONObject("data")?.stringOrNull("ddl")?.takeIf { it.isNotEmpty() }
        return if (link != null) DdlAnswer(NETWORK, "link", link, response.status, null)
        else DdlAnswer(NETWORK, "none", null, response.status, response.body.take(300))
    }

    private fun iso8601(ms: Long): String {
        val f = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        f.timeZone = TimeZone.getTimeZone("UTC")
        return f.format(Date(ms))
    }
}
