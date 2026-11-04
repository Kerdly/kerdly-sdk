package com.kerdly.sdk.internal

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

// Helpers over org.json that behave the same on Android's implementation and the reference
// one used by the JVM tests (they differ on NULL handling in optString and friends).

/** `put` that writes JSON null for a Kotlin null (Android's `put(key, null)` removes the key). */
internal fun JSONObject.putNullable(key: String, value: Any?): JSONObject = put(key, value ?: JSONObject.NULL)

internal fun JSONObject.stringOrNull(key: String): String? {
    if (!has(key) || isNull(key)) return null
    return when (val v = opt(key)) {
        is String -> v
        is Number, is Boolean -> v.toString()
        else -> null
    }
}

internal fun JSONObject.longOrNull(key: String): Long? {
    if (!has(key) || isNull(key)) return null
    return when (val v = opt(key)) {
        is Number -> {
            val d = v.toDouble()
            if (d.isFinite()) v.toLong() else null
        }
        is String -> v.trim().toLongOrNull()
        else -> null
    }
}

internal fun JSONObject.intOrNull(key: String): Int? =
    longOrNull(key)?.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()

internal fun JSONObject.boolOrNull(key: String): Boolean? {
    if (!has(key) || isNull(key)) return null
    return opt(key) as? Boolean
}

internal fun JSONArray.strings(): List<String> {
    val out = ArrayList<String>(length())
    for (i in 0 until length()) {
        if (isNull(i)) continue
        val v = opt(i)
        if (v is String) out.add(v)
    }
    return out
}

/** Parses a JSON object; null for blank, malformed or non-object text. */
internal fun parseObject(text: String?): JSONObject? {
    if (text.isNullOrBlank()) return null
    return try {
        JSONObject(text)
    } catch (e: Exception) {
        null
    }
}

/** Structural JSON equality: key order is ignored and 5 equals 5.0 (Android's org.json has no
 * `similar`). */
internal fun jsonEquals(a: Any?, b: Any?): Boolean {
    val x = if (a == null) JSONObject.NULL else a
    val y = if (b == null) JSONObject.NULL else b
    return when {
        x is JSONObject && y is JSONObject -> {
            if (x.length() != y.length()) return false
            val keys = x.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                if (!y.has(k) || !jsonEquals(x.opt(k), y.opt(k))) return false
            }
            true
        }
        x is JSONArray && y is JSONArray -> {
            if (x.length() != y.length()) return false
            (0 until x.length()).all { jsonEquals(x.opt(it), y.opt(it)) }
        }
        x is Number && y is Number -> x.toDouble() == y.toDouble()
        else -> x == y
    }
}

internal fun utf8Length(s: String): Int {
    var n = 0
    var i = 0
    while (i < s.length) {
        val c = s[i]
        when {
            c.code < 0x80 -> n += 1
            c.code < 0x800 -> n += 2
            Character.isHighSurrogate(c) && i + 1 < s.length && Character.isLowSurrogate(s[i + 1]) -> {
                n += 4
                i++
            }
            else -> n += 3
        }
        i++
    }
    return n
}

private val HEX = "0123456789abcdef".toCharArray()

internal fun sha1Hex(s: String): String {
    val digest = MessageDigest.getInstance("SHA-1").digest(s.toByteArray(Charsets.UTF_8))
    val out = CharArray(digest.size * 2)
    for (i in digest.indices) {
        val b = digest[i].toInt() and 0xff
        out[i * 2] = HEX[b ushr 4]
        out[i * 2 + 1] = HEX[b and 0x0f]
    }
    return String(out)
}
