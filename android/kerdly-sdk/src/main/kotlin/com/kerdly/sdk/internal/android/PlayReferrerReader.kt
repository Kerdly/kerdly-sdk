package com.kerdly.sdk.internal.android

import android.content.Context
import com.kerdly.sdk.internal.Cancellable
import com.kerdly.sdk.internal.Logger
import com.kerdly.sdk.internal.PlayReferrerCodes
import com.kerdly.sdk.internal.PlayReferrerDetails
import com.kerdly.sdk.internal.PlayReferrerResult
import com.kerdly.sdk.internal.Scheduler
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import java.util.concurrent.atomic.AtomicBoolean

/** One Play Install Referrer read, bounded by a timeout. Exactly one result per attempt, and the
 * connection is always ended — the app's old reader had no timeout and could hang a session. */
internal class PlayReferrerReader(
    private val context: Context,
    private val scheduler: Scheduler,
    private val log: Logger,
) {
    fun start(timeoutMs: Long, onResult: (PlayReferrerResult) -> Unit) {
        Attempt(timeoutMs, onResult).begin()
    }

    private inner class Attempt(
        private val timeoutMs: Long,
        private val onResult: (PlayReferrerResult) -> Unit,
    ) : InstallReferrerStateListener {
        private val finished = AtomicBoolean(false)

        @Volatile private var client: InstallReferrerClient? = null

        @Volatile private var timeout: Cancellable? = null

        fun begin() {
            try {
                timeout = scheduler.schedule(timeoutMs) {
                    finish(PlayReferrerResult.Transient("no answer within $timeoutMs ms"))
                }
                val c = InstallReferrerClient.newBuilder(context).build()
                client = c
                c.startConnection(this)
            } catch (t: Throwable) {
                finish(PlayReferrerResult.Transient("could not connect: ${t.javaClass.simpleName}"))
            }
        }

        // Play calls back on the main thread; the details read is a binder call, so it runs on
        // the SDK thread instead.
        override fun onInstallReferrerSetupFinished(responseCode: Int) {
            scheduler.execute {
                if (finished.get()) return@execute
                val result = when (PlayReferrerCodes.classify(responseCode)) {
                    PlayReferrerCodes.Kind.OK -> read()
                    PlayReferrerCodes.Kind.PERMANENT -> PlayReferrerResult.Permanent(responseCode)
                    PlayReferrerCodes.Kind.TRANSIENT -> PlayReferrerResult.Transient("response code $responseCode")
                }
                finish(result)
            }
        }

        override fun onInstallReferrerServiceDisconnected() {
            scheduler.execute { finish(PlayReferrerResult.Transient("service disconnected")) }
        }

        private fun read(): PlayReferrerResult = try {
            val d = client!!.installReferrer
            PlayReferrerResult.Ok(
                PlayReferrerDetails.of(
                    referrer = d.installReferrer,
                    clickTs = d.referrerClickTimestampSeconds,
                    installBeginTs = d.installBeginTimestampSeconds,
                    clickServerTs = d.referrerClickTimestampServerSeconds,
                    installBeginServerTs = d.installBeginTimestampServerSeconds,
                    installVersion = d.installVersion,
                    instant = d.googlePlayInstantParam,
                ),
            )
        } catch (t: Throwable) {
            PlayReferrerResult.Transient("read failed: ${t.javaClass.simpleName}")
        }

        private fun finish(result: PlayReferrerResult) {
            if (!finished.compareAndSet(false, true)) return
            timeout?.cancel()
            try {
                client?.endConnection()
            } catch (_: Throwable) {
            }
            try {
                onResult(result)
            } catch (t: Throwable) {
                log.warn("install referrer result handling failed", t)
            }
        }
    }
}
