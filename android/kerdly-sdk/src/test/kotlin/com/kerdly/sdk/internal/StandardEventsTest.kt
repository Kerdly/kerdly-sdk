package com.kerdly.sdk.internal

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Standard events: typed props checked the same way from the typed methods and
 * from `track`; the rest under the custom rules. */
class StandardEventsTest {
    private fun sanitize(name: String, props: Map<String, Any?>) = StandardEvents.sanitize(name, props)

    // --- Typed props -------------------------------------------------------------------------

    @Test
    fun aNegativeOrNonFiniteValueIsDroppedAndTheRestKept() {
        for (bad in listOf<Any>(-0.01, -1, Double.NaN, Double.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY, "9.99", true)) {
            val s = sanitize("subscribe", mapOf("product_id" to "p", "value" to bad, "currency" to "USD"))
            assertFalse("$bad", s.json.has("value"))
            assertEquals("USD", s.json.getString("currency"))
            assertEquals("p", s.json.getString("product_id"))
            assertEquals(listOf("value (not a finite number ≥ 0)"), s.dropped)
        }
    }

    @Test
    fun zeroIsAValueAFreeTrial() {
        val s = sanitize("start_trial", mapOf("value" to 0.0, "currency" to "USD"))
        assertEquals(0.0, s.json.getDouble("value"), 0.0)
        assertTrue(s.dropped.isEmpty())
    }

    @Test
    fun theCurrencyIsTrimmedAndUpperCased() {
        val s = sanitize("subscribe", mapOf("value" to 7.99, "currency" to " usd "))
        assertEquals("USD", s.json.getString("currency"))
        assertEquals(7.99, s.json.getDouble("value"), 0.0)
        assertTrue(s.dropped.isEmpty())
    }

    @Test
    fun anInvalidCurrencyIsDroppedAndTakesTheValueWithIt() {
        for (bad in listOf<Any>("US", "USDT", "U5D", "€€€", "", 840)) {
            val s = sanitize("purchase", mapOf("product_id" to "exam_pack", "value" to 4.99, "currency" to bad, "quantity" to 1))
            assertEquals("$bad", setOf("product_id", "quantity"), s.json.keyList())
            assertEquals(listOf("currency (not a three-letter ISO 4217 code)", "value (no valid currency)"), s.dropped)
        }
    }

    @Test
    fun aValueWithoutACurrencyIsDropped() {
        val s = sanitize("purchase", mapOf("product_id" to "exam_pack", "value" to 4.99, "quantity" to 1))
        assertEquals(setOf("product_id", "quantity"), s.json.keyList())
        assertEquals(listOf("value (no valid currency)"), s.dropped)
        // A currency alone is kept.
        assertEquals(setOf("currency"), sanitize("subscribe", mapOf("currency" to "eur")).json.keyList())
    }

    @Test
    fun quantityIsAnIntegerOfAtLeastOne() {
        for (bad in listOf<Any>(0, -1, 2.5, Double.NaN, "2", true)) {
            val s = sanitize("purchase", mapOf("quantity" to bad, "product_id" to "p"))
            assertFalse("$bad", s.json.has("quantity"))
            assertEquals(listOf("quantity (not an integer ≥ 1)"), s.dropped)
        }
        for ((ok, want) in listOf<Pair<Any, Long>>(1 to 1L, 3L to 3L, 2.0 to 2L, 4.0f to 4L)) {
            val q = sanitize("purchase", mapOf("quantity" to ok)).json.get("quantity")
            assertEquals("$ok", want, q)
        }
    }

    @Test
    fun idsAreCutAt128AndTheMethodAt64() {
        val s = sanitize("subscribe", mapOf("product_id" to "p".repeat(200), "transaction_id" to "t".repeat(129)))
        assertEquals(128, s.json.getString("product_id").length)
        assertEquals(128, s.json.getString("transaction_id").length)
        assertTrue(s.dropped.isEmpty())
        assertEquals(64, sanitize("registration", mapOf("method" to "m".repeat(100))).json.getString("method").length)
    }

    @Test
    fun typedStringsMustBeStrings() {
        val s = sanitize("start_trial", mapOf("product_id" to 42, "transaction_id" to 2_000_001_012_345_678L))
        assertEquals(0, s.json.length())
        assertEquals(listOf("product_id (not a string)", "transaction_id (not a string)"), s.dropped)
        assertEquals(listOf("method (not a string)"), sanitize("registration", mapOf("method" to true)).dropped)
    }

    @Test
    fun quantityIsTypedOnlyForPurchase() {
        // On subscribe it is an ordinary custom prop.
        val s = sanitize("subscribe", mapOf("quantity" to 0))
        assertEquals(0L, s.json.getLong("quantity"))
    }

    // --- Custom props riding along -----------------------------------------------------------

    @Test
    fun extraPropsFollowTheCustomRules() {
        val s = sanitize(
            "subscribe",
            linkedMapOf("product_id" to "p", "plan" to "weekly", "Bad" to "x", "nested" to mapOf("a" to 1), "s" to "y".repeat(300)),
        )
        assertEquals(setOf("product_id", "plan", "s"), s.json.keyList())
        assertEquals(256, s.json.getString("s").length)
        assertEquals(listOf("Bad (invalid key)", "nested (unsupported value)"), s.dropped)
    }

    @Test
    fun theTypedPropsCountTowardTwentyFive() {
        val props = linkedMapOf<String, Any?>()
        for (i in 0 until 30) props["p$i"] = i
        // Typed keys after the custom ones still come first: they always fit.
        props.putAll(mapOf("product_id" to "p", "value" to 1.0, "currency" to "USD", "quantity" to 1, "transaction_id" to "t"))
        val s = sanitize("purchase", props)
        assertEquals(25, s.json.length())
        for (k in listOf("product_id", "value", "currency", "quantity", "transaction_id")) assertTrue(k, s.json.has(k))
        assertTrue(s.json.has("p19"))
        assertFalse(s.json.has("p20"))
        assertEquals(10, s.dropped.size)
    }

    @Test
    fun otherNamesGetOnlyTheCustomRules() {
        val s = sanitize("quiz_completed", mapOf("currency" to "usd", "value" to -1, "quantity" to 0))
        assertEquals("usd", s.json.getString("currency"))
        assertEquals(-1L, s.json.getLong("value"))
        assertEquals(0L, s.json.getLong("quantity"))
        assertTrue(s.dropped.isEmpty())
    }

    @Test
    fun theTypedArgumentsWinOverProperties() {
        val (merged, ignored) = StandardEvents.merge(
            StandardEvents.money("car_weekly_pro", 7.99, null, null),
            linkedMapOf("product_id" to "other", "currency" to "usd", "plan" to "weekly"),
        )
        assertEquals(mapOf("product_id" to "car_weekly_pro", "value" to 7.99, "currency" to "usd", "plan" to "weekly"), merged)
        assertEquals(listOf("product_id"), ignored)
    }

    // --- Through the engine ------------------------------------------------------------------

    private fun launched(): Harness {
        val h = Harness()
        h.launch()
        h.runDue()
        return h
    }

    @Test
    fun trackWithAStandardNameIsCheckedLikeTheTypedMethod() {
        val h = launched()
        val id = "p".repeat(200)
        h.run {
            it.track(
                "purchase",
                linkedMapOf("product_id" to id, "value" to -4.99, "currency" to "eur", "quantity" to 0, "transaction_id" to "t", "plan" to "x"),
                h.clock.now,
            )
        }
        h.run { it.trackStandard(StandardEvents.PURCHASE, StandardEvents.money(id, -4.99, "eur", "t", 0), mapOf("plan" to "x"), h.clock.now) }
        h.run { it.flush() }

        val sent = h.transport.sentEvents().named("purchase")
        assertEquals(2, sent.size)
        val expected = JSONObject().put("product_id", "p".repeat(128)).put("currency", "EUR").put("transaction_id", "t").put("plan", "x")
        for (e in sent) assertTrue("${e.getJSONObject("props")}", jsonEquals(expected, e.getJSONObject("props")))
        val logged = h.sink.lines.filter { it.contains("purchase: dropped props") }
        assertEquals(2, logged.size)
        assertTrue(logged.all { it.startsWith("DEBUG") && it.contains("value (not a finite number ≥ 0)") && it.contains("quantity (not an integer ≥ 1)") })
    }

    @Test
    fun propertiesNeverReplaceATypedArgument() {
        val h = launched()
        h.run {
            it.trackStandard(
                StandardEvents.SUBSCRIBE,
                StandardEvents.money("car_weekly_pro", 7.99, null, null),
                linkedMapOf("product_id" to "other", "currency" to " usd", "transaction_id" to "t".repeat(200), "plan" to "weekly"),
                h.clock.now,
            )
        }
        h.run { it.flush() }
        val props = h.transport.sentEvents().named("subscribe").single().getJSONObject("props")
        // A typed key the method left null comes from properties, checked as typed.
        val expected = JSONObject()
            .put("product_id", "car_weekly_pro")
            .put("value", 7.99)
            .put("currency", "USD")
            .put("transaction_id", "t".repeat(128))
            .put("plan", "weekly")
        assertTrue("$props", jsonEquals(expected, props))
        assertTrue(h.sink.lines.any { it.startsWith("DEBUG") && it.contains("subscribe: dropped props product_id (set by the typed argument)") })
    }

    @Test
    fun standardEventsNeedAnalyticsConsent() {
        val h = launched()
        h.run { it.setConsent(analytics = false, ads = null, ts = h.clock.now) }
        h.run { it.trackStandard(StandardEvents.REGISTRATION, StandardEvents.registration("anonymous"), emptyMap(), h.clock.now) }
        h.run { it.flush() }
        assertTrue(h.transport.sentEvents().named("registration").isEmpty())
    }
}
