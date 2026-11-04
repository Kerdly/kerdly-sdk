package com.kerdly.sdk.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PublicIpTest {
    @Test
    fun globalUnicastAddressesComeBackInCanonicalForm() {
        val cases = linkedMapOf(
            "2001:db8::1" to "2001:db8::1",
            "2A02:06B8:0000:0000:0000:0000:0000:0001" to "2a02:6b8::1",
            " 2607:f8b0:4005:80b::200e\n" to "2607:f8b0:4005:80b::200e",
            "2001:db8:0:0:1:0:0:1" to "2001:db8::1:0:0:1", // the first of two equal runs
            "2001:0:0:1:0:0:0:1" to "2001:0:0:1::1", // the longest run
            "2001:db8:0:1:1:1:1:1" to "2001:db8:0:1:1:1:1:1", // one zero group is not compressed
            "2001:db8:1:2:3:4:5::" to "2001:db8:1:2:3:4:5:0",
            "2001:db8::" to "2001:db8::",
            "2001:db8::192.0.2.1" to "2001:db8::c000:201",
            "3fff:ffff:ffff:ffff:ffff:ffff:255.255.255.255" to "3fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
        )
        for ((text, canonical) in cases) assertEquals(text, canonical, PublicIp.globalIpv6(text))
    }

    @Test
    fun everythingOutside2000Slash3OrUnparsableIsDropped() {
        val bad = listOf(
            null, "", " ",
            "203.0.113.7", // IPv4
            "::ffff:203.0.113.7", "::ffff:cb00:7107", // v4-mapped
            "::1", "::", // loopback, unspecified
            "fe80::1", "fe80::1%wlan0", // link-local, with a zone id
            "fd12:3456:789a::1", "fc00::1", // ULA
            "ff02::1", // multicast
            "64:ff9b::203.0.113.7", // NAT64
            "1fff:ffff::1", "4000::1", // just outside 2000::/3
            "[2001:db8::1]", "2001:db8::1/64", "2001:db8::1 2001:db8::2",
            "2001:db8:::1", "2001::db8::1", ":2001:db8::1", "2001:db8::1:", "2001:db8:1:2:3:4:5:6:7",
            "2001:db8:1:2:3:4:5", "2001:db8:1:2:3:4:5::6", "2001:db8::12345", "2001:db8::g", "2001:db8::-1",
            "2001:db8::+1", "2001:db8::1.2.3", "2001:db8::256.1.1.1", "2001:db8::01.2.3.4",
            "2001:db8::1.2.3.4:1", "1.2.3.4::", "2001:db8:" + "0:".repeat(20) + "1",
            "localhost", "api6.ipify.org",
        )
        for (text in bad) assertNull(text, PublicIp.globalIpv6(text))
    }

    @Test
    fun theEchoAnswersIp() {
        assertEquals("2001:db8::1", PublicIp.parseEcho("""{"ip":"2001:db8::1"}"""))
        assertNull(PublicIp.parseEcho("""{"ip":null}"""))
        assertNull(PublicIp.parseEcho("""{"ip":42}"""))
        assertNull(PublicIp.parseEcho("""{"address":"2001:db8::1"}"""))
        assertNull(PublicIp.parseEcho("2001:db8::1"))
        assertNull(PublicIp.parseEcho(""))
        assertNull(PublicIp.parseEcho(null))
    }
}
