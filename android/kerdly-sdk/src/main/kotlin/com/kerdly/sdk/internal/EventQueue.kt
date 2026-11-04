package com.kerdly.sdk.internal

import org.json.JSONObject

/** One event as it goes on the wire. [json] is the serialized envelope, built
 * once at enqueue and reused for every retry, so the id and payload never change. */
internal class QueuedEvent(val id: String, val name: String, val seq: Long, val json: String) {
    val bytes: Int = utf8Length(json)
    val reserved: Boolean get() = EventNames.isReserved(name)

    companion object {
        fun fromJson(o: JSONObject): QueuedEvent? {
            val id = o.stringOrNull("id") ?: return null
            val name = o.stringOrNull("name") ?: return null
            val seq = o.longOrNull("seq") ?: return null
            return QueuedEvent(id, name, seq, o.toString())
        }
    }
}

/** The persistent queue, kept in `seq` order.
 *
 * Capacity: at [softMaxEvents] events or [softMaxBytes] the oldest custom event goes; reserved
 * events are never dropped for it. [hardMaxEvents] / [hardMaxBytes] only guard against an
 * endless pile of reserved events (a collector unreachable for months): past them the oldest
 * `$open` goes first, then the oldest event other than `$install`. */
internal class EventQueue(
    private val softMaxEvents: Int = 1_000,
    private val softMaxBytes: Long = 1_000_000,
    private val hardMaxEvents: Int = 5_000,
    private val hardMaxBytes: Long = 5_000_000,
) {
    private val list = ArrayList<QueuedEvent>()
    private val ids = HashSet<String>()

    /** The next `seq` to hand out; never reused within an install. */
    var nextSeq: Long = 1

    var bytes: Long = 0
        private set

    val size: Int get() = list.size

    fun isEmpty(): Boolean = list.isEmpty()

    fun events(): List<QueuedEvent> = list

    fun contains(id: String): Boolean = id in ids

    fun maxSeq(): Long = list.maxOfOrNull { it.seq } ?: 0

    /** Inserts in `seq` order and returns what the capacity rules dropped (possibly [event]). */
    fun add(event: QueuedEvent): List<QueuedEvent> {
        if (!ids.add(event.id)) return emptyList()
        var i = list.size
        while (i > 0 && list[i - 1].seq > event.seq) i--
        list.add(i, event)
        bytes += event.bytes
        if (event.seq >= nextSeq) nextSeq = event.seq + 1
        return trim()
    }

    /** Removes these ids; returns how many were queued. */
    fun remove(toRemove: Collection<String>): Int {
        if (toRemove.isEmpty()) return 0
        val set = toRemove as? Set<String> ?: toRemove.toHashSet()
        var removed = 0
        val it = list.iterator()
        while (it.hasNext()) {
            val e = it.next()
            if (e.id in set) {
                it.remove()
                ids.remove(e.id)
                bytes -= e.bytes
                removed++
            }
        }
        return removed
    }

    private fun removeAt(index: Int): QueuedEvent {
        val e = list.removeAt(index)
        ids.remove(e.id)
        bytes -= e.bytes
        return e
    }

    private fun trim(): List<QueuedEvent> {
        var dropped: MutableList<QueuedEvent>? = null
        while (list.size > softMaxEvents || bytes > softMaxBytes) {
            val i = list.indexOfFirst { !it.reserved }
            if (i < 0) break
            (dropped ?: ArrayList<QueuedEvent>().also { dropped = it }).add(removeAt(i))
        }
        while (list.size > hardMaxEvents || bytes > hardMaxBytes) {
            var i = list.indexOfFirst { it.name == EventNames.OPEN }
            if (i < 0) i = list.indexOfFirst { it.name != EventNames.INSTALL }
            if (i < 0) break
            (dropped ?: ArrayList<QueuedEvent>().also { dropped = it }).add(removeAt(i))
        }
        return dropped ?: emptyList()
    }

    /** `{"v":1,"install_id":…,"next_seq":…,"events":[…]}`; the event JSON is spliced in as built. */
    fun serialize(installId: String): String {
        val sb = StringBuilder(bytes.toInt().coerceAtMost(Int.MAX_VALUE - 256) + 128)
        sb.append("{\"v\":1,\"install_id\":").append(JSONObject.quote(installId))
        sb.append(",\"next_seq\":").append(nextSeq)
        sb.append(",\"events\":[")
        list.forEachIndexed { i, e ->
            if (i > 0) sb.append(',')
            sb.append(e.json)
        }
        sb.append("]}")
        return sb.toString()
    }

    companion object {
        /** Null when [text] is not a queue of [installId] (absent, unreadable, or another install's). */
        fun parse(text: String?, installId: String): EventQueue? {
            val o = parseObject(text) ?: return null
            if (o.stringOrNull("install_id") != installId) return null
            val queue = EventQueue()
            val events = o.optJSONArray("events")
            if (events != null) {
                for (i in 0 until events.length()) {
                    val e = events.optJSONObject(i) ?: continue
                    QueuedEvent.fromJson(e)?.let { queue.add(it) }
                }
            }
            queue.nextSeq = maxOf(o.longOrNull("next_seq") ?: 1, queue.maxSeq() + 1, 1)
            return queue
        }
    }
}
