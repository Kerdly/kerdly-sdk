package com.kerdly.sdk.internal

import org.json.JSONObject

/** `GET /v1/sdk/config`, with defaults for every missing or malformed field.
 * The `skan` block is iOS-only and ignored here. */
internal class RemoteConfig(
    val version: Int? = null,
    /** Kill switch: false → send nothing, keep collecting reserved events. */
    val enabled: Boolean = true,
    /** Kerdly is off for this app version: record, collect and send nothing. */
    val off: Boolean = false,
    val maxBatch: Int = BatchBody.MAX_EVENTS,
    val queueFlushAt: Int = 20,
    val intervalS: Int = 15,
    val blocked: Set<String> = emptySet(),
    val collectAdvertisingId: Boolean = true,
    val collectInstallReferrer: Boolean = true,
    val collectMetaInstallReferrer: Boolean = true,
    val collectPurchases: Boolean = true,
    val collectPublicIp: Boolean = true,
    /** Where the public IPv6 is looked up; only an `https` URL replaces the default. */
    val ipv6EchoUrl: String = PublicIp.DEFAULT_ECHO_URL,
    /** Deferred deep links; null = off. */
    val ddl: DdlConfig? = null,
    val minSupportedSdk: String? = null,
    val debugDevices: Set<String> = emptySet(),
) {
    companion object {
        val DEFAULT = RemoteConfig()

        fun parse(text: String?): RemoteConfig? = parseObject(text)?.let(::fromJson)

        fun fromJson(o: JSONObject): RemoteConfig {
            val flush = o.optJSONObject("flush")
            val events = o.optJSONObject("events")
            val collect = o.optJSONObject("collect")
            fun flag(key: String): Boolean = collect?.boolOrNull(key) ?: true
            return RemoteConfig(
                version = o.intOrNull("version"),
                enabled = o.boolOrNull("enabled") ?: true,
                off = o.boolOrNull("off") ?: false,
                maxBatch = (flush?.intOrNull("max_batch") ?: BatchBody.MAX_EVENTS).coerceIn(1, BatchBody.MAX_EVENTS),
                queueFlushAt = (flush?.intOrNull("queue_flush_at") ?: 20).coerceIn(1, 1_000),
                intervalS = (flush?.intOrNull("interval_s") ?: 15).coerceIn(1, 3_600),
                blocked = events?.optJSONArray("block")?.strings()?.toHashSet() ?: emptySet(),
                collectAdvertisingId = flag("advertising_id"),
                collectInstallReferrer = flag("install_referrer"),
                collectMetaInstallReferrer = flag("meta_install_referrer"),
                collectPurchases = flag("purchases"),
                collectPublicIp = flag("public_ip"),
                ipv6EchoUrl = PublicIp.echoUrl(o.stringOrNull("ipv6_echo_url")),
                ddl = DdlConfig.fromJson(o.optJSONObject("ddl")),
                minSupportedSdk = o.stringOrNull("min_supported_sdk"),
                debugDevices = o.optJSONArray("debug_devices")?.strings()?.map { it.lowercase() }?.toHashSet() ?: emptySet(),
            )
        }
    }
}

/** The config as cached on the device: `config.json` = `{etag, fetched_at, config}`. */
/**
 * The cached config. [appVersion] is the app version it was fetched for: Kerdly resolves the config
 * per version, so after an app update the copy is fetched again. Null in a cache
 * written before the field existed.
 */
internal class ConfigCache(val etag: String?, val fetchedAt: Long?, val raw: JSONObject?, val appVersion: String? = null) {
    val config: RemoteConfig? = raw?.let(RemoteConfig::fromJson)

    fun serialize(): String =
        JSONObject().putNullable("etag", etag).putNullable("fetched_at", fetchedAt).putNullable("config", raw)
            .putNullable("app_version", appVersion).toString()

    companion object {
        val EMPTY = ConfigCache(null, null, null)

        fun parse(text: String?): ConfigCache {
            val o = parseObject(text) ?: return EMPTY
            val raw = o.optJSONObject("config") ?: return EMPTY
            return ConfigCache(o.stringOrNull("etag"), o.longOrNull("fetched_at"), raw, o.stringOrNull("app_version"))
        }
    }
}

internal object Semver {
    /** Numeric `major.minor.patch` comparison; pre-release and build suffixes are ignored. */
    fun compare(a: String, b: String): Int {
        val pa = parts(a)
        val pb = parts(b)
        for (i in 0 until maxOf(pa.size, pb.size)) {
            val x = pa.getOrElse(i) { 0 }
            val y = pb.getOrElse(i) { 0 }
            if (x != y) return x.compareTo(y)
        }
        return 0
    }

    private fun parts(v: String): List<Int> =
        v.trim().removePrefix("v").substringBefore('-').substringBefore('+').split('.').map { it.toIntOrNull() ?: 0 }
}
