package com.kerdly.sdk.internal

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The batches the SDK builds have the shape of the golden fixtures in spec/fixtures/. */
class FixtureContractTest {
    /** Keys defines that a fixture predates (additive within v1). Empty since the
     * fixture carries the referrer's `status` / `response_code`; nothing may differ from it. */
    private val additive = emptyMap<String, Set<String>>()

    private fun firstLaunchBatch(): JSONObject {
        val h = Harness()
        h.cfg = CoreConfig(
            key = "pk_test_123",
            endpoint = "https://sdk.example.com",
            environment = "production",
            collectAdvertisingId = true,
            metaAppId = "1234567890",
            wrapper = null,
        )
        h.platform.referrerResult = PlayReferrerResult.Ok(FakePlatform.FIXTURE_REFERRER)
        h.platform.metaRows = listOf(
            MetaReferrerRow(
                source = "instagram",
                installReferrer = "{\"utm_campaign\":\"x\",\"utm_content\":\"{\\\"source\\\":{\\\"data\\\":\\\"abc\\\",\\\"nonce\\\":\\\"def\\\"}}\"}",
                isCt = 1,
                actualTimestamp = 1_760_399_880,
            ),
        )
        // The launch batch fails, so its retry carries $install, $open and all three signals:
        // the same five events as the fixture.
        h.transport.offlineBatches = true
        h.launch()
        h.runDue()
        h.transport.offlineBatches = false
        h.advance(Backoff.MAX_MS)
        return h.transport.batches().first { it.getJSONArray("events").length() == 5 }
    }

    @Test
    fun firstLaunchBatchHasTheFixtureKeys() {
        val fixture = Spec.json("batch-android-first-launch.request.json")
        val batch = firstLaunchBatch()

        assertEquals("top-level keys", fixture.keyList(), batch.keyList())
        assertShape("sdk", fixture.getJSONObject("sdk"), batch.getJSONObject("sdk"))
        assertShape("app", fixture.getJSONObject("app"), batch.getJSONObject("app"))
        assertShape("context", fixture.getJSONObject("context"), batch.getJSONObject("context"))
        assertTrue(batch.get("sent_at") is Number)
        assertTrue(batch.get("install_id") is String)

        val expected = fixture.getJSONArray("events").objects()
        val actual = batch.getJSONArray("events").objects()
        assertEquals("event count", expected.size, actual.size)
        for (e in expected) {
            val label = label(e)
            val a = actual.firstOrNull { label(it) == label }
            assertNotNull("no $label event in the batch", a)
            assertShape("events[$label]", e, a!!)
        }
    }

    @Test
    fun firstLaunchBatchHasTheFixtureValues() {
        val fixture = Spec.json("batch-android-first-launch.request.json")
        val batch = firstLaunchBatch()

        assertEquals("kerdly-android", batch.getJSONObject("sdk").getString("name"))
        assertEquals(SdkInfo.VERSION, batch.getJSONObject("sdk").getString("version"))
        assertFalse(batch.getJSONObject("sdk").has("wrapper"))
        assertTrue(jsonEquals(fixture.getJSONObject("app"), batch.getJSONObject("app")))
        assertEquals(fixture.getString("install_id"), batch.getString("install_id"))
        // Device values are the fixture's (FakePlatform), so the whole context must match.
        assertTrue(
            "context\nexpected ${fixture.getJSONObject("context")}\nactual   ${batch.getJSONObject("context")}",
            jsonEquals(fixture.getJSONObject("context"), batch.getJSONObject("context")),
        )

        val events = batch.getJSONArray("events").objects()
        assertEquals(listOf(1L, 2L, 3L, 4L, 5L), events.map { it.getLong("seq") })
        assertTrue(events.all { InstallId.isValid(it.getString("id")) })
        assertTrue(events.none { it.has("user_id") })
        for (e in fixture.getJSONArray("events").objects()) {
            val a = events.first { label(it) == label(e) }
            val expectedProps = e.getJSONObject("props")
            val actualProps = JSONObject(a.getJSONObject("props").toString())
            additive["events[${label(e)}].props"]?.forEach { actualProps.remove(it) }
            assertTrue(
                "${label(e)} props\nexpected $expectedProps\nactual   $actualProps",
                jsonEquals(expectedProps, actualProps),
            )
        }
        val referrer = events.signal("install_referrer")!!.getJSONObject("props")
        assertEquals("ok", referrer.getString("status"))
        assertTrue(referrer.isNull("response_code"))
    }

    @Test
    fun firstLaunchInstallCarriesTheFixtureDevice() {
        val fixture = Spec.json("batch-android-first-launch.request.json")
        val expected = fixture.getJSONArray("events").objects().named(EventNames.INSTALL).single().getJSONObject("props").getJSONObject("device")
        val actual = firstLaunchBatch().getJSONArray("events").objects().named(EventNames.INSTALL).single().getJSONObject("props").getJSONObject("device")
        assertTrue("device\nexpected $expected\nactual   $actual", jsonEquals(expected, actual))

        // In the fixture too, the snapshot is the context without consent and lat.
        val context = JSONObject(fixture.getJSONObject("context").toString())
        context.remove("consent")
        context.remove("lat")
        assertTrue(jsonEquals(context, expected))
    }

    /** The standard-event fixture is written from iOS; names and props are the same on Android
     * (ids, ts, seq and user_id are not compared). */
    @Test
    fun standardEventMethodsBuildTheFixtureEvents() {
        val fixture = Spec.json("batch-standard-events.request.json")
        val h = Harness()
        h.launch()
        h.runDue()
        val ts = h.clock.now
        // What Kerdly.trackRegistration / trackStartTrial / trackSubscribe / trackPurchase submit.
        h.on { it.trackStandard(StandardEvents.REGISTRATION, StandardEvents.registration("anonymous"), emptyMap(), ts) }
        h.on { it.trackStandard(StandardEvents.START_TRIAL, StandardEvents.money("car_weekly_pro", 0.0, "USD", "2000001012345678"), emptyMap(), ts) }
        h.on { it.trackStandard(StandardEvents.SUBSCRIBE, StandardEvents.money("car_weekly_pro", 7.99, "usd", "2000001012345679"), mapOf("plan" to "weekly"), ts) }
        h.on { it.trackStandard(StandardEvents.PURCHASE, StandardEvents.money("exam_pack", 4.99, "EUR", "2000001012345680", quantity = 1), emptyMap(), ts) }
        h.on { it.track("quiz_completed", linkedMapOf("score" to 42, "state" to "CA", "passed" to true), ts) }
        h.run { it.flush() }

        val expected = fixture.getJSONArray("events").objects()
        val actual = h.transport.sentEvents().filterNot { EventNames.isReserved(it.getString("name")) }
        assertEquals(expected.map { it.getString("name") }, actual.map { it.getString("name") })
        for ((e, a) in expected.zip(actual)) {
            val name = e.getString("name")
            assertTrue(
                "$name props\nexpected ${e.getJSONObject("props")}\nactual   ${a.getJSONObject("props")}",
                jsonEquals(e.getJSONObject("props"), a.getJSONObject("props")),
            )
            assertShape("events[$name]", e.getJSONObject("props"), a.getJSONObject("props"))
        }
        // The same props through track pass unchanged: the fixture's are already valid.
        for (e in expected) {
            val props = e.getJSONObject("props")
            val map = props.keyList().associateWith { props.get(it) }
            val s = StandardEvents.sanitize(e.getString("name"), map)
            assertTrue(e.getString("name"), s.dropped.isEmpty() && jsonEquals(props, s.json))
        }
    }

    @Test
    fun batchResponseFixtureParses() {
        val ack = BatchResponses.parseAck(Spec.text("batch.response.json"))!!
        assertEquals(listOf("a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c01", "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c02"), ack.accepted)
        assertEquals(1, ack.rejected.size)
        assertEquals("a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c08", ack.rejected[0].id)
        assertEquals("invalid_name", ack.rejected[0].reason)
        assertEquals("\"1-5e1a\"", ack.configEtag)
        assertEquals(emptyList<String>(), ack.needs)
        val attribution = AttributionParser.fromJson(ack.attribution)!!
        assertEquals("provisional", attribution.state)
        assertEquals("meta", attribution.network)
        assertEquals("measured", attribution.status)
        assertEquals("cpp_deeplink", attribution.method)
        assertEquals("ce3a1b2c-0000-4000-8000-000000000001", attribution.cppId)
        assertEquals(1_760_400_126_000L, attribution.decidedAt)
    }

    @Test
    fun configFixtureParses() {
        val config = RemoteConfig.parse(Spec.text("config.response.json"))!!
        assertEquals(1, config.version)
        assertTrue(config.enabled)
        assertEquals(50, config.maxBatch)
        assertEquals(20, config.queueFlushAt)
        assertEquals(15, config.intervalS)
        assertTrue(config.blocked.isEmpty())
        assertTrue(config.collectAdvertisingId && config.collectInstallReferrer && config.collectMetaInstallReferrer && config.collectPurchases)
        assertEquals("0.1.0", config.minSupportedSdk)
    }

    @Test
    fun eventsFixtureNamesFollowTheCustomRules() {
        // The one event the collector rejects in the fixture is one the SDK would never send.
        val names = Spec.json("batch-events.request.json").getJSONArray("events").objects().map { it.getString("name") }
        val custom = names.filterNot { EventNames.isReserved(it) }
        assertEquals(listOf("registration", "Bad Name"), custom)
        assertTrue(CustomEvents.isValidName("registration"))
        assertFalse(CustomEvents.isValidName("Bad Name"))
    }

    private fun label(event: JSONObject): String {
        val name = event.getString("name")
        return if (name == EventNames.SIGNAL) "$name:${event.getJSONObject("props").getString("kind")}" else name
    }

    /** Same keys (bar [additive]) and the same JSON type for every value, recursively. */
    private fun assertShape(path: String, expected: Any?, actual: Any?) {
        when (expected) {
            is JSONObject -> {
                assertTrue("$path: expected an object, got $actual", actual is JSONObject)
                val a = actual as JSONObject
                val extra = additive[path] ?: emptySet()
                assertEquals("keys of $path", expected.keyList(), a.keyList() - extra)
                assertTrue("$path lacks the additive keys $extra", a.keyList().containsAll(extra))
                for (k in expected.keyList()) assertShape("$path.$k", expected.opt(k), a.opt(k))
            }
            is JSONArray -> {
                assertTrue("$path: expected an array, got $actual", actual is JSONArray)
                val a = actual as JSONArray
                if (expected.length() > 0 && a.length() > 0) assertShape("$path[0]", expected.get(0), a.get(0))
            }
            JSONObject.NULL -> assertEquals("$path should be null", JSONObject.NULL, actual)
            is Number -> assertTrue("$path: expected a number, got $actual", actual is Number)
            is String -> assertTrue("$path: expected a string, got $actual", actual is String)
            is Boolean -> assertTrue("$path: expected a boolean, got $actual", actual is Boolean)
            else -> error("unexpected fixture value at $path: $expected")
        }
    }
}
