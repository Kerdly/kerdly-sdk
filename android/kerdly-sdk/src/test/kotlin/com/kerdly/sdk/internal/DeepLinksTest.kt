package com.kerdly.sdk.internal

import com.kerdly.sdk.KerdlyDeepLink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeepLinksTest {
    @Test
    fun customSchemeWithTheSlugInTheHost() {
        val link = DeepLinks.parse("com.acme.app://onboarding?cpp=web-meta")!!
        assertEquals("web-meta", link.cpp)
        assertNull(link.ppid)
        assertNull(link.clickId)
        assertEquals("com.acme.app://onboarding?cpp=web-meta", link.url)
    }

    @Test
    fun appLinkWithTheHostBeforeThePath() {
        // The old app read "onboarding" as the host and lost these.
        val link = DeepLinks.parse(
            "https://acme-app.com/onboarding?cpp=california&ppid=ce3a1b2c-0000-4000-8000-000000000001&kerdly_c=k3f9q2xab7mn&kerdly_v=abcd1234efgh5678",
        )!!
        assertEquals(
            KerdlyDeepLink(
                url = "https://acme-app.com/onboarding?cpp=california&ppid=ce3a1b2c-0000-4000-8000-000000000001&kerdly_c=k3f9q2xab7mn&kerdly_v=abcd1234efgh5678",
                cpp = "california",
                ppid = "ce3a1b2c-0000-4000-8000-000000000001",
                clickId = "k3f9q2xab7mn",
                visitId = "abcd1234efgh5678",
                campaignIds = null,
            ),
            link,
        )
        assertTrue(DeepLinks.isAttributionBearing(link))
    }

    @Test
    fun anyPathDepthAndNoHost() {
        assertEquals("x", DeepLinks.parse("acmeapp:///a/b/c?kerdly_c=x")!!.clickId)
        assertEquals("y", DeepLinks.parse("acme:?cpp=y")!!.cpp)
        assertEquals("z", DeepLinks.parse("https://go.acme-app.com/l/abc/?utm_source=meta&kerdly_v=z")!!.visitId)
    }

    @Test
    fun linksMadeBefore010AreReadUnderTheirAfrNames() {
        val old = DeepLinks.parse("https://go.acme-app.com/l/abc?afr_c=k3f9q2xab7mn&afr_v=v123")!!
        assertEquals("k3f9q2xab7mn", old.clickId)
        assertEquals("v123", old.visitId)
        assertTrue(DeepLinks.isAttributionBearing(old))
        val props = ReservedProps.deeplink(old, "runtime")
        assertEquals("k3f9q2xab7mn", props.getString("kerdly_c"))
        assertFalse(props.has("afr_c"))
        assertEquals("new", DeepLinks.parse("acmeapp://open?afr_c=old&kerdly_c=new")!!.clickId)
    }

    @Test
    fun campaignIdsArriveAsGivenWithPlusSigns() {
        val link = DeepLinks.parse("fb123://app?campaign_ids=ARAb+c/d%3D%3D&cpp=")!!
        assertEquals("ARAb+c/d==", link.campaignIds)
        assertNull("an empty value is absent", link.cpp)
        assertFalse("campaign_ids alone is not kept pending", DeepLinks.isAttributionBearing(link))
    }

    @Test
    fun percentDecodingIsUtf8AndToleratesBrokenEscapes() {
        assertEquals("niño pruebas", DeepLinks.parse("acmeapp://x?cpp=ni%C3%B1o%20pruebas")!!.cpp)
        assertEquals("100%", DeepLinks.parse("acmeapp://x?cpp=100%")!!.cpp)
        assertEquals("a%zzb", DeepLinks.parse("acmeapp://x?cpp=a%zzb")!!.cpp)
        assertEquals("cpp", DeepLinks.percentDecode("%63pp"))
    }

    @Test
    fun theFragmentIsNotPartOfTheQuery() {
        val link = DeepLinks.parse("https://acme-app.com/p?cpp=a#ppid=b")!!
        assertEquals("a", link.cpp)
        assertNull(link.ppid)
        assertNull(DeepLinks.parse("https://acme-app.com/p#x?cpp=a")!!.cpp)
    }

    @Test
    fun theFirstOccurrenceWinsAndUnknownParamsAreIgnored() {
        val link = DeepLinks.parse("acmeapp://x?cpp=first&cpp=second&CPP=upper&foo=bar&ppid")!!
        assertEquals("first", link.cpp)
        assertNull(link.ppid)
    }

    @Test
    fun noQueryAndBlank() {
        val link = DeepLinks.parse("  acmeapp://home  ")!!
        assertEquals("acmeapp://home", link.url)
        assertNull(link.cpp)
        assertFalse(DeepLinks.isAttributionBearing(link))
        assertNull(DeepLinks.parse("   "))
        assertNull(DeepLinks.parse(""))
    }

    @Test
    fun theFirstLinkBeforeAnyBackgroundIsInitial() {
        val sources = DeepLinkSources()
        assertEquals("initial", sources.next())
        assertEquals("runtime", sources.next())

        val late = DeepLinkSources()
        late.onBackground()
        assertEquals("runtime", late.next())
    }

    @Test
    fun aCallerThatKnowsTheSourceWins() {
        val sources = DeepLinkSources()
        // The Expo bridge: a runtime link that arrives before the initial URL is read.
        assertEquals("runtime", sources.next("runtime"))
        assertEquals("initial", sources.next("initial"))
        // An explicit initial uses up the inferred one.
        assertEquals("runtime", sources.next())
        // Anything else falls back to inference.
        assertEquals("runtime", DeepLinkSources().also { it.next("initial") }.next("bogus"))
    }

    @Test
    fun longUrlsAreCutToTheCollectorLimitAfterParsing() {
        val url = "https://acme-app.com/p?cpp=keep&pad=" + "x".repeat(5_000)
        val link = DeepLinks.parse(url)!!
        val props = ReservedProps.deeplink(link, "runtime")
        assertEquals(DeepLinks.MAX_URL_CHARS, props.getString("url").length)
        assertEquals("keep", props.getString("cpp"))
        assertTrue(props.isNull("kerdly_c"))
    }
}
