package com.kerdly.sdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Modifier

/** The public object before `configure` (no Android runtime needed): it parses, buffers and
 * never throws — not even for the nulls a Java caller can pass to non-null parameters. */
class KerdlyApiTest {
    @Test
    fun beforeConfigureNothingIsKnownAndNothingThrows() {
        assertNull(Kerdly.installId)
        assertNull(Kerdly.attribution)
        Kerdly.setUserId("u1")
        Kerdly.track("registration", mapOf("method" to "anonymous"))
        Kerdly.trackRegistration(method = "anonymous")
        Kerdly.trackStartTrial(productId = "car_weekly_pro", value = 0.0, currency = "USD", transactionId = "t1")
        Kerdly.trackSubscribe("car_weekly_pro", 7.99, "USD", "t2", mapOf("plan" to "weekly"))
        Kerdly.trackPurchase(productId = "exam_pack", value = 4.99, currency = "EUR", quantity = 1)
        Kerdly.setConsent(analytics = true)
        Kerdly.setAppAccountToken(null)
        Kerdly.setPartnerIds(mapOf("meta_anon_id" to "x"))
        Kerdly.notifyPurchase(KerdlyPurchase("tok"))
        Kerdly.recordNetworkSend(KerdlyNetworkSend("meta", "StartTrial"))
        Kerdly.onAttribution { }
        Kerdly.flush()
    }

    @Test
    fun handleUrlParsesAtOnce() {
        val link = Kerdly.handleUrl("https://acme-app.com/onboarding?cpp=web-meta&kerdly_c=k3f9")!!
        assertEquals("web-meta", link.cpp)
        assertEquals("k3f9", link.clickId)
        assertNull(Kerdly.handleUrl("  "))
    }

    @Test
    fun javaNullsAreSwallowed() {
        val cls = Kerdly::class.java
        assertNull(cls.getMethod("handleUrl", String::class.java).invoke(null, null))
        cls.getMethod("track", String::class.java, Map::class.java).invoke(null, null, null)
        cls.getMethod("setPartnerIds", Map::class.java).invoke(null, null)
        cls.getMethod("notifyPurchase", KerdlyPurchase::class.java).invoke(null, null)
        cls.getMethod("configure", android.content.Context::class.java, KerdlyOptions::class.java).invoke(null, null, null)
        assertNull(Kerdly.installId)
    }

    @Test
    fun standardEventMethodsAreStaticWithJavaOverloads() {
        val cls = Kerdly::class.java
        val str = String::class.java
        val dbl = Double::class.javaObjectType
        val map = Map::class.java
        val overloads = listOf(
            cls.getMethod("trackRegistration"),
            cls.getMethod("trackRegistration", str),
            cls.getMethod("trackRegistration", str, map),
            cls.getMethod("trackStartTrial"),
            cls.getMethod("trackStartTrial", str, dbl, str, str, map),
            cls.getMethod("trackSubscribe", str, dbl),
            cls.getMethod("trackSubscribe", str, dbl, str, str, map),
            cls.getMethod("trackPurchase", str, dbl, str, Int::class.javaObjectType, str, map),
        )
        assertTrue(overloads.all { Modifier.isStatic(it.modifiers) })
        // A Java caller's null properties never throw.
        cls.getMethod("trackSubscribe", str, dbl, str, str, map).invoke(null, "p", 9.99, "USD", "t", null)
        cls.getMethod("trackRegistration", str, map).invoke(null, null, null)
    }

    @Test
    fun optionsNeverPrintTheWholeKey() {
        val text = KerdlyOptions(key = "pk_live_0123456789abcdef", endpoint = "https://sdk.example.com").toString()
        assertEquals(false, text.contains("0123456789abcdef"))
    }
}
