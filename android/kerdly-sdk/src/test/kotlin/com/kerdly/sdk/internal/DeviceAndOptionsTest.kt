package com.kerdly.sdk.internal

import com.kerdly.sdk.KerdlyEnvironment
import com.kerdly.sdk.KerdlyLogLevel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceAndOptionsTest {
    @Test
    fun localesUseTheIosIdentifierStyle() {
        assertEquals("es_US", LocaleFormat.identifier("es-US"))
        assertEquals("en_US", LocaleFormat.identifier("en_US"))
        assertEquals("en", LocaleFormat.identifier("en"))
        assertEquals("zh-Hant_TW", LocaleFormat.identifier("zh-Hant-TW"))
        assertEquals("sr-Latn", LocaleFormat.identifier("sr-latn"))
        assertEquals("es_419", LocaleFormat.identifier("es-419"))
        assertEquals("de_DE", LocaleFormat.identifier("de-DE-u-co-phonebk"))
        assertNull(LocaleFormat.identifier("und"))
        assertNull(LocaleFormat.identifier(""))
        assertNull(LocaleFormat.identifier(null))
    }

    @Test
    fun atMostFiveDistinctLanguages() {
        assertEquals(
            listOf("es-US", "en-US", "fr-FR", "de-DE", "it-IT"),
            LocaleFormat.languages(listOf("es-US", "en-US", "es-US", "und", "fr-FR", "de-DE", "it-IT", "pt-BR")),
        )
    }

    @Test
    fun theScreenIsPortraitWithTheDensityAsScale() {
        assertEquals(Triple(1080, 2340, 2.625), ContextJson.screen(2340, 1080, 2.625f))
        assertEquals(1.3313, ContextJson.screen(800, 1280, 1.3312501f)!!.third, 0.0)
        assertNull(ContextJson.screen(0, 100, 2f))
    }

    @Test
    fun contextStringsAreCutToTheCollectorLimits() {
        val device = DeviceContext("15", "M".repeat(100), "x", "en_US", listOf("en-US"), "UTC", null, null, null)
        val c = ContextJson.build(device, analytics = true, ads = false, lat = null, appVersion = "5.12-" + "9".repeat(40), appBuild = "1310")
        assertEquals(64, c.getString("model").length)
        assertEquals(32, c.getString("app_version").length)
        assertFalse(c.has("screen"))
        assertFalse(c.has("lat"))
        assertEquals("not_applicable", c.getString("att"))
        assertFalse(c.getJSONObject("consent").getBoolean("ads"))
    }

    @Test
    fun theInstallDeviceIsTheContextWithoutConsentAndLat() {
        val device = DeviceContext("15", "M".repeat(100), null, "en_US", listOf("en-US"), "UTC", 1080, 2340, null)
        val c = ContextJson.build(device, analytics = true, ads = true, lat = false, appVersion = "5.12", appBuild = null)
        val d = ContextJson.device(device, appVersion = "5.12", appBuild = null)
        assertEquals(c.keyList() - setOf("consent", "lat"), d.keyList())
        for (k in d.keyList()) assertTrue(k, jsonEquals(c.opt(k), d.opt(k)))
        assertEquals(64, d.getString("model").length)
        assertTrue(d.isNull("manufacturer"))
        assertTrue(d.isNull("app_build"))
        assertFalse(d.getJSONObject("screen").has("scale"))
    }

    @Test
    fun onlyTheStringTrueIsATestLabDevice() {
        assertTrue(TestLab.detect { "true" })
        assertFalse(TestLab.detect { null })
        assertFalse(TestLab.detect { "false" })
        assertFalse(TestLab.detect { "" })
        assertFalse(TestLab.detect { throw SecurityException("no settings") })
    }

    @Test
    fun testLabIsSentOnlyWhenTrue() {
        val lab = DeviceContext("15", "Pixel 8", "Google", "en_US", listOf("en-US"), "UTC", 1080, 2400, 2.625, testLab = true)
        assertTrue(ContextJson.build(lab, analytics = true, ads = true, lat = null, appVersion = "5.12", appBuild = "1310").getBoolean("test_lab"))
        assertTrue(ContextJson.device(lab, appVersion = "5.12", appBuild = "1310").getBoolean("test_lab"))
        val phone = DeviceContext("15", "Pixel 8", "Google", "en_US", listOf("en-US"), "UTC", 1080, 2400, 2.625)
        assertFalse(ContextJson.build(phone, analytics = true, ads = true, lat = null, appVersion = "5.12", appBuild = "1310").has("test_lab"))
        assertFalse(ContextJson.device(phone, appVersion = "5.12", appBuild = "1310").has("test_lab"))
        assertFalse(ContextJson.device(DeviceContext.UNKNOWN, appVersion = null, appBuild = null).has("test_lab"))
    }

    @Test
    fun endpoints() {
        assertEquals("https://sdk.example.com", OptionRules.endpoint("https://sdk.example.com/"))
        assertEquals("https://app.kerdly.com/api", OptionRules.endpoint(" https://app.kerdly.com/api// "))
        assertEquals("http://10.0.2.2:3003/api", OptionRules.endpoint("http://10.0.2.2:3003/api"))
        assertNull(OptionRules.endpoint("sdk.example.com"))
        assertNull(OptionRules.endpoint("https://"))
        assertNull(OptionRules.endpoint("https://x.com/api?x=1"))
        assertNull(OptionRules.endpoint("ftp://x.com"))
    }

    @Test
    fun keys() {
        assertEquals(OptionRules.KeyCheck.OK, OptionRules.checkKey("pk_live_abc"))
        assertEquals(OptionRules.KeyCheck.OK, OptionRules.checkKey("pk_test_abc"))
        assertEquals(OptionRules.KeyCheck.SECRET, OptionRules.checkKey("sk_live_abc"))
        assertEquals(OptionRules.KeyCheck.NOT_PUBLIC, OptionRules.checkKey("wk_live_abc"))
        assertEquals(OptionRules.KeyCheck.INVALID, OptionRules.checkKey(""))
        assertEquals(OptionRules.KeyCheck.INVALID, OptionRules.checkKey("pk_live_a\nb"))
    }

    @Test
    fun environmentAndWrapperAndMetaAppId() {
        assertEquals("development", OptionRules.environment(KerdlyEnvironment.AUTO, debuggable = true))
        assertEquals("production", OptionRules.environment(KerdlyEnvironment.AUTO, debuggable = false))
        assertEquals("sandbox", OptionRules.environment(KerdlyEnvironment.SANDBOX, debuggable = true))
        assertEquals("production", OptionRules.environment(KerdlyEnvironment.PRODUCTION, debuggable = true))
        assertEquals("expo/0.1.0", OptionRules.wrapper(" expo/0.1.0 "))
        assertNull(OptionRules.wrapper("  "))
        assertEquals("123" to true, OptionRules.metaAppId(" 123 "))
        assertEquals(null to true, OptionRules.metaAppId(null))
        assertEquals(null to false, OptionRules.metaAppId("my-app"))
    }

    @Test
    fun theSdkHeader() {
        assertEquals("kerdly-android/${SdkInfo.VERSION}", SdkInfo.header(null))
        assertEquals("kerdly-android/${SdkInfo.VERSION} expo/0.1.0", SdkInfo.header("expo/0.1.0"))
        assertTrue(SdkInfo.VERSION.matches(Regex("^\\d+\\.\\d+\\.\\d+.*")))
    }

    @Test
    fun logLevelsFilter() {
        val sink = CollectingSink()
        val log = Logger(KerdlyLogLevel.WARN, sink)
        log.error("e")
        log.warn("w")
        log.info("i")
        log.debug { "d" }
        assertEquals(listOf("ERROR [Kerdly] e", "WARN [Kerdly] w"), sink.lines)
        log.verbose = true
        log.debug { "d" }
        assertEquals("DEBUG [Kerdly] d", sink.lines.last())
        val silent = Logger(KerdlyLogLevel.NONE, sink)
        silent.error("x")
        assertEquals(3, sink.lines.size)
    }
}
