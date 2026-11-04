package com.kerdly.sdk.internal.android

import android.app.Activity
import android.app.Application
import android.net.TrafficStats
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import com.kerdly.sdk.KerdlyLogLevel
import com.kerdly.sdk.internal.Cancellable
import com.kerdly.sdk.internal.HttpRequest
import com.kerdly.sdk.internal.HttpResponse
import com.kerdly.sdk.internal.LogSink
import com.kerdly.sdk.internal.Logger
import com.kerdly.sdk.internal.MainDispatcher
import com.kerdly.sdk.internal.Scheduler
import com.kerdly.sdk.internal.Transport
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** The SDK's single background thread (`kerdly-sdk`, background priority). */
internal class ExecutorScheduler(private val log: Logger) : Scheduler {
    private val executor = ScheduledThreadPoolExecutor(1) { runnable ->
        Thread({
            try {
                Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
            } catch (_: Throwable) {
            }
            runnable.run()
        }, "kerdly-sdk").apply { isDaemon = true }
    }.apply { removeOnCancelPolicy = true }

    override fun execute(task: () -> Unit) {
        try {
            executor.execute(Runnable { run(task) })
        } catch (t: Throwable) {
            log.warn("task rejected", t)
        }
    }

    override fun schedule(delayMs: Long, task: () -> Unit): Cancellable = try {
        val future = executor.schedule(Runnable { run(task) }, delayMs.coerceAtLeast(0), TimeUnit.MILLISECONDS)
        Cancellable { future.cancel(false) }
    } catch (t: Throwable) {
        log.warn("task rejected", t)
        Cancellable { }
    }

    private fun run(task: () -> Unit) {
        try {
            task()
        } catch (t: Throwable) {
            log.error("internal error", t)
        }
    }
}

/** `HttpURLConnection`, no redirects (a redirected POST would turn into a GET), bounded reads. */
internal class HttpUrlTransport : Transport {
    override fun execute(request: HttpRequest): HttpResponse {
        TrafficStats.setThreadStatsTag(THREAD_STATS_TAG)
        var connection: HttpURLConnection? = null
        try {
            val c = URL(request.url).openConnection() as HttpURLConnection
            connection = c
            c.connectTimeout = CONNECT_TIMEOUT_MS
            c.readTimeout = READ_TIMEOUT_MS
            c.instanceFollowRedirects = false
            c.useCaches = false
            c.requestMethod = request.method
            for ((name, value) in request.headers) c.setRequestProperty(name, value)
            val body = request.body
            if (body != null) {
                c.doOutput = true
                c.setFixedLengthStreamingMode(body.size)
                c.outputStream.use { it.write(body) }
            }
            val status = c.responseCode
            val stream: InputStream? = try {
                if (status >= 400) c.errorStream else c.inputStream
            } catch (e: IOException) {
                c.errorStream
            }
            val text = stream?.use { readUtf8(it) } ?: ""
            return HttpResponse(status, text, c.getHeaderField("Retry-After"), c.getHeaderField("ETag"))
        } finally {
            connection?.disconnect()
            TrafficStats.clearThreadStatsTag()
        }
    }

    private fun readUtf8(input: InputStream): String {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(8 * 1024)
        while (out.size() < MAX_RESPONSE_BYTES) {
            val n = input.read(buffer)
            if (n < 0) break
            out.write(buffer, 0, n)
        }
        return String(out.toByteArray(), Charsets.UTF_8)
    }

    companion object {
        private const val CONNECT_TIMEOUT_MS = 10_000
        private const val READ_TIMEOUT_MS = 15_000
        private const val MAX_RESPONSE_BYTES = 1 shl 20
        /** Every socket the SDK opens carries this tag (StrictMode's untagged-socket check). */
        const val THREAD_STATS_TAG = 0xAF5
    }
}

/** Foreground / background from started activities. Configure may run after the first activity
 * started (the Expo bridge configures from JS), so the starting state comes from the process
 * importance, and a stop of an activity started before registration still counts. Rotation
 * (`isChangingConfigurations`) is not a background. */
internal class LifecycleTracker(
    initialForeground: Boolean,
    private val onForeground: () -> Unit,
    private val onBackground: () -> Unit,
) : Application.ActivityLifecycleCallbacks {
    private val started = HashSet<Int>()
    private var foreground = initialForeground

    override fun onActivityStarted(activity: Activity) {
        started.add(System.identityHashCode(activity))
        if (!foreground) {
            foreground = true
            safely(onForeground)
        }
    }

    override fun onActivityStopped(activity: Activity) {
        started.remove(System.identityHashCode(activity))
        if (foreground && started.isEmpty() && !isChangingConfigurations(activity)) {
            foreground = false
            safely(onBackground)
        }
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
    override fun onActivityResumed(activity: Activity) {}
    override fun onActivityPaused(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
    override fun onActivityDestroyed(activity: Activity) {}

    private fun isChangingConfigurations(activity: Activity): Boolean = try {
        activity.isChangingConfigurations
    } catch (_: Throwable) {
        false
    }

    private fun safely(block: () -> Unit) {
        try {
            block()
        } catch (_: Throwable) {
        }
    }
}

internal object AndroidLogSink : LogSink {
    private const val TAG = "Kerdly"

    override fun write(level: KerdlyLogLevel, message: String, error: Throwable?) {
        when (level) {
            KerdlyLogLevel.ERROR -> Log.e(TAG, message, error)
            KerdlyLogLevel.WARN -> Log.w(TAG, message, error)
            KerdlyLogLevel.INFO -> Log.i(TAG, message, error)
            KerdlyLogLevel.DEBUG -> Log.d(TAG, message, error)
            KerdlyLogLevel.NONE -> Unit
        }
    }
}

internal object MainThreadDispatcher : MainDispatcher {
    private val handler by lazy { Handler(Looper.getMainLooper()) }

    override fun post(block: () -> Unit) {
        handler.post(block)
    }
}
