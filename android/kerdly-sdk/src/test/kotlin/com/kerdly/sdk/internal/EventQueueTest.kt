package com.kerdly.sdk.internal

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EventQueueTest {
    private var n = 0

    private fun event(name: String, seq: Long, pad: Int = 0): QueuedEvent {
        val id = "00000000-0000-4000-8000-%012d".format(++n)
        val o = JSONObject().put("id", id).put("name", name).put("ts", 1L).put("seq", seq)
            .put("props", JSONObject().put("pad", "x".repeat(pad)))
        return QueuedEvent(id, name, seq, o.toString())
    }

    @Test
    fun keepsSeqOrderEvenForAReEnqueuedOlderEvent() {
        val q = EventQueue()
        q.add(event("a", 1))
        q.add(event("b", 3))
        q.add(event("c", 2))
        assertEquals(listOf(1L, 2L, 3L), q.events().map { it.seq })
        assertEquals(4L, q.nextSeq)
    }

    @Test
    fun aDuplicateIdIsIgnored() {
        val q = EventQueue()
        val e = event("a", 1)
        q.add(e)
        q.add(e)
        assertEquals(1, q.size)
    }

    @Test
    fun whenFullTheOldestCustomEventGoesAndReservedEventsStay() {
        val q = EventQueue(softMaxEvents = 3)
        q.add(event("\$install", 1))
        q.add(event("first", 2))
        q.add(event("\$open", 3))
        val dropped = q.add(event("second", 4))
        assertEquals(listOf("first"), dropped.map { it.name })
        assertEquals(listOf("\$install", "\$open", "second"), q.events().map { it.name })

        // Reserved events are never dropped for the soft limit…
        q.add(event("\$signal", 5))
        q.add(event("\$identify", 6))
        assertEquals(listOf("\$install", "\$open", "\$signal", "\$identify"), q.events().map { it.name })
        // …and a new custom event is itself the oldest custom one.
        assertEquals(listOf("late"), q.add(event("late", 7)).map { it.name })
    }

    @Test
    fun theByteLimitAppliesToo() {
        val q = EventQueue(softMaxBytes = 2_000)
        q.add(event("a", 1, pad = 900))
        q.add(event("b", 2, pad = 900))
        val dropped = q.add(event("c", 3, pad = 900))
        assertEquals(listOf("a"), dropped.map { it.name })
        assertTrue(q.bytes <= 2_000)
    }

    @Test
    fun theHardLimitDropsOpensFirstAndNeverTheInstall() {
        val q = EventQueue(softMaxEvents = 2, hardMaxEvents = 3)
        q.add(event("\$install", 1))
        q.add(event("\$signal", 2))
        q.add(event("\$open", 3))
        assertEquals(listOf("\$open"), q.add(event("\$signal", 4)).map { it.name })
        assertEquals(listOf("\$signal"), q.add(event("\$identify", 5)).map { it.name })
        assertEquals("\$install", q.events().first().name)
    }

    @Test
    fun removeById() {
        val q = EventQueue()
        val a = event("a", 1)
        val b = event("b", 2)
        q.add(a)
        q.add(b)
        assertEquals(1, q.remove(listOf(a.id, "unknown")))
        assertFalse(q.contains(a.id))
        assertTrue(q.contains(b.id))
        assertEquals(b.bytes.toLong(), q.bytes)
    }

    @Test
    fun serializeAndParseRoundTrip() {
        val q = EventQueue()
        q.add(event("\$install", 1))
        q.add(event("registration", 2))
        q.nextSeq = 9
        val text = q.serialize("4d5e6f7a-8b9c-4d0e-9f1a-2b3c4d5e6f71")
        val back = EventQueue.parse(text, "4d5e6f7a-8b9c-4d0e-9f1a-2b3c4d5e6f71")!!
        assertEquals(listOf("\$install", "registration"), back.events().map { it.name })
        assertEquals(9L, back.nextSeq)
        assertTrue(jsonEquals(JSONObject(q.events()[1].json), JSONObject(back.events()[1].json)))
    }

    @Test
    fun anotherInstallsQueueIsNotLoaded() {
        val q = EventQueue()
        q.add(event("a", 1))
        assertNull(EventQueue.parse(q.serialize("aaaaaaaa-0000-4000-8000-000000000000"), "bbbbbbbb-0000-4000-8000-000000000000"))
        assertNull(EventQueue.parse("not json", "x"))
        assertNull(EventQueue.parse(null, "x"))
    }

    @Test
    fun parseSkipsBrokenEventsAndRepairsTheCounter() {
        val text = """{"v":1,"install_id":"i","next_seq":1,"events":[{"id":"a","name":"x","seq":5,"ts":1,"props":{}},{"name":"no-id","seq":6},7]}"""
        val q = EventQueue.parse(text, "i")!!
        assertEquals(1, q.size)
        assertEquals(6L, q.nextSeq)
    }
}
