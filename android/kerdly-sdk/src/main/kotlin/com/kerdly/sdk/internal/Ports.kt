package com.kerdly.sdk.internal

import java.io.IOException

// The engine (Core) talks to the device only through these ports, so every rule in it runs in
// plain JVM tests with fakes. The Android implementations live in `internal.android`.

internal fun interface Clock {
    fun now(): Long
}

internal fun interface Cancellable {
    fun cancel()
}

/** One serial background thread: every Core method runs on it, in submission order. */
internal interface Scheduler {
    fun execute(task: () -> Unit)
    fun schedule(delayMs: Long, task: () -> Unit): Cancellable
}

/** Small named files under `noBackupFilesDir/afr/`. */
internal interface Store {
    /** The file's text, or null when the file does not exist. Throws when it exists but cannot be read. */
    @Throws(IOException::class)
    fun read(name: String): String?

    /** Replaces the file atomically. False when it could not be written. */
    fun write(name: String, content: String): Boolean

    fun delete(name: String)
}

internal class HttpRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String>,
    val body: ByteArray?,
)

internal class HttpResponse(
    val status: Int,
    val body: String,
    val retryAfter: String? = null,
    val etag: String? = null,
)

internal interface Transport {
    /** Blocking. Throws [IOException] on a network failure; any HTTP status is a response. */
    @Throws(IOException::class)
    fun execute(request: HttpRequest): HttpResponse
}

/** Runs listener callbacks for the app (the main thread on Android). */
internal fun interface MainDispatcher {
    fun post(block: () -> Unit)
}

internal class AppInfo(val bundle: String, val version: String?, val build: String?)

internal class InstallInfo(
    /** `PackageInfo.firstInstallTime`, or null when the read failed or returned ≤ 0. */
    val installedAt: Long?,
    /** The installing package, e.g. `com.android.vending`. */
    val installer: String?,
)

/** Device facts that read the platform. Collectors block (Core calls them on its own thread),
 * except [startPlayReferrer] and [startPublicIpv6Lookup], which answer through their callback
 * exactly once. */
internal interface Platform {
    fun appInfo(): AppInfo
    fun installInfo(): InstallInfo
    fun deviceContext(): DeviceContext
    /** Null when the advertising id is unavailable (no Play services, an error). */
    fun readAdvertisingId(): AdIdResult?
    /** One row per Meta app that answered; empty when none did. */
    fun readMetaReferrer(metaAppId: String): List<MetaReferrerRow>
    /** One GET of [echoUrl] off the calling thread, [timeoutMs] in all: the answer's `ip` as sent,
     * or null on any failure (an IPv4-only network, the timeout, an error, another answer). */
    fun startPublicIpv6Lookup(echoUrl: String, timeoutMs: Long, onResult: (String?) -> Unit)
    fun startPlayReferrer(timeoutMs: Long, onResult: (PlayReferrerResult) -> Unit)
}
