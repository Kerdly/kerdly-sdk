package com.kerdly.sdk.internal

import com.kerdly.sdk.KerdlyDeepLink
import com.kerdly.sdk.KerdlyNetworkSend
import com.kerdly.sdk.KerdlyPurchase
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import kotlin.math.abs

/** Reserved event names. */
internal object EventNames {
    const val INSTALL = "\$install"
    const val OPEN = "\$open"
    const val SIGNAL = "\$signal"
    const val DEEPLINK = "\$deeplink"
    const val IDENTIFY = "\$identify"
    const val CONSENT = "\$consent"
    const val IDS = "\$ids"
    const val PURCHASE_LINK = "\$purchase_link"
    const val SKAN = "\$skan"
    const val NETWORK_SEND = "\$network_send"

    /** What is still recorded with `analytics == false`. */
    val ANALYTICS_OFF_ALLOWED = setOf(INSTALL, OPEN, SIGNAL, CONSENT, IDENTIFY, IDS, PURCHASE_LINK, SKAN)

    fun isReserved(name: String): Boolean = name.startsWith("$")
}

internal class SanitizedProps(val json: JSONObject, val dropped: List<String>)

/** Custom events: names and keys `[a-z][a-z0-9_]{0,39}`, at most 25 props,
 * values strings (cut at 256 chars), finite numbers or booleans. A bad name drops the event;
 * a bad key or value drops only that prop. */
internal object CustomEvents {
    private val NAME = Regex("^[a-z][a-z0-9_]{0,39}$")
    const val MAX_PROPS = 25
    const val MAX_STRING = 256

    fun isValidName(name: String): Boolean = NAME.matches(name)

    fun sanitize(props: Map<String, Any?>): SanitizedProps {
        val json = JSONObject()
        val dropped = ArrayList<String>()
        append(json, props, dropped)
        return SanitizedProps(json, dropped)
    }

    /** Adds [props] to [json] under the custom rules, skipping [skip]; what is already in
     * [json] counts toward the 25. */
    fun append(json: JSONObject, props: Map<String, Any?>, dropped: MutableList<String>, skip: Set<String> = emptySet()) {
        var count = json.length()
        for ((key, raw) in props) {
            if (key in skip) continue
            if (!NAME.matches(key)) {
                dropped += "$key (invalid key)"
                continue
            }
            val value = normalize(raw)
            if (value == null) {
                dropped += "$key (unsupported value)"
                continue
            }
            if (count >= MAX_PROPS) {
                dropped += "$key (over $MAX_PROPS props)"
                continue
            }
            json.put(key, value)
            count++
        }
    }

    /** A JSON-safe value, or null when the type is not allowed (null, NaN and ∞ included). */
    fun normalize(value: Any?): Any? = when (value) {
        null -> null
        is String -> truncate(value, MAX_STRING)
        is Boolean -> value
        is Int -> value.toLong()
        is Long -> value
        is Short -> value.toLong()
        is Byte -> value.toLong()
        is Double -> value.takeIf { it.isFinite() }
        // Float → its shortest decimal form, so 0.1f is 0.1 rather than 0.10000000149011612.
        is Float -> value.takeIf { it.isFinite() }?.toString()?.toDouble()
        is Number -> value.toDouble().takeIf { it.isFinite() }
        else -> null
    }

    /** Cuts at [max] UTF-16 units without splitting a surrogate pair. */
    fun truncate(s: String, max: Int): String {
        if (s.length <= max) return s
        var end = max
        if (Character.isHighSurrogate(s[end - 1])) end--
        return s.substring(0, end)
    }
}

/** Standard events: ordinary names whose typed props are checked the same way
 * whether they come from the typed methods or from `track`. Other props follow the custom
 * rules; the typed ones count toward the 25. A bad typed prop drops only that prop. */
internal object StandardEvents {
    const val REGISTRATION = "registration"
    const val START_TRIAL = "start_trial"
    const val SUBSCRIBE = "subscribe"
    const val PURCHASE = "purchase"

    const val MAX_ID = 128
    const val MAX_METHOD = 64
    private val CURRENCY = Regex("^[A-Z]{3}$")
    /** 2^53: beyond it a double no longer holds every integer. */
    private const val MAX_EXACT_DOUBLE = 9_007_199_254_740_992.0

    private val MONEY = listOf("product_id", "value", "currency", "transaction_id")

    /** Each standard event's typed keys. */
    val TYPED_KEYS: Map<String, List<String>> = mapOf(
        REGISTRATION to listOf("method"),
        START_TRIAL to MONEY,
        SUBSCRIBE to MONEY,
        PURCHASE to listOf("product_id", "value", "currency", "quantity", "transaction_id"),
    )

    /** The typed methods' arguments, as props. */
    fun registration(method: String?): Map<String, Any?> = linkedMapOf("method" to method)

    fun money(productId: String?, value: Double?, currency: String?, transactionId: String?, quantity: Int? = null): Map<String, Any?> {
        val m = linkedMapOf<String, Any?>("product_id" to productId, "value" to value, "currency" to currency)
        if (quantity != null) m["quantity"] = quantity
        m["transaction_id"] = transactionId
        return m
    }

    /** A typed method's props: its non-null [args] first, then [properties]. A key an argument
     * set is never taken from [properties]; those keys come back as the second value. */
    fun merge(args: Map<String, Any?>, properties: Map<String, Any?>): Pair<Map<String, Any?>, List<String>> {
        val merged = LinkedHashMap<String, Any?>()
        for ((k, v) in args) if (v != null) merged[k] = v
        val ignored = ArrayList<String>()
        for ((k, v) in properties) {
            if (k in merged) ignored += k else merged[k] = v
        }
        return merged to ignored
    }

    /** Props of an event named [name]: the typed checks for a standard name, then the custom
     * rules for the rest (only the custom rules for any other name). */
    fun sanitize(name: String, props: Map<String, Any?>): SanitizedProps {
        val typedKeys = TYPED_KEYS[name] ?: return CustomEvents.sanitize(props)
        val json = JSONObject()
        val dropped = ArrayList<String>()
        for (key in typedKeys) {
            if (!props.containsKey(key)) continue
            val value = typed(key, props[key])
            if (value == null) dropped += "$key (${problem(key)})" else json.put(key, value)
        }
        // A value without a currency means nothing to a network.
        if (json.has("value") && !json.has("currency")) {
            json.remove("value")
            dropped += "value (no valid currency)"
        }
        CustomEvents.append(json, props, dropped, skip = typedKeys.toSet())
        return SanitizedProps(json, dropped)
    }

    private fun typed(key: String, raw: Any?): Any? = when (key) {
        "product_id", "transaction_id" -> (raw as? String)?.let { CustomEvents.truncate(it, MAX_ID) }
        "method" -> (raw as? String)?.let { CustomEvents.truncate(it, MAX_METHOD) }
        "currency" -> (raw as? String)?.trim()?.uppercase(Locale.ROOT)?.takeIf { CURRENCY.matches(it) }
        "value" -> number(raw)?.takeIf { it.toDouble() >= 0 }
        "quantity" -> wholeNumber(raw)?.takeIf { it >= 1 }
        else -> null
    }

    /** A finite number, as [CustomEvents.normalize] writes it; null for anything else. */
    private fun number(raw: Any?): Number? = if (raw is Number) CustomEvents.normalize(raw) as? Number else null

    /** An integral number (2 and 2.0, not 2.5) as a Long; null otherwise. */
    private fun wholeNumber(raw: Any?): Long? = when (val n = number(raw)) {
        is Long -> n
        is Double -> n.takeIf { it % 1.0 == 0.0 && abs(it) <= MAX_EXACT_DOUBLE }?.toLong()
        else -> null
    }

    private fun problem(key: String): String = when (key) {
        "product_id", "transaction_id", "method" -> "not a string"
        "currency" -> "not a three-letter ISO 4217 code"
        "value" -> "not a finite number ≥ 0"
        "quantity" -> "not an integer ≥ 1"
        else -> "invalid"
    }
}

/** Props of the SDK's own events. */
internal object ReservedProps {
    const val MAX_PRODUCTS = 20

    /** [device] is [ContextJson.device], taken at enqueue. */
    fun install(installedAt: Long?, firstLaunchAt: Long, installer: String?, initialUrl: String?, device: JSONObject): JSONObject =
        JSONObject()
            .put("install_state", "fresh")
            .putNullable("installed_at", installedAt)
            .putNullable("installed_at_source", if (installedAt != null) "package_manager" else null)
            .put("first_launch_at", firstLaunchAt)
            .putNullable("installer", installer)
            .putNullable("initial_url", initialUrl)
            .put("device", device)

    fun open(reason: String): JSONObject = JSONObject().put("reason", reason)

    fun deeplink(link: KerdlyDeepLink, source: String): JSONObject =
        JSONObject()
            .put("url", CustomEvents.truncate(link.url, DeepLinks.MAX_URL_CHARS))
            .put("source", source)
            .putNullable("cpp", link.cpp)
            .putNullable("ppid", link.ppid)
            .putNullable("afr_c", link.afrC)
            .putNullable("afr_v", link.afrV)
            .putNullable("campaign_ids", link.campaignIds)

    fun identify(userId: String?, previousUserId: String?): JSONObject =
        JSONObject().putNullable("user_id", userId).putNullable("previous_user_id", previousUserId)

    fun consent(analytics: Boolean, ads: Boolean): JSONObject =
        JSONObject().put("att", "not_applicable").put("analytics", analytics).put("ads", ads)

    fun ids(appAccountToken: String?, partner: Map<String, String>): JSONObject {
        val p = JSONObject()
        for ((k, v) in partner) p.put(k, v)
        return JSONObject().putNullable("app_account_token", appAccountToken).put("partner", p)
    }

    fun purchaseLink(purchase: KerdlyPurchase): JSONObject =
        JSONObject()
            .put("store", "play_store")
            .put("purchase_token", purchase.purchaseToken)
            .putNullable("order_id", purchase.orderId)
            .put("products", JSONArray(purchase.products.filter { it.isNotEmpty() }.take(MAX_PRODUCTS)))
            .putNullable("purchase_time", purchase.purchaseTime?.takeIf { it > 0 })
            .putNullable("obfuscated_account_id", purchase.obfuscatedAccountId)
            .putNullable("obfuscated_profile_id", purchase.obfuscatedProfileId)
            .put("source", "notify")

    fun networkSend(send: KerdlyNetworkSend): JSONObject =
        JSONObject()
            .put("network", send.network)
            .put("event", send.event)
            .putNullable("event_id", send.eventId)
            .putNullable("value", send.value?.takeIf { it.isFinite() })
            .putNullable("currency", send.currency)
            .putNullable("flag", send.flag)
}

/** `$signal` props (Android kinds). */
internal object Signals {
    fun installReferrerOk(d: PlayReferrerDetails): JSONObject =
        JSONObject()
            .put("kind", "install_referrer")
            .put("status", "ok")
            .put("response_code", JSONObject.NULL)
            .put("referrer", d.referrer)
            .putNullable("click_ts", d.clickTs)
            .putNullable("install_begin_ts", d.installBeginTs)
            .putNullable("click_server_ts", d.clickServerTs)
            .putNullable("install_begin_server_ts", d.installBeginServerTs)
            .putNullable("install_version", d.installVersion)
            .putNullable("instant", d.instant)

    fun installReferrerUnavailable(responseCode: Int): JSONObject =
        JSONObject()
            .put("kind", "install_referrer")
            .put("status", "unavailable")
            .put("response_code", responseCode)
            .put("referrer", "")
            .put("click_ts", JSONObject.NULL)
            .put("install_begin_ts", JSONObject.NULL)
            .put("click_server_ts", JSONObject.NULL)
            .put("install_begin_server_ts", JSONObject.NULL)
            .put("install_version", JSONObject.NULL)
            .put("instant", JSONObject.NULL)

    fun advertisingIds(gaid: String?, lat: Boolean): JSONObject =
        JSONObject().put("kind", "advertising_ids").putNullable("gaid", gaid).put("lat", lat)

    /** [ipv6] is already [PublicIp.globalIpv6]'s canonical text. */
    fun publicIp(ipv6: String): JSONObject = JSONObject().put("kind", "public_ip").put("ipv6", ipv6)

    /** One network's deferred-deep-link answer, with the params [DeepLinks] reads from it. */
    fun deferredLink(answer: DdlAnswer, attempt: Int): JSONObject {
        val parsed = answer.url?.let(DeepLinks::parse)
        return JSONObject()
            .put("kind", "deferred_link")
            .put("network", answer.network)
            .put("status", answer.status)
            .putNullable("url", answer.url?.take(DeepLinks.MAX_URL_CHARS))
            .put("click_ts", JSONObject.NULL)
            .putNullable("cpp", parsed?.cpp)
            .putNullable("ppid", parsed?.ppid)
            .putNullable("afr_c", parsed?.afrC)
            .putNullable("afr_v", parsed?.afrV)
            .putNullable("campaign_ids", parsed?.campaignIds)
            .putNullable("http_status", answer.httpStatus)
            .putNullable("detail", answer.detail?.take(300))
            .put("attempt", attempt)
            .put("att", "not_applicable")
    }

    fun metaInstallReferrer(row: MetaReferrerRow): JSONObject =
        JSONObject()
            .put("kind", "meta_install_referrer")
            .put("source", row.source)
            .put("install_referrer", row.installReferrer ?: "")
            .putNullable("is_ct", row.isCt)
            .putNullable("actual_timestamp", row.actualTimestamp)
}
