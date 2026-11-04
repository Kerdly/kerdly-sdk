package com.kerdly.sdk.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReferrersTest {
    @Test
    fun playResponseCodesAreClassified() {
        assertEquals(PlayReferrerCodes.Kind.OK, PlayReferrerCodes.classify(0))
        for (code in listOf(2, 3, 4)) assertEquals("code $code", PlayReferrerCodes.Kind.PERMANENT, PlayReferrerCodes.classify(code))
        for (code in listOf(1, -1, 5, 99, -3)) assertEquals("code $code", PlayReferrerCodes.Kind.TRANSIENT, PlayReferrerCodes.classify(code))
    }

    @Test
    fun anOkSignalCarriesTheRawReferrerAndSeconds() {
        val p = Signals.installReferrerOk(FakePlatform.FIXTURE_REFERRER)
        assertEquals("install_referrer", p.getString("kind"))
        assertEquals("ok", p.getString("status"))
        assertTrue(p.isNull("response_code"))
        assertTrue(p.getString("referrer").startsWith("afr_c=k3f9q2xab7mn&utm_source=meta"))
        assertEquals(1_760_399_890L, p.getLong("click_ts"))
        assertEquals(1_760_399_931L, p.getLong("install_begin_server_ts"))
        assertEquals("5.12", p.getString("install_version"))
        assertFalse(p.getBoolean("instant"))
    }

    @Test
    fun playZeroTimestampsAreUnknown() {
        val d = PlayReferrerDetails.of("utm_source=google-play&utm_medium=organic", 0, 0, 0, 0, "", false)
        val p = Signals.installReferrerOk(d)
        assertTrue(p.isNull("click_ts"))
        assertTrue(p.isNull("install_begin_server_ts"))
        assertTrue(p.isNull("install_version"))
        assertEquals("utm_source=google-play&utm_medium=organic", p.getString("referrer"))
        assertEquals("", PlayReferrerDetails.of(null, 1, 1, 1, 1, null, true).referrer)
    }

    @Test
    fun anUnavailableSignalHasTheCodeAndAnEmptyReferrer() {
        val p = Signals.installReferrerUnavailable(PlayReferrerCodes.DEVELOPER_ERROR)
        assertEquals(
            setOf("kind", "status", "response_code", "referrer", "click_ts", "install_begin_ts", "click_server_ts", "install_begin_server_ts", "install_version", "instant"),
            p.keyList(),
        )
        assertEquals("unavailable", p.getString("status"))
        assertEquals(3, p.getInt("response_code"))
        assertEquals("", p.getString("referrer"))
    }

    @Test
    fun theFreshestMetaRowWinsAndEmptyRowsAreIgnored() {
        val fb = MetaReferrerRow("facebook", "{\"a\":1}", 1, 100)
        val ig = MetaReferrerRow("instagram", "{\"b\":1}", 0, 200)
        val empty = MetaReferrerRow("facebook_lite", "", 1, 300)
        val noTs = MetaReferrerRow("facebook_lite", "{\"c\":1}", 1, null)
        assertEquals("instagram", MetaReferrer.freshest(listOf(fb, ig, empty))!!.source)
        assertEquals("facebook", MetaReferrer.freshest(listOf(noTs, fb))!!.source)
        assertEquals("facebook", MetaReferrer.freshest(listOf(fb, MetaReferrerRow("instagram", "{}", 1, 100)))!!.source)
        assertNull(MetaReferrer.freshest(listOf(empty)))
        assertNull(MetaReferrer.freshest(emptyList()))
    }

    @Test
    fun metaProviderValuesAreNormalized() {
        assertEquals(1, MetaReferrer.isCt(1L))
        assertEquals(0, MetaReferrer.isCt("0"))
        assertNull(MetaReferrer.isCt(2L))
        assertNull(MetaReferrer.isCt("yes"))
        assertNull(MetaReferrer.isCt(null))
        assertEquals(1_760_399_880L, MetaReferrer.timestamp("1760399880"))
        assertNull(MetaReferrer.timestamp(0L))
        assertNull(MetaReferrer.timestamp("soon"))
    }

    @Test
    fun metaProvidersAndAppIds() {
        assertEquals(
            listOf(
                "content://com.facebook.katana.provider.InstallReferrerProvider/1234",
                "content://com.instagram.contentprovider.InstallReferrerProvider/1234",
                "content://com.facebook.lite.provider.InstallReferrerProvider/1234",
            ),
            MetaReferrer.PROVIDERS.map { (_, authority) -> MetaReferrer.uri(authority, "1234") },
        )
        assertEquals(listOf("facebook", "instagram", "facebook_lite"), MetaReferrer.PROVIDERS.map { it.first })
        assertEquals(listOf("install_referrer", "is_ct", "actual_timestamp"), MetaReferrer.COLUMNS.toList())
        assertTrue(MetaReferrer.isValidAppId("1234567890"))
        assertFalse(MetaReferrer.isValidAppId("12/34"))
        assertFalse(MetaReferrer.isValidAppId("fb123"))
    }

    @Test
    fun theMetaSignalProps() {
        val p = Signals.metaInstallReferrer(MetaReferrerRow("instagram", "{\"x\":1}", 1, 1_760_399_880))
        assertEquals(setOf("kind", "source", "install_referrer", "is_ct", "actual_timestamp"), p.keyList())
        assertEquals("meta_install_referrer", p.getString("kind"))
    }

    @Test
    fun limitAdTrackingOrAZeroedIdMeansNoGaid() {
        val on = AdIds.normalize("38400000-8CF0-11BD-B23E-10B96E40000D", limitAdTracking = false)
        assertEquals("38400000-8cf0-11bd-b23e-10b96e40000d", on.gaid)
        assertFalse(on.lat)
        for ((id, lat) in listOf("38400000-8cf0-11bd-b23e-10b96e40000d" to true, "00000000-0000-0000-0000-000000000000" to false, null to false, "" to false)) {
            val r = AdIds.normalize(id, lat)
            assertNull(r.gaid)
            assertTrue(r.lat)
        }
        val signal = Signals.advertisingIds(null, true)
        assertTrue(signal.isNull("gaid"))
        assertTrue(signal.getBoolean("lat"))
    }

    @Test
    fun idsAreMaskedInLogs() {
        assertEquals("3840…", maskId("38400000-8cf0-11bd-b23e-10b96e40000d"))
        assertEquals("null", maskId(null))
        assertEquals("…", maskId("abc"))
    }
}
