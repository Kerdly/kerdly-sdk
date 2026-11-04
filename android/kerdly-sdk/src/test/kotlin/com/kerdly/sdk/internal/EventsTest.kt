package com.kerdly.sdk.internal

import com.kerdly.sdk.KerdlyNetworkSend
import com.kerdly.sdk.KerdlyPurchase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigDecimal

class EventsTest {
    @Test
    fun customNames() {
        for (ok in listOf("registration", "a", "trial_start", "step_2", "a" + "b".repeat(39))) {
            assertTrue(ok, CustomEvents.isValidName(ok))
        }
        for (bad in listOf("", "Bad Name", "Registration", "2fa", "_x", "a-b", "\$install", "a" + "b".repeat(40), "é")) {
            assertFalse(bad, CustomEvents.isValidName(bad))
        }
    }

    @Test
    fun propsKeepStringsNumbersAndBooleans() {
        val s = CustomEvents.sanitize(
            linkedMapOf(
                "method" to "anonymous",
                "count" to 3,
                "big" to 9_007_199_254_740_993L,
                "ratio" to 0.25,
                "f" to 0.1f,
                "short" to 7.toShort(),
                "decimal" to BigDecimal("1.5"),
                "ok" to true,
            ),
        )
        assertTrue(s.dropped.isEmpty())
        assertEquals("anonymous", s.json.getString("method"))
        assertEquals(3L, s.json.getLong("count"))
        assertEquals(9_007_199_254_740_993L, s.json.getLong("big"))
        assertEquals(0.25, s.json.getDouble("ratio"), 0.0)
        assertEquals(0.1, s.json.getDouble("f"), 0.0)
        assertEquals(7L, s.json.getLong("short"))
        assertEquals(1.5, s.json.getDouble("decimal"), 0.0)
        assertTrue(s.json.getBoolean("ok"))
    }

    @Test
    fun badKeysAndValuesDropOnlyThatProp() {
        val s = CustomEvents.sanitize(
            linkedMapOf(
                "good" to "x",
                "Bad" to "x",
                "nested" to mapOf("a" to 1),
                "list" to listOf(1),
                "nan" to Double.NaN,
                "inf" to Float.POSITIVE_INFINITY,
                "nothing" to null,
                "char" to 'c',
            ),
        )
        assertEquals(setOf("good"), s.json.keyList())
        assertEquals(7, s.dropped.size)
    }

    @Test
    fun atMost25PropsAndStringsCutAt256() {
        val props = LinkedHashMap<String, Any?>()
        for (i in 0 until 30) props["p$i"] = i
        val s = CustomEvents.sanitize(props)
        assertEquals(25, s.json.length())
        assertTrue(s.json.has("p24"))
        assertFalse(s.json.has("p25"))
        assertEquals(5, s.dropped.size)

        val long = CustomEvents.sanitize(mapOf("s" to "y".repeat(300))).json.getString("s")
        assertEquals(256, long.length)
    }

    @Test
    fun truncationNeverSplitsASurrogatePair() {
        val emoji = "😀" // one code point, two UTF-16 units
        val s = "a".repeat(255) + emoji
        val cut = CustomEvents.truncate(s, 256)
        assertEquals(255, cut.length)
        assertFalse(Character.isHighSurrogate(cut.last()))
    }

    @Test
    fun analyticsOffAllowsOnlyTheAttributionEvents() {
        assertEquals(
            setOf("\$install", "\$open", "\$signal", "\$consent", "\$identify", "\$ids", "\$purchase_link", "\$skan"),
            EventNames.ANALYTICS_OFF_ALLOWED,
        )
        assertFalse(EventNames.DEEPLINK in EventNames.ANALYTICS_OFF_ALLOWED)
        assertFalse(EventNames.NETWORK_SEND in EventNames.ANALYTICS_OFF_ALLOWED)
    }

    @Test
    fun purchaseLinkProps() {
        val p = ReservedProps.purchaseLink(
            KerdlyPurchase(
                purchaseToken = "tok",
                products = listOf("a", "", "b"),
                purchaseTime = 0,
            ),
        )
        assertEquals(setOf("store", "purchase_token", "order_id", "products", "purchase_time", "obfuscated_account_id", "obfuscated_profile_id", "source"), p.keyList())
        assertEquals(2, p.getJSONArray("products").length())
        assertTrue("a non-positive purchase time is unknown", p.isNull("purchase_time"))
        assertTrue(p.isNull("order_id"))
    }

    @Test
    fun networkSendProps() {
        val p = ReservedProps.networkSend(KerdlyNetworkSend("meta", "StartTrial", "2000001012345678:trial_start", 0.0, "USD", "meta_start_trial_enabled"))
        assertEquals("meta", p.getString("network"))
        assertEquals("StartTrial", p.getString("event"))
        assertEquals(0.0, p.getDouble("value"), 0.0)
        assertEquals("USD", p.getString("currency"))
        assertTrue(ReservedProps.networkSend(KerdlyNetworkSend("meta", "Purchase", value = Double.NaN)).isNull("value"))
    }

    @Test
    fun identifyConsentAndIdsProps() {
        val identify = ReservedProps.identify(null, "u1")
        assertTrue(identify.isNull("user_id"))
        assertEquals("u1", identify.getString("previous_user_id"))

        val consent = ReservedProps.consent(analytics = true, ads = false)
        assertEquals("not_applicable", consent.getString("att"))
        assertFalse(consent.getBoolean("ads"))

        val ids = ReservedProps.ids(null, mapOf("meta_anon_id" to "X"))
        assertTrue(ids.isNull("app_account_token"))
        assertEquals("X", ids.getJSONObject("partner").getString("meta_anon_id"))
    }

    @Test
    fun installPropsWithAnUnknownInstallTime() {
        val p = ReservedProps.install(null, 5L, null, null, ContextJson.device(DeviceContext.UNKNOWN, null, null))
        assertTrue(p.isNull("installed_at"))
        assertTrue(p.isNull("installed_at_source"))
        assertEquals(5L, p.getLong("first_launch_at"))
        assertTrue(p.isNull("installer"))
        assertTrue(p.isNull("initial_url"))
        assertNull(p.opt("restored_from"))
        val device = p.getJSONObject("device")
        assertEquals("android", device.getString("platform"))
        assertEquals("not_applicable", device.getString("att"))
    }
}
