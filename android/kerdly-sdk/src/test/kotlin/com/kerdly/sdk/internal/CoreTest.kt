package com.kerdly.sdk.internal

import com.kerdly.sdk.KerdlyNetworkSend
import com.kerdly.sdk.KerdlyPurchase
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreTest {
    private val hour = 3_600_000L
    private val day = 24 * hour

    private fun names(batch: JSONObject) = batch.getJSONArray("events").objects().map { it.getString("name") }

    // --- Launch ------------------------------------------------------------------------------

    @Test
    fun firstLaunchSendsInstallAndOpenAtOnceWithTheHeaders() {
        val h = Harness()
        h.launch()
        h.runDue()

        val config = h.transport.requests.first()
        assertEquals("this version's config comes first", "GET", config.method)
        assertEquals("https://sdk.example.com/v1/sdk/config", config.url)
        val request = h.transport.batchRequests().first()
        assertEquals("POST", request.method)
        assertEquals("https://sdk.example.com/v1/sdk/batch", request.url)
        assertEquals("Bearer pk_test_123", request.headers["Authorization"])
        assertEquals("com.acme.other", request.headers["X-Afr-Bundle"])
        assertEquals("afr-android/${SdkInfo.VERSION}", request.headers["X-Afr-Sdk"])
        assertEquals("application/json", request.headers["Content-Type"])

        val first = h.transport.batches().first()
        assertEquals(listOf("\$install", "\$open"), names(first))
        val install = first.getJSONArray("events").getJSONObject(0)
        assertEquals(1L, install.getLong("seq"))
        val props = install.getJSONObject("props")
        assertEquals("fresh", props.getString("install_state"))
        assertEquals(1_760_399_960_000L, props.getLong("installed_at"))
        assertEquals("package_manager", props.getString("installed_at_source"))
        assertEquals(h.clock.now, props.getLong("first_launch_at"))
        assertEquals("com.android.vending", props.getString("installer"))
        assertTrue(props.isNull("initial_url"))
        assertFalse(props.has("restored_from"))
        assertEquals("launch", first.getJSONArray("events").getJSONObject(1).getJSONObject("props").getString("reason"))
        assertEquals("production", first.getJSONObject("app").getString("environment"))
        assertTrue(first.has("context"))
        assertTrue(h.queued().isEmpty())
    }

    @Test
    fun aNewIdReachesTheDiskBeforeAnythingIsSent() {
        val h = Harness()
        h.launch()
        assertNull("configure itself does not write", h.store.files[StoreFiles.INSTALL_ID])
        var idOnDiskAtFirstSend: String? = null
        h.transport.batchHandler = { body ->
            if (idOnDiskAtFirstSend == null) idOnDiskAtFirstSend = h.store.files[StoreFiles.INSTALL_ID]
            FakeTransport.ackAll(body)
        }
        h.runDue()
        assertEquals(Harness.FIXTURE_INSTALL_ID, idOnDiskAtFirstSend)
        assertEquals(Harness.FIXTURE_INSTALL_ID, h.transport.batches().first().getString("install_id"))
    }

    @Test
    fun installCarriesTheContextsDeviceFields() {
        val noScreen = DeviceContext("15", null, "samsung", "es_US", listOf("es-US"), "America/Los_Angeles", null, null, null)
        for (device in listOf(FakePlatform().device, noScreen)) {
            val h = Harness()
            h.platform.device = device
            h.launch()
            h.runDue()
            val batch = h.transport.batches().first()
            val snapshot = batch.getJSONArray("events").objects().named("\$install").single().getJSONObject("props").getJSONObject("device")
            // The same builder: the context bar its consent and lat, absent values the same way.
            val context = JSONObject(batch.getJSONObject("context").toString())
            context.remove("consent")
            context.remove("lat")
            assertTrue("device\nexpected $context\nactual   $snapshot", jsonEquals(context, snapshot))
            assertEquals(device.screenW != null, snapshot.has("screen"))
            assertEquals("not_applicable", snapshot.getString("att"))
            assertFalse(snapshot.has("idfv"))
        }
    }

    @Test
    fun aTestLabDeviceSaysSoInTheContextAndTheInstallSnapshot() {
        for (testLab in listOf(true, false)) {
            val h = Harness()
            h.platform.device = DeviceContext("15", "Pixel 8", "Google", "en_US", listOf("en-US"), "UTC", 1080, 2400, 2.625, testLab = testLab)
            h.launch()
            h.runDue()
            val batch = h.transport.batches().first()
            val snapshot = batch.getJSONArray("events").objects().named("\$install").single().getJSONObject("props").getJSONObject("device")
            val context = batch.getJSONObject("context")
            if (testLab) {
                assertTrue(context.getBoolean("test_lab"))
                assertTrue(snapshot.getBoolean("test_lab"))
            } else {
                assertFalse(context.has("test_lab"))
                assertFalse(snapshot.has("test_lab"))
            }
        }
    }

    @Test
    fun theDeviceSnapshotIsTakenAtEnqueue() {
        val h = Harness()
        h.transport.offline = true
        h.launch()
        h.runDue()
        // By the time the batch goes out the device has changed; the context says so, the
        // snapshot keeps what it was when `$install` was queued.
        h.platform.device = DeviceContext("16", "SM-S921B", "samsung", "en_US", listOf("en-US"), "America/New_York", 1080, 2340, 2.625)
        h.transport.offline = false
        h.advance(Backoff.MAX_MS)
        val batch = h.transport.batches().first()
        val snapshot = batch.getJSONArray("events").objects().named("\$install").single().getJSONObject("props").getJSONObject("device")
        assertEquals("America/Los_Angeles", snapshot.getString("tz"))
        assertEquals("15", snapshot.getString("os"))
        assertEquals("America/New_York", batch.getJSONObject("context").getString("tz"))
    }

    @Test
    fun anUnreadableDeviceStillSendsASnapshot() {
        val h = Harness()
        h.platform.deviceFails = true
        h.launch()
        h.runDue()
        val snapshot = h.transport.sentEvents().named("\$install").single().getJSONObject("props").getJSONObject("device")
        assertEquals("android", snapshot.getString("platform"))
        assertEquals("not_applicable", snapshot.getString("att"))
        assertEquals("5.12", snapshot.getString("app_version"))
        assertEquals("1310", snapshot.getString("app_build"))
        assertTrue(snapshot.isNull("os"))
        assertEquals(0, snapshot.getJSONArray("languages").length())
        assertFalse(snapshot.has("screen"))
    }

    @Test
    fun aFailedInstallTimeReadIsNullNeverMinusOne() {
        val h = Harness()
        h.platform.install = InstallInfo(installedAt = null, installer = null)
        h.launch()
        h.runDue()
        val props = h.transport.sentEvents().named("\$install").single().getJSONObject("props")
        assertTrue(props.isNull("installed_at"))
        assertTrue(props.isNull("installed_at_source"))
        assertTrue(props.isNull("installer"))
    }

    @Test
    fun theWrapperIsInTheHeaderAndTheBody() {
        val h = Harness()
        h.cfg = CoreConfig("pk_test_123", "https://sdk.example.com", "development", true, null, "expo/0.1.0")
        h.launch()
        h.runDue()
        assertEquals("afr-android/${SdkInfo.VERSION} expo/0.1.0", h.transport.requests.first().headers["X-Afr-Sdk"])
        val batch = h.transport.batches().first()
        assertEquals("expo/0.1.0", batch.getJSONObject("sdk").getString("wrapper"))
        assertEquals("development", batch.getJSONObject("app").getString("environment"))
    }

    @Test
    fun anOrdinaryLaunchSendsOnlyOpenAndSeqNeverRepeats() {
        val h = Harness()
        h.transport.offlineBatches = true
        h.launch()
        h.runDue()
        h.relaunch()
        h.runDue()
        val queued = h.queued()
        assertEquals(listOf("\$install", "\$open", "\$signal", "\$open"), queued.map { it.getString("name") })
        assertEquals(listOf(1L, 2L, 3L, 4L), queued.map { it.getLong("seq") })

        // Back online: the persisted back-off still applies, then one batch carries everything.
        h.transport.offlineBatches = false
        h.relaunch()
        h.runDue()
        assertTrue(h.transport.batchRequests().isEmpty())
        h.advance(Backoff.MAX_MS)
        assertEquals(listOf(1L, 2L, 3L, 4L, 5L), h.transport.sentEvents().map { it.getLong("seq") })
        assertEquals(1, h.transport.sentEvents().named("\$install").size)
        assertTrue(h.queued().isEmpty())
    }

    @Test
    fun callsMadeBeforeConfigureRunAfterInstallAndOpen() {
        val h = Harness()
        h.launch(
            buffered = listOf(
                { c -> c.setUserId("u1", h.clock.now) },
                { c -> c.track("early", mapOf("step" to 1), h.clock.now) },
            ),
        )
        h.runDue()
        val first = h.transport.batches().first()
        assertEquals(listOf("\$install", "\$open", "\$identify", "early"), names(first))
        val events = first.getJSONArray("events").objects()
        assertFalse(events[0].has("user_id"))
        assertEquals("u1", events[3].getString("user_id"))
    }

    // --- Delivery ------------------------------------------------------------------------------

    @Test
    fun acceptedAndRejectedIdsLeaveTheQueueAndOthersStay() {
        val h = Harness()
        h.transport.offlineBatches = true
        h.launch()
        h.runDue()
        h.run { it.track("registration", mapOf("method" to "anonymous"), h.clock.now) }
        assertEquals(4, h.queued().size)

        h.transport.offlineBatches = false
        var calls = 0
        h.transport.batchHandler = { body ->
            calls++
            val ids = body.getJSONArray("events").objects().map { it.getString("id") }
            if (calls == 1) {
                FakeTransport.ack(accepted = listOf(ids[0], ids[2]), rejected = listOf(ids[1] to "invalid_name"))
            } else {
                FakeTransport.ackAll(body)
            }
        }
        h.advance(1_000) // the back-off of the failed launch batch
        assertEquals(listOf("registration"), h.queued().map { it.getString("name") })

        h.advance(Backoff.MAX_MS)
        assertTrue(h.queued().isEmpty())
        val sent = h.transport.sentEvents()
        assertEquals("a rejected event is never resent", 1, sent.named("\$open").size)
        assertEquals("an unanswered event is resent", 2, sent.named("registration").size)
    }

    @Test
    fun unauthorizedDropsTheBatchAndStopsUntilTheNextLaunch() {
        val h = Harness()
        h.transport.batchHandler = { HttpResponse(401, """{"error":"bad key","code":"bad_key"}""") }
        h.launch()
        h.runDue()
        assertEquals(1, h.transport.batchRequests().size)
        assertTrue(h.queued().none { it.getString("name") == "\$install" })
        assertEquals("the config came first; nothing after the 401", 1, h.transport.configRequests().size)

        h.run { it.track("registration", emptyMap(), h.clock.now) }
        h.run { it.flush() }
        h.advance(10 * 60_000)
        assertEquals(1, h.transport.batchRequests().size)

        h.transport.batchHandler = { FakeTransport.ackAll(it) }
        h.relaunch()
        h.runDue()
        assertTrue(h.transport.batchRequests().size > 1)
        assertTrue(h.queued().isEmpty())
    }

    @Test
    fun forbiddenStopsToo() {
        val h = Harness()
        h.transport.batchHandler = { HttpResponse(403, """{"error":"x","code":"bundle_mismatch"}""") }
        h.launch()
        h.runDue()
        h.advance(10 * 60_000)
        assertEquals(1, h.transport.batchRequests().size)
        assertTrue(h.sink.lines.any { it.contains("bundle_mismatch") })
    }

    @Test
    fun malformedDropsTheBatchWithoutStopping() {
        val h = Harness()
        h.transport.batchHandler = { HttpResponse(400, """{"error":"bad","code":"malformed"}""") }
        h.launch()
        h.runDue()
        assertTrue(h.queued().none { it.getString("name") == "\$install" })
        h.transport.batchHandler = { FakeTransport.ackAll(it) }
        h.run { it.track("registration", emptyMap(), h.clock.now) }
        h.run { it.flush() }
        assertTrue(h.transport.sentEvents().named("registration").isNotEmpty())
    }

    @Test
    fun tooLargeHalvesTheBatchUntilItFits() {
        val h = Harness()
        h.launch(foreground = false)
        h.runDue()
        repeat(8) { i -> h.on { it.track("step_$i", emptyMap(), h.clock.now) } }
        h.runDue()
        val sizes = ArrayList<Int>()
        h.transport.batchHandler = { body ->
            val n = body.getJSONArray("events").length()
            sizes.add(n)
            if (n > 2) HttpResponse(413, """{"error":"too large","code":"too_large"}""") else FakeTransport.ackAll(body)
        }
        h.run { it.flush() }
        assertEquals(listOf(8, 4, 2), sizes.take(3))
        assertTrue(h.queued().isEmpty())
        assertEquals(8, h.transport.sentEvents().map { it.getString("name") }.filter { it.startsWith("step_") }.distinct().size)
    }

    @Test
    fun aSingleEventStillTooLargeIsDropped() {
        val h = Harness()
        h.launch(foreground = false)
        h.runDue()
        h.transport.batchHandler = { HttpResponse(413, """{"error":"too large","code":"too_large"}""") }
        h.run { it.track("huge", mapOf("a" to "x"), h.clock.now) }
        h.run { it.track("huge2", emptyMap(), h.clock.now) }
        h.run { it.flush() }
        assertTrue(h.queued().isEmpty())
        assertTrue(h.sink.lines.any { it.contains("too large") })
    }

    @Test
    fun serverErrorsBackOffWithJitterAndRetryAfterWins() {
        val h = Harness()
        h.transport.batchHandler = { HttpResponse(503, "") }
        h.launch()
        h.runDue()
        assertEquals(1, h.transport.batchRequests().size)
        // Retry 1: exactly 1 s (the cap of the first step), and the time is persisted.
        assertEquals(h.clock.now + 1_000, h.state().getLong("retry_next_at"))
        h.advance(999)
        assertEquals(1, h.transport.batchRequests().size)
        h.advance(1)
        assertEquals(2, h.transport.batchRequests().size)
        // Retry 2 lands within [1 s, 2 s].
        val next = h.state().getLong("retry_next_at") - h.clock.now
        assertTrue("retry 2 in $next ms", next in 1_000..2_000)

        h.transport.batchHandler = { HttpResponse(429, """{"error":"slow down","code":"rate_limited"}""", retryAfter = "30") }
        h.advance(next)
        assertEquals(3, h.transport.batchRequests().size)
        h.advance(29_999)
        assertEquals(3, h.transport.batchRequests().size)
        h.transport.batchHandler = { FakeTransport.ackAll(it) }
        h.advance(1)
        assertEquals(4, h.transport.batchRequests().size)
        assertTrue(h.queued().isEmpty())
        assertEquals(0, h.state().getInt("retry_attempt"))
    }

    @Test
    fun thePersistedNextAttemptHoldsAcrossLaunches() {
        val h = Harness()
        h.transport.batchHandler = { HttpResponse(503, "", retryAfter = "60") }
        h.launch()
        h.runDue()
        assertEquals(1, h.transport.batchRequests().size)
        h.transport.batchHandler = { FakeTransport.ackAll(it) }
        h.advance(10_000)
        h.relaunch()
        h.runDue()
        assertEquals(1, h.transport.batchRequests().size)
        h.advance(50_000)
        assertEquals(2, h.transport.batchRequests().size)
        assertTrue(h.queued().isEmpty())
    }

    @Test
    fun anAnswerThatAcksNothingBacksOffInsteadOfLooping() {
        val h = Harness()
        h.transport.batchHandler = { FakeTransport.ack(accepted = emptyList()) }
        h.launch()
        h.runDue()
        assertEquals(1, h.transport.batchRequests().size)
        h.advance(500)
        assertEquals(1, h.transport.batchRequests().size)
    }

    @Test
    fun theContextGoesOutOnlyWhenItChanged() {
        val h = Harness()
        h.launch()
        h.runDue()
        val batches = h.transport.batches()
        assertTrue(batches[0].has("context"))
        assertFalse("lat is unknown before the advertising id read", batches[0].getJSONObject("context").has("lat"))
        // The advertising-id read made `lat` known: a changed context.
        assertEquals(false, batches[1].getJSONObject("context").getBoolean("lat"))

        h.run { it.track("registration", emptyMap(), h.clock.now) }
        h.run { it.flush() }
        assertFalse(h.transport.batches().last().has("context"))

        h.run { it.setConsent(null, false, h.clock.now) }
        val consent = h.transport.batches().last().getJSONObject("context").getJSONObject("consent")
        assertEquals(false, consent.getBoolean("ads"))

        h.relaunch()
        h.runDue()
        assertFalse("an unchanged context is not resent after a relaunch", h.transport.batches().last().has("context"))
    }

    @Test
    fun customEventsWaitForTheTimerOrTwentyQueued() {
        val h = Harness()
        h.launch()
        h.runDue()
        val before = h.transport.batchRequests().size
        h.run { it.track("a", emptyMap(), h.clock.now) }
        assertEquals(before, h.transport.batchRequests().size)
        h.advance(14_999)
        assertEquals(before, h.transport.batchRequests().size)
        h.advance(1)
        assertEquals(before + 1, h.transport.batchRequests().size)

        repeat(20) { i -> h.on { it.track("e$i", emptyMap(), h.clock.now) } }
        h.runDue()
        assertEquals(before + 2, h.transport.batchRequests().size)
        assertEquals(20, h.transport.batches().last().getJSONArray("events").length())
    }

    @Test
    fun inTheBackgroundCustomEventsWaitForTheNextForeground() {
        val h = Harness()
        h.launch(foreground = false)
        h.runDue()
        val before = h.transport.batchRequests().size
        h.run { it.track("a", emptyMap(), h.clock.now) }
        h.advance(60_000)
        assertEquals(before, h.transport.batchRequests().size)
        h.run { it.onForeground(h.clock.now) }
        assertEquals(before + 1, h.transport.batchRequests().size)
    }

    @Test
    fun goingToTheBackgroundFlushes() {
        val h = Harness()
        h.launch()
        h.runDue()
        h.run { it.track("a", emptyMap(), h.clock.now) }
        val before = h.transport.batchRequests().size
        h.run { it.onBackground(h.clock.now) }
        assertEquals(before + 1, h.transport.batchRequests().size)
    }

    @Test
    fun openOnForegroundOnlyAfterThirtyMinutesInTheBackground() {
        val h = Harness()
        h.launch()
        h.runDue()
        h.run { it.onBackground(h.clock.now) }
        h.advance(10 * 60_000)
        h.run { it.onForeground(h.clock.now) }
        assertEquals(1, h.transport.sentEvents().named("\$open").size)

        h.run { it.onBackground(h.clock.now) }
        h.advance(30 * 60_000)
        h.run { it.onForeground(h.clock.now) }
        val opens = h.transport.sentEvents().named("\$open")
        assertEquals(2, opens.size)
        assertEquals("foreground", opens[1].getJSONObject("props").getString("reason"))
    }

    // --- Users, consent, ids -----------------------------------------------------------------

    @Test
    fun identifyCarriesTheNewAndPreviousIds() {
        val h = Harness()
        h.launch()
        h.runDue()
        h.run { it.setUserId("m5KwQ2xYz", h.clock.now) }
        h.run { it.setUserId("m5KwQ2xYz", h.clock.now) }
        h.run { it.track("registration", mapOf("method" to "anonymous"), h.clock.now) }
        h.run { it.setUserId(null, h.clock.now) }
        h.run { it.track("after_logout", emptyMap(), h.clock.now) }
        h.run { it.flush() }

        val sent = h.transport.sentEvents()
        val identifies = sent.named("\$identify")
        assertEquals(2, identifies.size)
        assertEquals("m5KwQ2xYz", identifies[0].getString("user_id"))
        assertEquals("m5KwQ2xYz", identifies[0].getJSONObject("props").getString("user_id"))
        assertTrue(identifies[0].getJSONObject("props").isNull("previous_user_id"))
        assertFalse(identifies[1].has("user_id"))
        assertTrue(identifies[1].getJSONObject("props").isNull("user_id"))
        assertEquals("m5KwQ2xYz", identifies[1].getJSONObject("props").getString("previous_user_id"))
        assertEquals("m5KwQ2xYz", sent.named("registration").single().getString("user_id"))
        assertFalse(sent.named("after_logout").single().has("user_id"))

        h.relaunch()
        h.run { it.setUserId(null, h.clock.now) }
        assertEquals("the user id is persisted", 2, h.transport.sentEvents().named("\$identify").size)
    }

    @Test
    fun analyticsOffKeepsOnlyTheAttributionEvents() {
        val h = Harness()
        h.launch()
        h.runDue()
        h.run { it.setConsent(false, null, h.clock.now) }
        h.run { it.track("registration", emptyMap(), h.clock.now) }
        h.run { it.handleUrl(DeepLinks.parse("acmeapp://open?cpp=web-meta")!!, "runtime", h.clock.now) }
        h.run { it.recordNetworkSend(KerdlyNetworkSend("meta", "StartTrial"), h.clock.now) }
        h.run { it.setUserId("u1", h.clock.now) }
        h.run { it.notifyPurchase(KerdlyPurchase("tok"), h.clock.now) }
        h.run { it.flush() }

        val sent = h.transport.sentEvents()
        val consent = sent.named("\$consent").single().getJSONObject("props")
        assertEquals("not_applicable", consent.getString("att"))
        assertEquals(false, consent.getBoolean("analytics"))
        assertEquals(true, consent.getBoolean("ads"))
        assertTrue(sent.named("registration").isEmpty())
        assertTrue(sent.named("\$deeplink").isEmpty())
        assertTrue(sent.named("\$network_send").isEmpty())
        assertEquals(1, sent.named("\$identify").size)
        assertEquals(1, sent.named("\$purchase_link").size)
        assertNull(h.store.files[StoreFiles.PENDING_LINKS])
    }

    @Test
    fun adsOffNeverReadsTheAdvertisingId() {
        val h = Harness()
        h.launch(buffered = listOf { c -> c.setConsent(null, false, h.clock.now) })
        h.runDue()
        h.advance(day)
        assertEquals(0, h.platform.adIdReads)
        assertNull(h.transport.sentEvents().signal("advertising_ids"))

        h.run { it.setConsent(null, true, h.clock.now) }
        assertEquals(1, h.platform.adIdReads)
        assertNotNull(h.transport.sentEvents().signal("advertising_ids"))
    }

    @Test
    fun collectAdvertisingIdFalseNeverReadsIt() {
        val h = Harness()
        h.cfg = CoreConfig("pk_test_123", "https://sdk.example.com", "production", false, null, null)
        h.launch()
        h.runDue()
        h.run { it.onBackground(h.clock.now) }
        h.run { it.onForeground(h.clock.now) }
        assertEquals(0, h.platform.adIdReads)
    }

    @Test
    fun theAdvertisingIdIsReadDailyAndSentOnChange() {
        val h = Harness()
        h.launch()
        h.runDue()
        assertEquals(1, h.platform.adIdReads)
        val first = h.transport.sentEvents().signal("advertising_ids")!!.getJSONObject("props")
        assertEquals("38400000-8cf0-11bd-b23e-10b96e40000d", first.getString("gaid"))
        assertEquals(false, first.getBoolean("lat"))

        h.relaunch()
        h.runDue()
        assertEquals(1, h.platform.adIdReads)

        h.clock.now += day + 1
        h.relaunch()
        h.runDue()
        assertEquals(2, h.platform.adIdReads)
        assertEquals(1, h.transport.sentEvents().filter { it.getJSONObject("props").optString("kind") == "advertising_ids" }.size)

        // Limit ad tracking switched on: no GAID, lat true.
        h.platform.adId = AdIds.normalize("38400000-8cf0-11bd-b23e-10b96e40000d", limitAdTracking = true)
        h.clock.now += day + 1
        h.relaunch()
        h.runDue()
        val signals = h.transport.sentEvents().filter { it.getJSONObject("props").optString("kind") == "advertising_ids" }
        assertEquals(2, signals.size)
        assertTrue(signals[1].getJSONObject("props").isNull("gaid"))
        assertEquals(true, signals[1].getJSONObject("props").getBoolean("lat"))
    }

    @Test
    fun idsCarryTheTokenAndTheMergedPartnerMap() {
        val h = Harness()
        h.launch()
        h.runDue()
        val alias = "\$SuperwallAlias:3F2504E0-4F89-41D3-9A0C-0305E82C3301"
        h.run { it.setAppAccountToken(alias, h.clock.now) }
        h.run { it.setPartnerIds(mapOf("superwall_alias" to alias), h.clock.now) }
        h.run { it.setPartnerIds(mapOf("superwall_alias" to alias), h.clock.now) }
        h.run { it.setPartnerIds(mapOf("meta_anon_id" to "XZ1"), h.clock.now) }
        h.run { it.setPartnerIds(mapOf("meta_anon_id" to ""), h.clock.now) }
        h.run { it.setAppAccountToken(alias, h.clock.now) }
        h.run { it.flush() }

        val ids = h.transport.sentEvents().named("\$ids").map { it.getJSONObject("props") }
        assertEquals(4, ids.size)
        assertEquals(alias, ids[0].getString("app_account_token"))
        assertEquals(0, ids[0].getJSONObject("partner").length())
        assertEquals(alias, ids[1].getJSONObject("partner").getString("superwall_alias"))
        assertEquals(setOf("superwall_alias", "meta_anon_id"), ids[2].getJSONObject("partner").keyList())
        assertEquals(setOf("superwall_alias"), ids[3].getJSONObject("partner").keyList())
        assertEquals(alias, ids[3].getString("app_account_token"))
    }

    // --- Deep links ----------------------------------------------------------------------------

    @Test
    fun anAttributionLinkStaysPendingAndIsReEnqueuedWithItsIdNextLaunch() {
        val h = Harness()
        h.launch()
        h.runDue()
        h.transport.batchHandler = { HttpResponse(400, """{"error":"bad","code":"malformed"}""") }
        val link = DeepLinks.parse("https://acme-app.com/onboarding?cpp=web-meta&ppid=ce3a1b2c-0000-4000-8000-000000000001")!!
        h.run { it.handleUrl(link, "initial", h.clock.now) }

        val dropped = h.transport.sentEvents().named("\$deeplink").single()
        val props = dropped.getJSONObject("props")
        assertEquals("web-meta", props.getString("cpp"))
        assertEquals("initial", props.getString("source"))
        assertTrue(props.isNull("afr_c"))
        assertTrue(h.queued().none { it.getString("name") == "\$deeplink" })
        assertTrue(h.store.files[StoreFiles.PENDING_LINKS]!!.contains(dropped.getString("id")))

        h.transport.batchHandler = { FakeTransport.ackAll(it) }
        h.relaunch()
        h.runDue()
        val sent = h.transport.sentEvents().named("\$deeplink")
        assertEquals(2, sent.size)
        assertEquals(sent[0].getString("id"), sent[1].getString("id"))
        assertEquals(sent[0].getLong("seq"), sent[1].getLong("seq"))
        assertFalse(h.store.files[StoreFiles.PENDING_LINKS]!!.contains(dropped.getString("id")))

        h.relaunch()
        h.runDue()
        assertEquals(2, h.transport.sentEvents().named("\$deeplink").size)
    }

    @Test
    fun aPlainLinkIsRecordedButNotKeptPending() {
        val h = Harness()
        h.launch()
        h.runDue()
        h.run { it.handleUrl(DeepLinks.parse("https://acme-app.com/settings")!!, "runtime", h.clock.now) }
        assertEquals(1, h.transport.sentEvents().named("\$deeplink").size)
        assertNull(h.store.files[StoreFiles.PENDING_LINKS])
    }

    // --- Purchases -----------------------------------------------------------------------------

    @Test
    fun aPurchaseIsLinkedOncePerToken() {
        val h = Harness()
        h.launch()
        h.runDue()
        val purchase = KerdlyPurchase(
            purchaseToken = "tok-1",
            orderId = "GPA.3333-4444",
            products = listOf("car_weekly_pro"),
            purchaseTime = 1_760_400_119_000L,
            obfuscatedAccountId = "\$SuperwallAlias:3F2504E0",
        )
        h.run { it.notifyPurchase(purchase, h.clock.now) }
        h.run { it.notifyPurchase(purchase, h.clock.now) }
        h.relaunch()
        h.runDue()
        h.run { it.notifyPurchase(purchase, h.clock.now) }
        h.run { it.notifyPurchase(purchase.copy(purchaseToken = "tok-2"), h.clock.now) }

        val links = h.transport.sentEvents().named("\$purchase_link")
        assertEquals(2, links.size)
        val p = links[0].getJSONObject("props")
        assertEquals("play_store", p.getString("store"))
        assertEquals("tok-1", p.getString("purchase_token"))
        assertEquals("GPA.3333-4444", p.getString("order_id"))
        assertEquals("car_weekly_pro", p.getJSONArray("products").getString(0))
        assertEquals(1_760_400_119_000L, p.getLong("purchase_time"))
        assertEquals("\$SuperwallAlias:3F2504E0", p.getString("obfuscated_account_id"))
        assertTrue(p.isNull("obfuscated_profile_id"))
        assertEquals("notify", p.getString("source"))
        assertFalse("only a hash of the token is stored", h.store.files[StoreFiles.PURCHASES]!!.contains("tok-1"))
    }

    // --- Collectors ----------------------------------------------------------------------------

    @Test
    fun aPermanentReferrerAnswerIsSignalledOnce() {
        val h = Harness()
        h.platform.referrerResult = PlayReferrerResult.Permanent(PlayReferrerCodes.FEATURE_NOT_SUPPORTED)
        h.launch()
        h.runDue()
        val props = h.transport.sentEvents().signal("install_referrer")!!.getJSONObject("props")
        assertEquals("unavailable", props.getString("status"))
        assertEquals(2, props.getInt("response_code"))
        assertEquals("", props.getString("referrer"))

        h.run { it.onBackground(h.clock.now) }
        h.run { it.onForeground(h.clock.now) }
        h.relaunch()
        h.runDue()
        assertEquals(1, h.platform.referrerStarts)
    }

    @Test
    fun aTransientReferrerFailureRetriesAtForegroundAndLaunch() {
        val h = Harness()
        h.platform.referrerResult = PlayReferrerResult.Transient("SERVICE_UNAVAILABLE")
        h.launch()
        h.runDue()
        assertNull(h.transport.sentEvents().signal("install_referrer"))
        h.run { it.onBackground(h.clock.now) }
        h.run { it.onForeground(h.clock.now) }
        assertEquals(2, h.platform.referrerStarts)

        h.platform.referrerResult = PlayReferrerResult.Ok(FakePlatform.FIXTURE_REFERRER)
        h.relaunch()
        h.runDue()
        assertEquals(3, h.platform.referrerStarts)
        val props = h.transport.sentEvents().signal("install_referrer")!!.getJSONObject("props")
        assertEquals("ok", props.getString("status"))
        assertEquals(1_760_399_890L, props.getLong("click_ts"))

        h.relaunch()
        h.runDue()
        assertEquals(3, h.platform.referrerStarts)
    }

    @Test
    fun onlyOneReferrerReadIsInFlight() {
        val h = Harness()
        h.platform.referrerResult = null // held
        h.launch()
        h.runDue()
        h.run { it.onBackground(h.clock.now) }
        h.run { it.onForeground(h.clock.now) }
        assertEquals(1, h.platform.referrerStarts)
        h.platform.heldReferrer!!(PlayReferrerResult.Ok(FakePlatform.FIXTURE_REFERRER))
        h.runDue()
        assertNotNull(h.transport.sentEvents().signal("install_referrer"))
    }

    @Test
    fun theReferrerIsRetriedForNinetyDaysOnly() {
        val h = Harness()
        h.platform.install = InstallInfo(h.clock.now - 100 * day, "com.android.vending")
        h.platform.referrerResult = PlayReferrerResult.Transient("SERVICE_DISCONNECTED")
        h.launch()
        h.runDue()
        assertEquals("the first attempt always runs", 1, h.platform.referrerStarts)
        h.relaunch()
        h.runDue()
        assertEquals(1, h.platform.referrerStarts)
        assertTrue(h.state().getBoolean("referrer_done"))
    }

    @Test
    fun theMetaReferrerIsReadOncePerInstallAndTheFreshestRowWins() {
        val h = Harness()
        h.cfg = CoreConfig("pk_test_123", "https://sdk.example.com", "production", true, "1234567890", null)
        h.platform.metaRows = listOf(
            MetaReferrerRow("facebook", "{\"fb\":1}", 0, 1_760_399_000),
            MetaReferrerRow("instagram", "{\"ig\":1}", 1, 1_760_399_880),
            MetaReferrerRow("facebook_lite", null, 1, 1_760_399_999),
        )
        h.launch()
        h.runDue()
        val props = h.transport.sentEvents().signal("meta_install_referrer")!!.getJSONObject("props")
        assertEquals("instagram", props.getString("source"))
        assertEquals("{\"ig\":1}", props.getString("install_referrer"))
        assertEquals(1, props.getInt("is_ct"))
        assertEquals(1_760_399_880L, props.getLong("actual_timestamp"))

        h.relaunch()
        h.runDue()
        assertEquals(1, h.platform.metaReads)
    }

    @Test
    fun noMetaAppIdNoMetaRead() {
        val h = Harness()
        h.launch()
        h.runDue()
        assertEquals(0, h.platform.metaReads)
    }

    @Test
    fun theInstallLaunchSignalsThePublicIpv6RightBehindTheInstallFlush() {
        val h = Harness()
        h.platform.publicIp = "2A02:06B8:0:0:0:0:0:0001"
        var batchesAtLookup = -1
        var adIdReadsAtLookup = -1
        h.platform.onPublicIpLookup = {
            batchesAtLookup = h.transport.batchRequests().size
            adIdReadsAtLookup = h.platform.adIdReads
        }
        h.launch()
        h.runDue()
        assertEquals(listOf(PublicIp.DEFAULT_ECHO_URL to 3_000L), h.platform.publicIpLookups)
        assertEquals("the `\$install` batch went out first", 1, batchesAtLookup)
        assertEquals("ahead of the collectors", 0, adIdReadsAtLookup)
        assertEquals(listOf("\$install", "\$open"), names(h.transport.batches().first()))
        val props = h.transport.sentEvents().signal("public_ip")!!.getJSONObject("props")
        assertEquals(setOf("kind", "ipv6"), props.keyList())
        assertEquals("2a02:6b8::1", props.getString("ipv6"))
        assertTrue(h.sink.lines.any { it == "INFO [Kerdly] public IPv6 2a02…" })
        assertFalse("never the full address", h.sink.lines.any { it.contains("6b8") })

        // Later launches never look it up again.
        h.clock.now += day
        h.relaunch()
        h.runDue()
        h.run { it.onBackground(h.clock.now) }
        h.run { it.onForeground(h.clock.now) }
        assertEquals(1, h.platform.publicIpLookups.size)
        assertEquals(1, h.transport.sentEvents().filter { it.getJSONObject("props").optString("kind") == "public_ip" }.size)
    }

    @Test
    fun noPublicIpv6OnTheInstallLaunchIsNeverRetried() {
        val h = Harness()
        h.platform.publicIp = null // an IPv4-only network
        h.launch()
        h.runDue()
        assertEquals(1, h.platform.publicIpLookups.size)
        assertNull(h.transport.sentEvents().signal("public_ip"))

        h.platform.publicIp = "2001:db8::1"
        h.relaunch()
        h.runDue()
        assertEquals(1, h.platform.publicIpLookups.size)
        assertNull(h.transport.sentEvents().signal("public_ip"))
    }

    @Test
    fun anAnswerThatIsNotAGlobalIpv6IsDropped() {
        for (answer in listOf("203.0.113.7", "::ffff:203.0.113.7", "fe80::1", "fd12:3456::1", "::1", "ff02::1", "2001:db8::1%wlan0", "<html>", "")) {
            val h = Harness()
            h.platform.publicIp = answer
            h.launch()
            h.runDue()
            assertEquals(answer, 1, h.platform.publicIpLookups.size)
            assertNull(answer, h.transport.sentEvents().signal("public_ip"))
        }
    }

    @Test
    fun noPublicIpv6LookupWithAdsConsentOff() {
        val h = Harness()
        h.platform.publicIp = "2001:db8::1"
        h.launch(buffered = listOf { c -> c.setConsent(null, false, h.clock.now) })
        h.runDue()
        // Granting it later does not start one: only the install launch's network counts.
        h.run { it.setConsent(null, true, h.clock.now) }
        assertTrue(h.platform.publicIpLookups.isEmpty())
        assertNull(h.transport.sentEvents().signal("public_ip"))
    }

    @Test
    fun theLookupStartsUnderTheConfigTheInstallLaunchHas() {
        // A real install launch has no fetched config yet; a cached one (config.json outlives a
        // lost install-id file) is what the start reads.
        fun launchWith(collect: Boolean, echoUrl: String): Harness {
            val h = Harness()
            h.platform.publicIp = "2001:db8::1"
            val raw = Spec.json("config.response.json").put("ipv6_echo_url", echoUrl)
            raw.getJSONObject("collect").put("public_ip", collect)
            h.store.files[StoreFiles.CONFIG] = ConfigCache(FakeTransport.CONFIG_ETAG, h.clock.now, raw, "5.12").serialize()
            h.launch()
            h.runDue()
            return h
        }

        val off = launchWith(collect = false, echoUrl = "https://ip6.example.com/json")
        assertTrue(off.platform.publicIpLookups.isEmpty())
        assertNull(off.transport.sentEvents().signal("public_ip"))

        val on = launchWith(collect = true, echoUrl = "https://ip6.example.com/json")
        assertEquals(listOf("https://ip6.example.com/json" to Core.PUBLIC_IP_TIMEOUT_MS), on.platform.publicIpLookups)
        assertEquals("2001:db8::1", on.transport.sentEvents().signal("public_ip")!!.getJSONObject("props").getString("ipv6"))
    }

    @Test
    fun theLookupNeverHoldsTheSdkThread() {
        val h = Harness()
        h.platform.holdPublicIp = true
        h.launch()
        h.runDue()
        assertEquals(1, h.platform.publicIpLookups.size)
        // While it is in flight the collectors, the config fetch and the app's events all go on.
        assertEquals(1, h.platform.adIdReads)
        assertEquals(1, h.transport.configRequests().size)
        h.run { it.track("registration", emptyMap(), h.clock.now) }
        h.run { it.flush() }
        assertEquals(1, h.transport.sentEvents().named("registration").size)
        assertNull(h.transport.sentEvents().signal("public_ip"))

        h.platform.heldPublicIp!!("2001:db8::1")
        h.runDue()
        val sent = h.transport.sentEvents()
        val signal = sent.signal("public_ip")!!
        assertEquals("2001:db8::1", signal.getJSONObject("props").getString("ipv6"))
        assertTrue("queued when the answer arrives", signal.getLong("seq") > sent.named("registration").single().getLong("seq"))
    }

    @Test
    fun theLookupWaitsForThisVersionsConfigWhichCanTurnItOff() {
        val h = Harness()
        val off = Spec.json("config.response.json")
        off.getJSONObject("collect").put("public_ip", false)
        h.transport.configHandler = { HttpResponse(200, off.toString(), etag = FakeTransport.CONFIG_ETAG) }
        h.platform.publicIp = "2001:db8::1"
        h.launch()
        h.runDue()
        assertEquals(1, h.transport.configRequests().size)
        assertTrue("collect.public_ip false arrived before any lookup", h.platform.publicIpLookups.isEmpty())
        assertNull(h.transport.sentEvents().signal("public_ip"))
    }

    @Test
    fun adsConsentWithdrawnDuringTheLookupDropsTheAnswer() {
        val h = Harness()
        h.platform.holdPublicIp = true
        h.launch()
        h.runDue()
        h.run { it.setConsent(null, false, h.clock.now) }
        h.platform.heldPublicIp!!("2001:db8::1")
        h.runDue()
        assertNull(h.transport.sentEvents().signal("public_ip"))
        // Granted again: no second lookup, and the dropped answer stays dropped.
        h.run { it.setConsent(null, true, h.clock.now) }
        assertEquals(1, h.platform.publicIpLookups.size)
        assertNull(h.transport.sentEvents().signal("public_ip"))
    }

    // --- Remote config -------------------------------------------------------------------------

    @Test
    fun theConfigIsFetchedAtLaunchCachedForSixHoursAndRefetchedOnANewEtag() {
        val h = Harness()
        h.launch()
        h.runDue()
        assertEquals(1, h.transport.configRequests().size)
        assertNull(h.transport.configRequests()[0].headers["If-None-Match"])

        h.relaunch()
        h.runDue()
        assertEquals(1, h.transport.configRequests().size)

        h.clock.now += 6 * hour
        h.transport.configHandler = { HttpResponse(304, "") }
        h.relaunch()
        h.runDue()
        assertEquals(2, h.transport.configRequests().size)
        assertEquals(FakeTransport.CONFIG_ETAG, h.transport.configRequests()[1].headers["If-None-Match"])

        // A batch names another config version.
        h.transport.batchHandler = { FakeTransport.ackAll(it, etag = "\"2-b\"") }
        h.transport.configHandler = { HttpResponse(200, Spec.text("config.response.json"), etag = "\"2-b\"") }
        h.advance(Core.CONFIG_MIN_INTERVAL_MS)
        h.run { it.track("registration", emptyMap(), h.clock.now) }
        h.run { it.flush() }
        assertEquals(3, h.transport.configRequests().size)
        h.run { it.track("registration", emptyMap(), h.clock.now) }
        h.run { it.flush() }
        assertEquals("the same etag does not refetch", 3, h.transport.configRequests().size)
    }

    @Test
    fun everyRequestNamesTheAppVersionAndAnUpdateRefetchesAFreshConfig() {
        val h = Harness()
        h.launch()
        h.runDue()
        val first = h.transport.configRequests().single()
        assertEquals("5.12", first.headers["X-Afr-App-Version"])
        assertEquals("1310", first.headers["X-Afr-App-Build"])
        val batches = h.transport.requests.filter { it.url.endsWith("/v1/sdk/batch") }
        assertTrue(batches.isNotEmpty() && batches.all { it.headers["X-Afr-App-Version"] == "5.12" })
        assertEquals("the cache remembers the version it is for", "5.12", ConfigCache.parse(h.store.files[StoreFiles.CONFIG]).appVersion)

        h.platform.app = AppInfo("com.acme.other", "5.13", "1400")
        h.transport.configHandler = { HttpResponse(304, "") }
        h.clock.now += hour
        h.relaunch()
        h.runDue()
        assertEquals("a fresh copy fetched for 5.12 is fetched again for 5.13", 2, h.transport.configRequests().size)
        val refetch = h.transport.configRequests()[1]
        assertEquals("5.13", refetch.headers["X-Afr-App-Version"])
        assertEquals(FakeTransport.CONFIG_ETAG, refetch.headers["If-None-Match"])
        assertEquals("a 304 for 5.13 makes the copy 5.13's", "5.13", ConfigCache.parse(h.store.files[StoreFiles.CONFIG]).appVersion)

        h.relaunch()
        h.runDue()
        assertEquals("then cached for 6 h again", 2, h.transport.configRequests().size)
    }

    @Test
    fun nothingButTheConfigFetchGoesOutUntilThisVersionsConfigIsIn() {
        val h = Harness()
        h.platform.publicIp = "2001:db8::1"
        h.transport.configHandler = { HttpResponse(503, "") }
        h.launch()
        h.runDue()
        h.run { it.track("registration", emptyMap(), h.clock.now) }
        h.run { it.flush() }
        assertEquals("the config request is the only one", listOf("https://sdk.example.com/v1/sdk/config"), h.transport.requests.map { it.url })
        assertTrue(h.platform.publicIpLookups.isEmpty())
        assertEquals(0, h.platform.adIdReads)
        assertEquals("events are kept meanwhile", listOf("\$install", "\$open", "registration"), h.queued().map { it.getString("name") })

        // No answer: no timeout, the fetch is asked again with a back-off, and at once on a foreground.
        h.advance(5_000)
        assertEquals(2, h.transport.configRequests().size)
        h.run { it.onBackground(h.clock.now) }
        h.run { it.onForeground(h.clock.now) }
        assertEquals(3, h.transport.configRequests().size)
        h.advance(60_000)
        assertTrue(h.transport.batchRequests().isEmpty())

        h.transport.configHandler = { HttpResponse(200, Spec.text("config.response.json"), etag = FakeTransport.CONFIG_ETAG) }
        h.advance(300_000)
        assertEquals(listOf("\$install", "\$open", "registration"), names(h.transport.batches().first()))
        assertEquals("the collectors start with the config", 1, h.platform.publicIpLookups.size)
    }

    @Test
    fun offRecordsCollectsAndSendsNothing() {
        val off = Spec.json("config.response.json").put("off", true).put("enabled", false)
        val collect = off.getJSONObject("collect")
        for (k in collect.keys().asSequence().toList()) collect.put(k, false)
        val h = Harness()
        h.platform.publicIp = "2001:db8::1"
        h.transport.configHandler = { HttpResponse(200, off.toString(), etag = FakeTransport.CONFIG_ETAG) }
        h.launch()
        h.runDue()
        h.run { it.track("registration", emptyMap(), h.clock.now) }
        h.run { it.setUserId("u1", h.clock.now) }
        h.run { it.flush() }
        assertEquals(listOf("https://sdk.example.com/v1/sdk/config"), h.transport.requests.map { it.url })
        assertTrue("the launch's own events are dropped too", h.queued().isEmpty())
        assertTrue(h.platform.publicIpLookups.isEmpty())
        assertEquals(0, h.platform.adIdReads)

        // The next launch, same version, fresh copy: nothing at all, not even a config fetch.
        h.clock.now += 60_000
        h.relaunch()
        h.runDue()
        assertEquals(1, h.transport.requests.size)
        assertTrue(h.queued().isEmpty())

        // Six hours on, Kerdly switched it back on: the launch fetches, then records and sends again.
        h.transport.configHandler = { HttpResponse(200, Spec.text("config.response.json"), etag = "\"2-on\"") }
        h.clock.now += 7 * hour
        h.relaunch()
        h.runDue()
        h.run { it.track("registration", emptyMap(), h.clock.now) }
        h.run { it.flush() }
        val names = h.transport.sentEvents().map { it.getString("name") }
        assertTrue("what follows the config that says on is sent", "registration" in names)
        assertFalse("an install first seen while off is never reported", "\$install" in names)
    }

    @Test
    fun theKillSwitchStopsSendingButKeepsReservedEvents() {
        val h = Harness()
        val off = Spec.json("config.response.json").put("enabled", false)
        h.transport.configHandler = { HttpResponse(200, off.toString(), etag = "\"2-off\"") }
        h.launch()
        h.runDue()
        val sentBefore = h.transport.batchRequests().size

        h.run { it.track("registration", emptyMap(), h.clock.now) }
        h.run { it.setUserId("u1", h.clock.now) }
        h.run { it.flush() }
        h.advance(10 * 60_000)
        assertEquals(sentBefore, h.transport.batchRequests().size)
        val queued = h.queued().map { it.getString("name") }
        assertTrue(queued.contains("\$identify"))
        assertFalse(queued.contains("registration"))

        // Turned back on: the next stale-config launch fetches it and sends the backlog.
        h.transport.configHandler = { HttpResponse(200, Spec.text("config.response.json"), etag = "\"3-on\"") }
        h.clock.now += 6 * hour
        h.relaunch()
        h.runDue()
        assertTrue(h.transport.batchRequests().size > sentBefore)
        assertTrue(h.queued().isEmpty())
    }

    @Test
    fun blockedEventsAreDroppedOnTheDevice() {
        val h = Harness()
        val config = Spec.json("config.response.json")
        config.getJSONObject("events").put("block", org.json.JSONArray(listOf("noisy")))
        h.transport.configHandler = { HttpResponse(200, config.toString(), etag = FakeTransport.CONFIG_ETAG) }
        h.launch()
        h.runDue()
        h.run { it.track("noisy", emptyMap(), h.clock.now) }
        h.run { it.track("quiet", emptyMap(), h.clock.now) }
        h.run { it.flush() }
        assertTrue(h.transport.sentEvents().named("noisy").isEmpty())
        assertEquals(1, h.transport.sentEvents().named("quiet").size)
    }

    @Test
    fun anSdkBelowTheMinimumStopsSending() {
        val h = Harness()
        val config = Spec.json("config.response.json").put("min_supported_sdk", "99.0.0")
        h.transport.configHandler = { HttpResponse(200, config.toString(), etag = FakeTransport.CONFIG_ETAG) }
        h.launch()
        h.runDue()
        val before = h.transport.batchRequests().size
        h.run { it.setUserId("u1", h.clock.now) }
        h.advance(60_000)
        assertEquals(before, h.transport.batchRequests().size)
    }

    // --- Attribution ---------------------------------------------------------------------------

    @Test
    fun attributionFromABatchResponseReachesListenersOnce() {
        val h = Harness()
        val attribution = Spec.json("batch.response.json").getJSONObject("attribution")
        h.transport.batchHandler = { FakeTransport.ackAll(it, attribution = attribution) }
        h.launch(buffered = listOf { c -> c.addAttributionListener { h.delivered.add(it) } })
        h.runDue()
        h.run { it.track("registration", emptyMap(), h.clock.now) }
        h.run { it.flush() }

        assertEquals(1, h.delivered.size)
        assertEquals("meta", h.delivered[0].network)
        assertEquals("cpp_deeplink", h.delivered[0].method)
        assertEquals("ce3a1b2c-0000-4000-8000-000000000001", h.delivered[0].cppId)
        assertEquals(h.delivered[0], h.core.attribution)

        // Cached across launches; a listener added later gets it at once.
        h.relaunch()
        h.runDue()
        assertEquals("meta", h.core.attribution?.network)
        h.run { c -> c.addAttributionListener { h.delivered.add(it) } }
        assertEquals(2, h.delivered.size)

        // A change is delivered.
        val final = JSONObject(attribution.toString()).put("state", "final")
        h.transport.batchHandler = { FakeTransport.ackAll(it, attribution = final) }
        h.run { it.track("registration", emptyMap(), h.clock.now) }
        h.run { it.flush() }
        assertEquals(3, h.delivered.size)
        assertEquals("final", h.delivered[2].state)
    }

    @Test
    fun atMostThreeAttributionPollsInTheFirstMinute() {
        val h = Harness()
        h.launch()
        h.runDue()
        h.advance(10 * 60_000)
        val polls = h.transport.attributionRequests()
        assertEquals(3, polls.size)
        assertTrue(polls.all { it.method == "GET" && it.url.endsWith("/v1/sdk/attribution?install_id=${Harness.FIXTURE_INSTALL_ID}") })
        assertTrue(polls.all { it.headers["Authorization"] == "Bearer pk_test_123" })

        h.relaunch()
        h.runDue()
        h.advance(10 * 60_000)
        assertEquals("only a fresh install polls", 3, h.transport.attributionRequests().size)
    }

    @Test
    fun pollingStopsOnceTheAttributionIsKnown() {
        val h = Harness()
        val attribution = Spec.json("batch.response.json").getJSONObject("attribution")
        h.transport.attributionHandler = { HttpResponse(200, JSONObject().put("attribution", attribution).toString()) }
        h.launch(buffered = listOf { c -> c.addAttributionListener { h.delivered.add(it) } })
        h.runDue()
        h.advance(60_000)
        assertEquals(1, h.transport.attributionRequests().size)
        assertEquals(1, h.delivered.size)
    }

    @Test
    fun noPollBeforeTheCollectorHasTheInstall() {
        val h = Harness()
        h.transport.batchHandler = { HttpResponse(503, "") }
        h.launch()
        h.runDue()
        h.advance(60_000)
        assertTrue(h.transport.attributionRequests().isEmpty())
    }
}
