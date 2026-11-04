package com.kerdly.sdk.internal

import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/** Device facts for the batch `context`, as the platform reports them. */
internal class DeviceContext(
    val os: String?,
    val model: String?,
    val manufacturer: String?,
    /** `en_US` style (see [LocaleFormat.identifier]). */
    val locale: String?,
    /** BCP-47 tags, at most 5. */
    val languages: List<String>,
    val tz: String?,
    val screenW: Int?,
    val screenH: Int?,
    val scale: Double?,
    /** A Firebase Test Lab or Play pre-launch report device ([TestLab]); sent only when true. */
    val testLab: Boolean = false,
) {
    companion object {
        /** A failed read: the snapshot still says `android`, `not_applicable` and the app version. */
        val UNKNOWN = DeviceContext(null, null, null, null, emptyList(), null, null, null, null)
    }
}

/** Firebase Test Lab, and the Play pre-launch report that runs on it, set the system setting
 * `firebase.test.lab` to `"true"` on its devices. */
internal object TestLab {
    const val SETTING = "firebase.test.lab"

    /** [read] returns the setting (`Settings.System.getString`); anything but `"true"`, or a
     * failed read, is not a test device. */
    fun detect(read: () -> String?): Boolean = try {
        read() == "true"
    } catch (t: Throwable) {
        false
    }
}

internal object ContextJson {
    // The collector rejects the whole batch (400) when a context string is over its limit, so
    // device strings are cut to it here.
    private const val MAX_DEVICE = 64
    private const val MAX_APP = 32

    /** The batch `context`. */
    fun build(
        device: DeviceContext,
        analytics: Boolean,
        ads: Boolean,
        lat: Boolean?,
        appVersion: String?,
        appBuild: String?,
    ): JSONObject = fields(device, appVersion, appBuild) { o ->
        o.put("consent", JSONObject().put("analytics", analytics).put("ads", ads))
        if (lat != null) o.put("lat", lat)
    }

    /** The `$install` `device` snapshot: the context's device and app fields,
     * built by the same code, without `consent` and `lat`. */
    fun device(device: DeviceContext, appVersion: String?, appBuild: String?): JSONObject =
        fields(device, appVersion, appBuild) {}

    private inline fun fields(
        device: DeviceContext,
        appVersion: String?,
        appBuild: String?,
        beforeApp: (JSONObject) -> Unit,
    ): JSONObject {
        val o = JSONObject()
            .put("platform", "android")
            .putNullable("os", device.os?.take(MAX_DEVICE))
            .putNullable("model", device.model?.take(MAX_DEVICE))
            .putNullable("manufacturer", device.manufacturer?.take(MAX_DEVICE))
            .putNullable("locale", device.locale?.take(MAX_DEVICE))
            .put("languages", JSONArray(device.languages.map { it.take(MAX_DEVICE) }.take(5)))
            .putNullable("tz", device.tz?.take(MAX_DEVICE))
        if (device.screenW != null && device.screenH != null) {
            val screen = JSONObject().put("w", device.screenW).put("h", device.screenH)
            device.scale?.let { screen.put("scale", it) }
            o.put("screen", screen)
        }
        o.put("att", "not_applicable")
        if (device.testLab) o.put("test_lab", true)
        beforeApp(o)
        o.putNullable("app_version", appVersion?.take(MAX_APP))
        o.putNullable("app_build", appBuild?.take(MAX_APP))
        return o
    }

    /** Portrait pixels (rotation must not look like a context change) and the density, rounded. */
    fun screen(widthPx: Int, heightPx: Int, density: Float): Triple<Int, Int, Double>? {
        if (widthPx <= 0 || heightPx <= 0) return null
        val scale = if (density > 0f && density.isFinite()) (density.toDouble() * 10_000).roundToLong() / 10_000.0 else 1.0
        return Triple(min(widthPx, heightPx), max(widthPx, heightPx), scale)
    }
}

internal object LocaleFormat {
    /** `Locale.current.identifier` style, as iOS reports it: `language[-Script][_REGION]`, e.g.
     * `es-US` → `es_US`, `zh-Hant-TW` → `zh-Hant_TW`. Null for an undetermined locale. */
    fun identifier(languageTag: String?): String? {
        if (languageTag.isNullOrBlank()) return null
        val parts = languageTag.trim().replace('_', '-').split('-').filter { it.isNotEmpty() }
        if (parts.isEmpty()) return null
        val language = parts[0].lowercase(Locale.ROOT)
        if (language == "und" || !language.all { it in 'a'..'z' }) return null
        var i = 1
        var script: String? = null
        var region: String? = null
        if (i < parts.size && parts[i].length == 4 && parts[i].all { it.isLetter() }) {
            script = parts[i].lowercase(Locale.ROOT).replaceFirstChar { it.titlecase(Locale.ROOT) }
            i++
        }
        if (i < parts.size) {
            val p = parts[i]
            if ((p.length == 2 && p.all { it.isLetter() }) || (p.length == 3 && p.all { it.isDigit() })) {
                region = p.uppercase(Locale.ROOT)
            }
        }
        return buildString {
            append(language)
            if (script != null) append('-').append(script)
            if (region != null) append('_').append(region)
        }
    }

    /** Preferred languages as BCP-47 tags, deduplicated, at most 5. */
    fun languages(tags: List<String>): List<String> =
        tags.map { it.trim() }.filter { it.isNotEmpty() && it != "und" }.distinct().take(5)
}
