package com.kerdly.sdk.internal

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConfigAndAttributionTest {
    @Test
    fun missingOrMalformedConfigFieldsTakeTheDefaults() {
        val c = RemoteConfig.parse("""{"enabled":"yes","flush":{"max_batch":500,"queue_flush_at":0,"interval_s":-4},"collect":{"advertising_id":false}}""")!!
        assertTrue("a non-boolean kill switch is ignored", c.enabled)
        assertEquals(50, c.maxBatch)
        assertEquals(1, c.queueFlushAt)
        assertEquals(1, c.intervalS)
        assertFalse(c.collectAdvertisingId)
        assertTrue(c.collectInstallReferrer)
        assertNull(c.minSupportedSdk)
        assertNull(RemoteConfig.parse("nope"))
    }

    @Test
    fun killSwitchBlockListAndDebugDevices() {
        val c = RemoteConfig.parse("""{"enabled":false,"events":{"block":["noisy"]},"debug_devices":["4D5E6F7A-8B9C-4D0E-9F1A-2B3C4D5E6F71"]}""")!!
        assertFalse(c.enabled)
        assertEquals(setOf("noisy"), c.blocked)
        assertTrue("4d5e6f7a-8b9c-4d0e-9f1a-2b3c4d5e6f71" in c.debugDevices)
    }

    @Test
    fun publicIpFlagAndEchoUrl() {
        val fixture = RemoteConfig.parse(Spec.text("config.response.json"))!!
        assertTrue(fixture.collectPublicIp)
        assertEquals("https://api6.ipify.org?format=json", fixture.ipv6EchoUrl)

        val c = RemoteConfig.parse("""{"collect":{"public_ip":false},"ipv6_echo_url":"https://ip6.example.com/json"}""")!!
        assertFalse(c.collectPublicIp)
        assertEquals("https://ip6.example.com/json", c.ipv6EchoUrl)
        assertTrue("a non-boolean flag is ignored", RemoteConfig.parse("""{"collect":{"public_ip":"no"}}""")!!.collectPublicIp)

        // Only an https URL with a host replaces the default.
        for (bad in listOf("\"http://ip6.example.com/json\"", "\"ip6.example.com\"", "\"//ip6.example.com\"", "\"https://\"", "\"ftp://ip6.example.com\"", "\"https://ip6.example.com/a b\"", "\"\"", "null", "42")) {
            assertEquals(bad, PublicIp.DEFAULT_ECHO_URL, RemoteConfig.parse("""{"ipv6_echo_url":$bad}""")!!.ipv6EchoUrl)
        }
    }

    @Test
    fun theConfigCacheRoundTrips() {
        val raw = Spec.json("config.response.json")
        val cache = ConfigCache("\"1-5e1a\"", 123L, raw, "5.12")
        val back = ConfigCache.parse(cache.serialize())
        assertEquals("\"1-5e1a\"", back.etag)
        assertEquals(123L, back.fetchedAt)
        assertEquals("5.12", back.appVersion)
        assertNull("a cache from before the stamp names no version", ConfigCache.parse(ConfigCache("x", 1L, raw).serialize()).appVersion)
        assertEquals(15, back.config!!.intervalS)
        assertNull(ConfigCache.parse("""{"etag":"x"}""").etag)
        assertNull(ConfigCache.parse(null).config)
    }

    @Test
    fun semverComparison() {
        assertEquals(0, Semver.compare("0.1.0", "0.1.0"))
        assertTrue(Semver.compare("0.1.0", "0.2.0") < 0)
        assertTrue(Semver.compare("0.10.0", "0.9.9") > 0)
        assertTrue(Semver.compare("1.0", "0.9.9") > 0)
        assertEquals(0, Semver.compare("0.1.0-beta.1", "0.1.0"))
        assertEquals(0, Semver.compare("v0.1.0", "0.1"))
    }

    @Test
    fun attributionFromTheBatchResponseFixture() {
        val o = Spec.json("batch.response.json").getJSONObject("attribution")
        val a = AttributionParser.fromJson(o)!!
        assertEquals("provisional", a.state)
        assertEquals("measured", a.status)
        assertNull(a.campaignId)
        assertNull(a.keyword)
        assertTrue(jsonEquals(o, JSONObject(a.raw)))
    }

    @Test
    fun attributionPollBodies() {
        val o = Spec.json("batch.response.json").getJSONObject("attribution")
        assertEquals("meta", AttributionParser.fromPollBody(JSONObject().put("attribution", o).put("deferred_link", JSONObject.NULL).toString())!!.network)
        assertEquals("meta", AttributionParser.fromPollBody(o.toString())!!.network)
        assertNull(AttributionParser.fromPollBody("""{"attribution":null}"""))
        assertNull(AttributionParser.fromPollBody("""{"state":"final"}"""))
        assertNull(AttributionParser.fromPollBody("oops"))
    }

    @Test
    fun jsonEqualityIgnoresKeyOrderAndNumberTypes() {
        assertTrue(jsonEquals(JSONObject("""{"a":1,"b":[1,{"c":null}]}"""), JSONObject("""{"b":[1.0,{"c":null}],"a":1}""")))
        assertFalse(jsonEquals(JSONObject("""{"a":1}"""), JSONObject("""{"a":2}""")))
        assertFalse(jsonEquals(JSONObject("""{"a":1}"""), JSONObject("""{"a":1,"b":2}""")))
        assertTrue(jsonEquals(null, JSONObject.NULL))
    }
}
