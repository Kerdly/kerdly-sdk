package com.kerdly.sdk.internal

import com.kerdly.sdk.KerdlyDeepLink
import java.io.ByteArrayOutputStream

/** Deep-link parsing: the attribution params come from the query string,
 * whatever the scheme, host or path. `myapp://onboarding?cpp=x` and the App
 * Link `https://example.com/onboarding?cpp=x` parse the same. */
internal object DeepLinks {
    const val CPP = "cpp"
    const val PPID = "ppid"
    const val AFR_C = "afr_c"
    const val AFR_V = "afr_v"
    const val CAMPAIGN_IDS = "campaign_ids"
    private val PARAMS = setOf(CPP, PPID, AFR_C, AFR_V, CAMPAIGN_IDS)

    /** The collector's limit on `$deeplink.url`; longer URLs are cut (the params are parsed first). */
    const val MAX_URL_CHARS = 4096

    /** Null only for a blank string. */
    fun parse(url: String): KerdlyDeepLink? {
        val trimmed = url.trim()
        if (trimmed.isEmpty()) return null
        val params = query(trimmed)?.let(::parseQuery) ?: emptyMap()
        return KerdlyDeepLink(
            url = trimmed,
            cpp = params[CPP],
            ppid = params[PPID],
            afrC = params[AFR_C],
            afrV = params[AFR_V],
            campaignIds = params[CAMPAIGN_IDS],
        )
    }

    /** A link carrying one of these is kept pending until the collector accepts it. */
    fun isAttributionBearing(link: KerdlyDeepLink): Boolean =
        link.cpp != null || link.ppid != null || link.afrC != null || link.afrV != null

    /** The text between the first `?` and the fragment, or null when there is none. */
    fun query(url: String): String? {
        val hash = url.indexOf('#')
        val beforeFragment = if (hash >= 0) url.substring(0, hash) else url
        val qm = beforeFragment.indexOf('?')
        return if (qm >= 0) beforeFragment.substring(qm + 1) else null
    }

    /** The known params of a query string. The first non-empty occurrence of a name wins; empty
     * values are absent. Values are percent-decoded, but `+` stays `+`: Meta's `campaign_ids`
     * is base64-like and must arrive "as given". */
    fun parseQuery(query: String): Map<String, String> {
        val out = HashMap<String, String>()
        for (part in query.split('&')) {
            if (part.isEmpty()) continue
            val eq = part.indexOf('=')
            val key = percentDecode(if (eq >= 0) part.substring(0, eq) else part)
            if (key !in PARAMS || out.containsKey(key)) continue
            val value = if (eq >= 0) percentDecode(part.substring(eq + 1)) else ""
            if (value.isNotEmpty()) out[key] = value
        }
        return out
    }

    /** RFC 3986 percent-decoding into UTF-8. A malformed escape is kept literally. */
    fun percentDecode(s: String): String {
        if (s.indexOf('%') < 0) return s
        val bytes = ByteArrayOutputStream(s.length)
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '%' && i + 2 < s.length) {
                val hi = Character.digit(s[i + 1], 16)
                val lo = Character.digit(s[i + 2], 16)
                if (hi >= 0 && lo >= 0) {
                    bytes.write(hi * 16 + lo)
                    i += 3
                    continue
                }
            }
            val cp = s.codePointAt(i)
            val chunk = String(Character.toChars(cp)).toByteArray(Charsets.UTF_8)
            bytes.write(chunk, 0, chunk.size)
            i += Character.charCount(cp)
        }
        return String(bytes.toByteArray(), Charsets.UTF_8)
    }
}

/** `source` of a `$deeplink`. A caller that knows it (the Expo bridge: React Native's initial URL
 * vs its `url` events) passes it. Otherwise the first `handleUrl` of the process, before the app
 * first went to the background, is the link that opened it (`initial`); every later one is
 * `runtime`. */
internal class DeepLinkSources {
    private var initialTaken = false
    private var wentBackground = false

    @Synchronized
    fun onBackground() {
        wentBackground = true
    }

    @Synchronized
    fun next(explicit: String? = null): String {
        if (explicit == "initial" || explicit == "runtime") {
            if (explicit == "initial") initialTaken = true
            return explicit
        }
        if (initialTaken || wentBackground) return "runtime"
        initialTaken = true
        return "initial"
    }
}
