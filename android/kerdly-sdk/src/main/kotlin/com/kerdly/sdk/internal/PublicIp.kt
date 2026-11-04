package com.kerdly.sdk.internal

import java.net.URI

/** The public IPv6 lookup: the echo URL, its answer, and which answers count. */
internal object PublicIp {
    const val DEFAULT_ECHO_URL = "https://api6.ipify.org?format=json"

    /** `ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255`: no IPv6 literal is longer. */
    private const val MAX_TEXT = 45

    /** [raw] when it is an absolute `https` URL with a host, else the default. */
    fun echoUrl(raw: String?): String {
        val s = raw?.trim() ?: return DEFAULT_ECHO_URL
        val uri = try {
            URI(s)
        } catch (e: Exception) {
            return DEFAULT_ECHO_URL
        }
        return if (uri.scheme.equals("https", ignoreCase = true) && !uri.host.isNullOrEmpty()) s else DEFAULT_ECHO_URL
    }

    /** The `ip` of the echo's `{"ip": "…"}`; null for any other answer. */
    fun parseEcho(body: String?): String? = parseObject(body)?.opt("ip") as? String

    /** [text] in RFC 5952 form (lowercase, the longest zero run as `::`) when it is a global
     * unicast IPv6 address (2000::/3); null for IPv4, v4-mapped, loopback, link-local, ULA,
     * multicast, a zone id or anything unparsable. The literal is parsed here, never through
     * `InetAddress`, which would resolve a host name. */
    fun globalIpv6(text: String?): String? {
        val groups = parse(text?.trim() ?: return null) ?: return null
        if (groups[0] and 0xE000 != 0x2000) return null
        return format(groups)
    }

    /** The eight 16-bit groups of an IPv6 literal (`::` and a dotted IPv4 tail allowed), or null. */
    private fun parse(s: String): IntArray? {
        if (s.isEmpty() || s.length > MAX_TEXT) return null
        val gap = s.indexOf("::")
        val groups = IntArray(8)
        if (gap < 0) {
            val all = groups(s.split(':'), ipv4Tail = true) ?: return null
            if (all.size != 8) return null
            all.forEachIndexed { i, g -> groups[i] = g }
            return groups
        }
        if (s.indexOf("::", gap + 1) >= 0) return null
        // An IPv4 tail ends the address, so only the part after `::` may carry one.
        val head = if (gap == 0) emptyList() else groups(s.substring(0, gap).split(':'), ipv4Tail = false) ?: return null
        val tail = if (gap + 2 == s.length) emptyList() else groups(s.substring(gap + 2).split(':'), ipv4Tail = true) ?: return null
        if (head.size + tail.size > 7) return null
        head.forEachIndexed { i, g -> groups[i] = g }
        tail.forEachIndexed { i, g -> groups[8 - tail.size + i] = g }
        return groups
    }

    private fun groups(pieces: List<String>, ipv4Tail: Boolean): List<Int>? {
        val out = ArrayList<Int>(8)
        for ((i, p) in pieces.withIndex()) {
            if (ipv4Tail && i == pieces.lastIndex && '.' in p) {
                val v4 = ipv4(p) ?: return null
                out.add(v4 ushr 16)
                out.add(v4 and 0xFFFF)
            } else {
                if (p.isEmpty() || p.length > 4 || !p.all { isHex(it) }) return null
                out.add(p.toInt(16))
            }
        }
        return out
    }

    /** Four decimal octets without leading zeros, as 32 bits. */
    private fun ipv4(s: String): Int? {
        val parts = s.split('.')
        if (parts.size != 4) return null
        var v = 0
        for (p in parts) {
            if (p.isEmpty() || p.length > 3 || !p.all { it in '0'..'9' } || (p.length > 1 && p[0] == '0')) return null
            val n = p.toInt()
            if (n > 255) return null
            v = (v shl 8) or n
        }
        return v
    }

    private fun isHex(c: Char): Boolean = c in '0'..'9' || c in 'a'..'f' || c in 'A'..'F'

    /** RFC 5952 §4: the longest run of two or more zero groups (the first of equal runs) is `::`. */
    private fun format(groups: IntArray): String {
        var gapStart = -1
        var gapLen = 1
        var i = 0
        while (i < 8) {
            if (groups[i] != 0) {
                i++
                continue
            }
            var j = i
            while (j < 8 && groups[j] == 0) j++
            if (j - i > gapLen) {
                gapStart = i
                gapLen = j - i
            }
            i = j
        }
        val sb = StringBuilder()
        i = 0
        while (i < 8) {
            if (i == gapStart) {
                sb.append("::")
                i += gapLen
                continue
            }
            if (i > 0 && i != gapStart + gapLen) sb.append(':')
            sb.append(Integer.toHexString(groups[i]))
            i++
        }
        return sb.toString()
    }
}
