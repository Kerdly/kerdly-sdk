package com.kerdly.sdk.internal

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class BatchTest {
    private val envelopeInfo = BatchBody.Envelope(
        sdkName = "afr-android",
        sdkVersion = "0.1.0",
        wrapper = null,
        bundle = "com.acme.other",
        appVersion = "5.12",
        appBuild = "1310",
        environment = "production",
        installId = "4d5e6f7a-8b9c-4d0e-9f1a-2b3c4d5e6f71",
    )

    private fun event(i: Int, pad: Int = 0): QueuedEvent {
        val id = "00000000-0000-4000-8000-%012d".format(i)
        val o = JSONObject().put("id", id).put("name", "e$i").put("ts", 1L).put("seq", i.toLong())
            .put("props", JSONObject().put("pad", "x".repeat(pad)))
        return QueuedEvent(id, "e$i", i.toLong(), o.toString())
    }

    @Test
    fun theBodySplicesTheEventsIntoTheEnvelope() {
        val context = JSONObject().put("platform", "android")
        val envelope = BatchBody.envelope(envelopeInfo, 1_760_400_005_000L, context)
        val body = JSONObject(BatchBody.join(envelope, listOf(event(1), event(2))))
        assertEquals(setOf("sdk", "app", "install_id", "sent_at", "context", "events"), body.keyList())
        assertEquals(setOf("name", "version"), body.getJSONObject("sdk").keyList())
        assertEquals(setOf("bundle", "version", "build", "environment"), body.getJSONObject("app").keyList())
        assertEquals(1_760_400_005_000L, body.getLong("sent_at"))
        assertEquals(listOf("e1", "e2"), body.getJSONArray("events").objects().map { it.getString("name") })

        val noContext = JSONObject(BatchBody.join(BatchBody.envelope(envelopeInfo, 1L, null), listOf(event(1))))
        assertFalse(noContext.has("context"))
        val wrapped = JSONObject(BatchBody.envelope(BatchBody.Envelope("afr-android", "0.1.0", "expo/0.1.0", "b", null, null, "development", "i"), 1L, null))
        assertEquals("expo/0.1.0", wrapped.getJSONObject("sdk").getString("wrapper"))
        assertTrue(wrapped.getJSONObject("app").isNull("version"))
    }

    @Test
    fun selectionStopsAtFiftyEventsOr256Kb() {
        val events = (1..60).map { event(it) }
        assertEquals(50, BatchBody.select(events, 50, BatchBody.MAX_BODY_BYTES).size)
        assertEquals(7, BatchBody.select(events, 7, BatchBody.MAX_BODY_BYTES).size)

        val big = (1..10).map { event(it, pad = 60_000) }
        val envelope = BatchBody.envelope(envelopeInfo, 1L, JSONObject().put("platform", "android"))
        val picked = BatchBody.select(big, 50, BatchBody.eventBudget(envelope))
        assertEquals(4, picked.size)
        assertTrue(BatchBody.join(envelope, picked).toByteArray().size <= BatchBody.MAX_BODY_BYTES)
    }

    @Test
    fun statusesMapToTheSpecActions() {
        val ack = """{"accepted":["a"],"rejected":[],"config_etag":"\"1\"","attribution":null,"needs":[],"cv_hints":[]}"""
        assertTrue(BatchResponses.classify(200, ack, null) is SendOutcome.Acked)
        val unreadable = BatchResponses.classify(200, "<html>", null)
        assertTrue(unreadable is SendOutcome.Retry)

        val malformed = BatchResponses.classify(400, """{"error":"x","code":"malformed"}""", null) as SendOutcome.Drop
        assertFalse(malformed.stop)
        assertEquals("malformed", malformed.code)
        assertTrue((BatchResponses.classify(401, """{"error":"x","code":"bad_key"}""", null) as SendOutcome.Drop).stop)
        val forbidden = BatchResponses.classify(403, """{"error":"x","code":"key_revoked"}""", null) as SendOutcome.Drop
        assertTrue(forbidden.stop)
        assertEquals("key_revoked", forbidden.code)
        assertFalse((BatchResponses.classify(404, "", null) as SendOutcome.Drop).stop)

        assertEquals(30_000L, (BatchResponses.classify(429, "", "30") as SendOutcome.Retry).retryAfterMs)
        assertNull((BatchResponses.classify(408, "", null) as SendOutcome.Retry).retryAfterMs)
        assertTrue(BatchResponses.classify(413, "", null) === SendOutcome.Split)
        assertEquals(5_000L, (BatchResponses.classify(503, "", " 5 ") as SendOutcome.Retry).retryAfterMs)
        assertTrue(BatchResponses.classify(500, "", null) is SendOutcome.Retry)
        assertTrue("a redirect is not followed", BatchResponses.classify(302, "", null) is SendOutcome.Retry)
    }

    @Test
    fun retryAfterParsing() {
        assertEquals(0L, BatchResponses.parseRetryAfter("0"))
        assertNull(BatchResponses.parseRetryAfter("-3"))
        assertNull(BatchResponses.parseRetryAfter("Wed, 21 Oct 2026 07:28:00 GMT"))
        assertNull(BatchResponses.parseRetryAfter(null))
        assertEquals(BatchResponses.MAX_RETRY_AFTER_S * 1000, BatchResponses.parseRetryAfter("999999999"))
    }

    @Test
    fun anAckWithMissingListsIsEmpty() {
        val ack = BatchResponses.parseAck("""{"rejected":[{"reason":"invalid_ts"}]}""")!!
        assertTrue(ack.accepted.isEmpty())
        assertNull(ack.rejected.single().id)
        assertEquals("invalid_ts", ack.rejected.single().reason)
        assertNull(ack.configEtag)
        assertNull(ack.attribution)
        assertNull(BatchResponses.parseAck("[]"))
    }

    @Test
    fun backoffGrowsFromOneSecondToFiveMinutesWithFullJitter() {
        assertEquals(1_000L, Backoff.capMs(1))
        assertEquals(2_000L, Backoff.capMs(2))
        assertEquals(4_000L, Backoff.capMs(3))
        assertEquals(256_000L, Backoff.capMs(9))
        assertEquals(300_000L, Backoff.capMs(10))
        assertEquals(300_000L, Backoff.capMs(1_000))
        val random = Random(1)
        for (attempt in 1..40) {
            repeat(50) {
                val d = Backoff.delayMs(attempt, random)
                assertTrue("attempt $attempt: $d", d in 1_000L..Backoff.capMs(attempt))
            }
        }
        // Jitter: the delays of one attempt spread out.
        val spread = (1..200).map { Backoff.delayMs(10, random) }
        assertTrue(spread.maxOrNull()!! - spread.minOrNull()!! > 100_000)
    }
}
