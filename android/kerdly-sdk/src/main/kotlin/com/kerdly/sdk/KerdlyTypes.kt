package com.kerdly.sdk

/** `app.environment` of every batch. [AUTO]: `development` when the app is
 * debuggable (`ApplicationInfo.FLAG_DEBUGGABLE`), else `production`. */
enum class KerdlyEnvironment { AUTO, PRODUCTION, SANDBOX, DEVELOPMENT }

/** Logcat verbosity. Messages are prefixed `[Kerdly]`; keys and full advertising
 * ids are never logged. */
enum class KerdlyLogLevel { NONE, ERROR, WARN, INFO, DEBUG }

/** Options for [Kerdly.configure]. */
data class KerdlyOptions @JvmOverloads constructor(
    /** The app's public key, `pk_live_…` / `pk_test_…`. */
    val key: String,
    /** Base URL; `/v1/sdk/batch` etc. are appended. Default: [DEFAULT_ENDPOINT]. */
    val endpoint: String = DEFAULT_ENDPOINT,
    val environment: KerdlyEnvironment = KerdlyEnvironment.AUTO,
    /** Read the Google advertising id (never when limit-ad-tracking is on or `ads` consent is off). */
    val collectAdvertisingId: Boolean = true,
    /** Facebook app id; enables the Meta Install Referrer read (once per install). */
    val metaAppId: String? = null,
    val logLevel: KerdlyLogLevel = KerdlyLogLevel.WARN,
    /** Set by wrappers such as the Expo bridge, e.g. `expo/0.1.0`. */
    val wrapper: String? = null,
) {
    override fun toString(): String =
        "KerdlyOptions(key=${key.take(8)}…, endpoint=$endpoint, environment=$environment, " +
            "collectAdvertisingId=$collectAdvertisingId, metaAppId=$metaAppId, logLevel=$logLevel, wrapper=$wrapper)"

    companion object {
        /** The Kerdly collector. */
        const val DEFAULT_ENDPOINT: String = "https://app.kerdly.com/api"
    }
}

/** What [Kerdly.handleUrl] parsed from a URL's query string. */
data class KerdlyDeepLink(
    val url: String,
    val cpp: String?,
    val ppid: String?,
    /** The click id of the Kerdly link that opened the app (`kerdly_c`). */
    val clickId: String?,
    /** The web visit that link continues (`kerdly_v`). */
    val visitId: String?,
    val campaignIds: String?,
)

/** A Google Play purchase as the paywall reports it (`$purchase_link`). */
data class KerdlyPurchase @JvmOverloads constructor(
    val purchaseToken: String,
    val orderId: String? = null,
    val products: List<String> = emptyList(),
    /** Milliseconds since the epoch. */
    val purchaseTime: Long? = null,
    val obfuscatedAccountId: String? = null,
    val obfuscatedProfileId: String? = null,
)

/** An event the app itself sent to an ad network (`$network_send`). */
data class KerdlyNetworkSend @JvmOverloads constructor(
    val network: String,
    val event: String,
    val eventId: String? = null,
    val value: Double? = null,
    val currency: String? = null,
    val flag: String? = null,
)

/** The install's attribution as the collector decided it. [raw] is the whole
 * JSON object. */
data class KerdlyAttribution(
    val state: String,
    val network: String,
    val status: String,
    val method: String,
    val campaignId: String?,
    val campaign: String?,
    val adsetId: String?,
    val adset: String?,
    val adId: String?,
    val ad: String?,
    val keywordId: String?,
    val keyword: String?,
    val linkId: String?,
    val cppId: String?,
    /** Milliseconds since the epoch. */
    val decidedAt: Long?,
    val raw: String,
)
