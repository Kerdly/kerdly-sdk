package com.kerdly.sdk.internal

import java.util.Locale

/** Play Install Referrer response codes (`InstallReferrerClient.InstallReferrerResponse`) and
 * what each one means for the SDK. */
internal object PlayReferrerCodes {
    const val SERVICE_DISCONNECTED = -1
    const val OK = 0
    const val SERVICE_UNAVAILABLE = 1
    const val FEATURE_NOT_SUPPORTED = 2
    const val DEVELOPER_ERROR = 3
    const val PERMISSION_ERROR = 4

    enum class Kind {
        /** Read the details and signal `status: ok`. */
        OK,

        /** Will never work on this install (e.g. not installed from Play): signal `unavailable` once. */
        PERMANENT,

        /** Try again at the next foreground or launch, within 90 days of the install. */
        TRANSIENT,
    }

    fun classify(code: Int): Kind = when (code) {
        OK -> Kind.OK
        FEATURE_NOT_SUPPORTED, DEVELOPER_ERROR, PERMISSION_ERROR -> Kind.PERMANENT
        else -> Kind.TRANSIENT // SERVICE_UNAVAILABLE, SERVICE_DISCONNECTED and anything new
    }
}

/** `ReferrerDetails`, with Play's 0 ("unknown") timestamps turned into null. Seconds. */
internal class PlayReferrerDetails(
    val referrer: String,
    val clickTs: Long?,
    val installBeginTs: Long?,
    val clickServerTs: Long?,
    val installBeginServerTs: Long?,
    val installVersion: String?,
    val instant: Boolean?,
) {
    companion object {
        fun of(
            referrer: String?,
            clickTs: Long,
            installBeginTs: Long,
            clickServerTs: Long,
            installBeginServerTs: Long,
            installVersion: String?,
            instant: Boolean,
        ) = PlayReferrerDetails(
            referrer = referrer ?: "",
            clickTs = clickTs.takeIf { it > 0 },
            installBeginTs = installBeginTs.takeIf { it > 0 },
            clickServerTs = clickServerTs.takeIf { it > 0 },
            installBeginServerTs = installBeginServerTs.takeIf { it > 0 },
            installVersion = installVersion?.takeIf { it.isNotEmpty() },
            instant = instant,
        )
    }
}

internal sealed class PlayReferrerResult {
    class Ok(val details: PlayReferrerDetails) : PlayReferrerResult()
    class Permanent(val code: Int) : PlayReferrerResult()
    class Transient(val reason: String) : PlayReferrerResult()
}

/** One row read from a Meta app's install-referrer content provider. */
internal class MetaReferrerRow(
    /** `facebook` | `instagram` | `facebook_lite`. */
    val source: String,
    val installReferrer: String?,
    /** 1 click, 0 view. */
    val isCt: Int?,
    /** Seconds. */
    val actualTimestamp: Long?,
)

/** Meta Install Referrer: the providers, and the pick among their rows. */
internal object MetaReferrer {
    /** `source` → content-provider authority, in the order they are queried. */
    val PROVIDERS: List<Pair<String, String>> = listOf(
        "facebook" to "com.facebook.katana.provider.InstallReferrerProvider",
        "instagram" to "com.instagram.contentprovider.InstallReferrerProvider",
        "facebook_lite" to "com.facebook.lite.provider.InstallReferrerProvider",
    )

    val COLUMNS: Array<String> = arrayOf("install_referrer", "is_ct", "actual_timestamp")

    private val APP_ID = Regex("^[0-9]{1,32}$")

    /** Facebook app ids are numeric; anything else would build a bogus provider path. */
    fun isValidAppId(appId: String): Boolean = APP_ID.matches(appId)

    fun uri(authority: String, appId: String): String = "content://$authority/$appId"

    /** The freshest row with a referrer (by `actual_timestamp`; ties keep provider order). */
    fun freshest(rows: List<MetaReferrerRow>): MetaReferrerRow? =
        rows.filter { !it.installReferrer.isNullOrEmpty() }
            .maxWithOrNull(compareBy { it.actualTimestamp ?: Long.MIN_VALUE })

    /** `is_ct` as the collector takes it: 0 or 1, else null. Providers may answer an int or a string. */
    fun isCt(raw: Any?): Int? {
        val n = when (raw) {
            is Number -> raw.toLong()
            is String -> raw.trim().toLongOrNull()
            else -> null
        }
        return if (n == 0L || n == 1L) n.toInt() else null
    }

    /** `actual_timestamp` in seconds; non-positive or unreadable is null. */
    fun timestamp(raw: Any?): Long? {
        val n = when (raw) {
            is Number -> raw.toLong()
            is String -> raw.trim().toLongOrNull()
            else -> null
        }
        return n?.takeIf { it > 0 }
    }
}

internal class AdIdResult(val gaid: String?, val lat: Boolean)

internal object AdIds {
    /** Limit-ad-tracking on, or a zeroed / missing id (the user deleted it) → no GAID, `lat: true`. */
    fun normalize(id: String?, limitAdTracking: Boolean): AdIdResult {
        val zeroed = id.isNullOrBlank() || id.all { it == '0' || it == '-' }
        return if (limitAdTracking || zeroed) {
            AdIdResult(null, true)
        } else {
            AdIdResult(id!!.trim().lowercase(Locale.ROOT), false)
        }
    }
}
