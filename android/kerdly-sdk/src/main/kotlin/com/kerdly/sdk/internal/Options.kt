package com.kerdly.sdk.internal

import com.kerdly.sdk.KerdlyEnvironment
import java.util.Locale

/** Validation of [com.kerdly.sdk.KerdlyOptions]: a bad option turns the SDK off with a log line, never
 * an exception. */
internal object OptionRules {
    enum class KeyCheck { OK, NOT_PUBLIC, SECRET, INVALID }

    /** Base URL without trailing slashes; null unless it is an http(s) URL with no query. */
    fun endpoint(raw: String): String? {
        val e = raw.trim().trimEnd('/')
        val lower = e.lowercase(Locale.ROOT)
        val scheme = when {
            lower.startsWith("https://") -> 8
            lower.startsWith("http://") -> 7
            else -> return null
        }
        if (e.length <= scheme || e.any { it.isWhitespace() || it == '?' || it == '#' }) return null
        return e
    }

    fun checkKey(key: String): KeyCheck = when {
        key.isEmpty() || key.any { it.isWhitespace() || it.isISOControl() } -> KeyCheck.INVALID
        key.startsWith("sk_") -> KeyCheck.SECRET // a server key must never ship in an app
        key.startsWith("pk_") -> KeyCheck.OK
        else -> KeyCheck.NOT_PUBLIC
    }

    fun wrapper(raw: String?): String? = raw?.trim()?.takeIf { it.isNotEmpty() }?.take(64)

    /** (id, valid): id null when absent or invalid; valid false when set but not a numeric
     * Facebook app id. */
    fun metaAppId(raw: String?): Pair<String?, Boolean> {
        val id = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null to true
        return if (MetaReferrer.isValidAppId(id)) id to true else null to false
    }

    /** Android: AUTO is `development` for a debuggable app, else `production`. */
    fun environment(env: KerdlyEnvironment, debuggable: Boolean): String = when (env) {
        KerdlyEnvironment.AUTO -> if (debuggable) "development" else "production"
        KerdlyEnvironment.PRODUCTION -> "production"
        KerdlyEnvironment.SANDBOX -> "sandbox"
        KerdlyEnvironment.DEVELOPMENT -> "development"
    }
}
