package com.kerdly.sdk.internal

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** TikTok's deferred deep link, asked from the device once per install. */
class DeferredLinksTest {
    private val hour = 3_600_000L
    private val link = "com.acme.app://onboarding?utm_source=tiktok&campaign_id=1&adgroup_id=2&ad_id=3"

    /** A harness whose server serves the config fixture with [ddl] as its `ddl` block. */
    private fun harness(
        ddl: JSONObject = JSONObject()
            .put("enabled", true).put("max_age_h", 47).put("meta", JSONObject.NULL)
            .put("tiktok", JSONObject().put("app_id", "7600000000000000002").put("store_app_id", "com.acme.app")),
    ): Harness {
        val h = Harness()
        val config = Spec.json("config.response.json").put("ddl", ddl)
        h.transport.configHandler = { HttpResponse(200, config.toString(), etag = FakeTransport.CONFIG_ETAG) }
        h.platform.referrerResult = PlayReferrerResult.Ok(FakePlatform.FIXTURE_REFERRER)
        return h
    }

    private fun signals(h: Harness): List<JSONObject> =
        h.transport.sentEvents().filter { it.getString("name") == EventNames.SIGNAL }
            .map { it.getJSONObject("props") }.filter { it.optString("kind") == "deferred_link" }

    private fun body(request: HttpRequest): JSONObject = JSONObject(String(request.body!!, Charsets.UTF_8))

    @Test
    fun offUnlessTheConfigTurnsItOn() {
        val h = harness(JSONObject().put("enabled", false).put("max_age_h", 47).put("meta", JSONObject.NULL).put("tiktok", JSONObject.NULL))
        h.launch()
        h.runDue()
        assertTrue(h.transport.ddlRequests().isEmpty())
        assertTrue(signals(h).isEmpty())
    }

    @Test
    fun asksTikTokOnceWithTheGaidAndTheRawReferrer() {
        val h = harness()
        h.transport.ddlHandler = { HttpResponse(200, """{"code":0,"message":"OK","data":{"ddl":"$link"}}""") }
        h.launch()
        h.runDue()
        val requests = h.transport.ddlRequests()
        assertEquals(1, requests.size)
        val b = body(requests[0])
        assertEquals("7600000000000000002", b.getString("tiktok_app_id"))
        val context = b.getJSONObject("context")
        assertEquals(FakePlatform.FIXTURE_REFERRER.referrer, context.getJSONObject("ad").getString("gp_referrer"))
        assertEquals("38400000-8cf0-11bd-b23e-10b96e40000d", context.getJSONObject("device").getString("gaid"))
        assertEquals("com.acme.app", context.getJSONObject("app").getString("id"))

        val s = signals(h).single()
        assertEquals("tiktok", s.getString("network"))
        assertEquals("link", s.getString("status"))
        assertEquals(link, s.getString("url"))
        assertEquals(1, s.getInt("attempt"))
        assertEquals("not_applicable", s.getString("att"))
        assertNull(h.state().stringOrNull("ddl_referrer"))

        h.run { it.onBackground(h.clock.now) }
        h.run { it.onForeground(h.clock.now) }
        h.relaunch()
        h.runDue()
        assertEquals("asked once per install", 1, h.transport.ddlRequests().size)
    }

    @Test
    fun waitsForPlaysReferrer() {
        val h = harness()
        h.platform.referrerResult = null // held
        h.launch()
        h.runDue()
        assertTrue(h.transport.ddlRequests().isEmpty())
        h.platform.heldReferrer!!(PlayReferrerResult.Ok(FakePlatform.FIXTURE_REFERRER))
        h.runDue()
        assertEquals(1, h.transport.ddlRequests().size)
    }

    @Test
    fun limitAdTrackingKeepsTheGaidOut() {
        val h = harness()
        h.platform.adId = AdIdResult(null, true)
        h.launch()
        h.runDue()
        assertFalse(body(h.transport.ddlRequests().single()).getJSONObject("context").getJSONObject("device").has("gaid"))
    }

    @Test
    fun theAdsConsentGatesIt() {
        val h = harness()
        h.launch(buffered = listOf { c -> c.setConsent(null, false, h.clock.now) })
        h.runDue()
        assertTrue(h.transport.ddlRequests().isEmpty())
    }

    @Test
    fun aFailureInTransitIsRetriedOnAForegroundAndGivenUpAfterThree() {
        val h = harness()
        h.transport.ddlHandler = { HttpResponse(503, "") }
        h.launch()
        h.runDue()
        assertTrue(signals(h).isEmpty())
        assertEquals(1, h.state().getInt("ddl_tiktok_failures"))
        repeat(2) {
            h.run { it.onBackground(h.clock.now) }
            h.run { it.onForeground(h.clock.now) }
        }
        val s = signals(h).single()
        assertEquals("error", s.getString("status"))
        assertEquals(503, s.getInt("http_status"))
        assertEquals(3, s.getInt("attempt"))
        h.run { it.onBackground(h.clock.now) }
        h.run { it.onForeground(h.clock.now) }
        assertEquals(3, h.transport.ddlRequests().size)
    }

    @Test
    fun aRefusalIsFinal() {
        val h = harness()
        h.transport.ddlHandler = { HttpResponse(200, """{"code":40001,"message":"no permission"}""") }
        h.launch()
        h.runDue()
        val s = signals(h).single()
        assertEquals("error", s.getString("status"))
        assertEquals("40001 no permission", s.getString("detail"))
    }

    @Test
    fun notAskedAfterTheAgeWindow() {
        val h = harness()
        h.platform.referrerResult = null
        h.launch()
        h.runDue()
        h.clock.now += 48 * hour
        h.platform.heldReferrer!!(PlayReferrerResult.Ok(FakePlatform.FIXTURE_REFERRER))
        h.runDue()
        assertTrue(h.transport.ddlRequests().isEmpty())
    }

    @Test
    fun parsesTheConfigBlock() {
        val c = DdlConfig.fromJson(JSONObject().put("enabled", true).put("max_age_h", 500).put("tiktok", JSONObject().put("app_id", "1")))!!
        assertTrue(c.enabled)
        assertEquals(168 * hour, c.maxAgeMs)
        assertEquals("1", c.tiktokAppId)
        assertNull(DdlConfig.fromJson(null))
        assertNull(DdlConfig.fromJson(JSONObject().put("tiktok", JSONObject().put("app_id", "")))!!.tiktokAppId)
    }
}
