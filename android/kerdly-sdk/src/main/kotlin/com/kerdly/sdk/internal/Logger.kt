package com.kerdly.sdk.internal

import com.kerdly.sdk.KerdlyLogLevel
import com.kerdly.sdk.BuildConfig

internal object SdkInfo {
    const val NAME = "kerdly-android"
    val VERSION: String = BuildConfig.KERDLY_VERSION

    /** `X-Kerdly-Sdk`: `kerdly-android/0.1.0`, plus ` expo/0.1.0` under a wrapper. */
    fun header(wrapper: String?): String = if (wrapper == null) "$NAME/$VERSION" else "$NAME/$VERSION $wrapper"
}

internal fun interface LogSink {
    fun write(level: KerdlyLogLevel, message: String, error: Throwable?)
}

/** Level-filtered logging with the `[Kerdly]` prefix. Never pass it keys or full
 * advertising ids; see [maskId]. */
internal class Logger(@Volatile var level: KerdlyLogLevel, private val sink: LogSink) {
    /** Set when the remote config lists this install in `debug_devices`: log everything. */
    @Volatile var verbose: Boolean = false

    fun enabled(at: KerdlyLogLevel): Boolean =
        at != KerdlyLogLevel.NONE && (verbose || at.ordinal <= level.ordinal)

    fun error(message: String, error: Throwable? = null) = write(KerdlyLogLevel.ERROR, message, error)
    fun warn(message: String, error: Throwable? = null) = write(KerdlyLogLevel.WARN, message, error)
    fun info(message: String) = write(KerdlyLogLevel.INFO, message, null)
    fun debug(message: () -> String) {
        if (enabled(KerdlyLogLevel.DEBUG)) write(KerdlyLogLevel.DEBUG, message(), null)
    }

    private fun write(at: KerdlyLogLevel, message: String, error: Throwable?) {
        if (!enabled(at)) return
        try {
            sink.write(at, "[Kerdly] $message", error)
        } catch (_: Throwable) {
            // Logging must never break the host app.
        }
    }
}

/** First four characters only: enough to tell ids apart in a log, useless to anyone else. */
internal fun maskId(id: String?): String = when {
    id == null -> "null"
    id.length <= 4 -> "…"
    else -> id.take(4) + "…"
}
