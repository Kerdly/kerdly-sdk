package com.kerdly.sdk.internal.android

import android.app.ActivityManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.database.Cursor
import android.hardware.display.DisplayManager
import android.net.TrafficStats
import android.net.Uri
import android.os.Build
import android.os.LocaleList
import android.provider.Settings
import android.util.DisplayMetrics
import android.view.Display
import com.kerdly.sdk.internal.AdIdResult
import com.kerdly.sdk.internal.AdIds
import com.kerdly.sdk.internal.AppInfo
import com.kerdly.sdk.internal.ContextJson
import com.kerdly.sdk.internal.DeviceContext
import com.kerdly.sdk.internal.InstallInfo
import com.kerdly.sdk.internal.LocaleFormat
import com.kerdly.sdk.internal.Logger
import com.kerdly.sdk.internal.MetaReferrer
import com.kerdly.sdk.internal.MetaReferrerRow
import com.kerdly.sdk.internal.Platform
import com.kerdly.sdk.internal.PlayReferrerResult
import com.kerdly.sdk.internal.PublicIp
import com.kerdly.sdk.internal.Scheduler
import com.kerdly.sdk.internal.TestLab
import com.google.android.gms.ads.identifier.AdvertisingIdClient
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** [Platform] on Android. Every read is guarded: a failure is a null or empty answer. */
internal class AndroidPlatform(
    private val context: Context,
    private val scheduler: Scheduler,
    private val log: Logger,
) : Platform {
    private val packageName: String = context.packageName

    /** Read once per launch, on the SDK thread (the first [deviceContext]); it cannot change. */
    private val testLab: Boolean by lazy {
        TestLab.detect { Settings.System.getString(context.contentResolver, TestLab.SETTING) }
    }

    @Suppress("DEPRECATION")
    private fun packageInfo(): PackageInfo? = try {
        val pm = context.packageManager
        if (Build.VERSION.SDK_INT >= 33) {
            pm.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            pm.getPackageInfo(packageName, 0)
        }
    } catch (t: Throwable) {
        null
    }

    @Suppress("DEPRECATION")
    override fun appInfo(): AppInfo {
        val info = packageInfo()
        val build = info?.let { if (Build.VERSION.SDK_INT >= 28) it.longVersionCode.toString() else it.versionCode.toString() }
        return AppInfo(packageName, info?.versionName, build)
    }

    @Suppress("DEPRECATION")
    override fun installInfo(): InstallInfo {
        // A failed read or a value ≤ 0 is null, never -1.
        val installedAt = packageInfo()?.firstInstallTime?.takeIf { it > 0 }
        val installer = try {
            val pm = context.packageManager
            if (Build.VERSION.SDK_INT >= 30) {
                pm.getInstallSourceInfo(packageName).installingPackageName
            } else {
                pm.getInstallerPackageName(packageName)
            }
        } catch (t: Throwable) {
            null
        }
        return InstallInfo(installedAt, installer)
    }

    override fun deviceContext(): DeviceContext {
        val appLocales = context.resources.configuration.locales
        val primary: Locale = if (appLocales.isEmpty) Locale.getDefault() else appLocales.get(0)
        val preferred = LocaleList.getDefault()
        val tags = ArrayList<String>()
        for (i in 0 until preferred.size()) tags.add(preferred.get(i).toLanguageTag())
        if (tags.isEmpty()) tags.add(primary.toLanguageTag())
        val screen = screen()
        return DeviceContext(
            os = Build.VERSION.RELEASE,
            model = Build.MODEL,
            manufacturer = Build.MANUFACTURER,
            locale = LocaleFormat.identifier(primary.toLanguageTag()),
            languages = LocaleFormat.languages(tags),
            tz = TimeZone.getDefault().id,
            screenW = screen?.first,
            screenH = screen?.second,
            scale = screen?.third,
            testLab = testLab,
        )
    }

    /** The physical display in pixels (DisplayManager works from the application context). */
    @Suppress("DEPRECATION")
    private fun screen(): Triple<Int, Int, Double>? = try {
        val metrics = DisplayMetrics()
        val display = (context.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager)?.getDisplay(Display.DEFAULT_DISPLAY)
        if (display != null) display.getRealMetrics(metrics) else metrics.setTo(context.resources.displayMetrics)
        ContextJson.screen(metrics.widthPixels, metrics.heightPixels, metrics.density)
    } catch (t: Throwable) {
        null
    }

    /** Blocking; never on the main thread (AdvertisingIdClient refuses it there). */
    override fun readAdvertisingId(): AdIdResult? = try {
        val info = AdvertisingIdClient.getAdvertisingIdInfo(context)
        AdIds.normalize(info.id, info.isLimitAdTrackingEnabled)
    } catch (t: Throwable) {
        // No Play services, the library excluded by the app, or an IPC failure.
        log.debug { "advertising id unavailable: ${t.javaClass.simpleName}" }
        null
    }

    override fun readMetaReferrer(metaAppId: String): List<MetaReferrerRow> {
        val rows = ArrayList<MetaReferrerRow>()
        for ((source, authority) in MetaReferrer.PROVIDERS) {
            try {
                val uri = Uri.parse(MetaReferrer.uri(authority, metaAppId))
                context.contentResolver.query(uri, MetaReferrer.COLUMNS, null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        rows.add(
                            MetaReferrerRow(
                                source = source,
                                installReferrer = c.value("install_referrer") as? String,
                                isCt = MetaReferrer.isCt(c.value("is_ct")),
                                actualTimestamp = MetaReferrer.timestamp(c.value("actual_timestamp")),
                            ),
                        )
                    }
                }
            } catch (t: Throwable) {
                // Not installed, not visible, or the provider refused: no row from this app.
                log.debug { "Meta install referrer ($source): ${t.javaClass.simpleName}" }
            }
        }
        return rows
    }

    /** Never on the SDK thread: a daemon thread waits for the answer and calls [onResult] once. */
    override fun startPublicIpv6Lookup(echoUrl: String, timeoutMs: Long, onResult: (String?) -> Unit) {
        try {
            Thread({
                val answer = readPublicIpv6(echoUrl, timeoutMs)
                try {
                    onResult(answer)
                } catch (t: Throwable) {
                    log.warn("public IPv6 result handling failed", t)
                }
            }, "kerdly-sdk-ip6").apply { isDaemon = true }.start()
        } catch (t: Throwable) {
            log.debug { "public IPv6 lookup not started: ${t.javaClass.simpleName}" }
        }
    }

    /** Blocking, [timeoutMs] in all. The GET runs on a thread of its own so that a slow DNS answer,
     * connect or read cannot outlast the budget (the connection's own timeouts are per phase); at
     * the deadline the connection is torn down. */
    private fun readPublicIpv6(echoUrl: String, timeoutMs: Long): String? {
        val connection = AtomicReference<HttpURLConnection?>()
        val task = FutureTask(Callable { fetchEcho(echoUrl, timeoutMs.toInt(), connection) })
        return try {
            Thread(task, "kerdly-sdk-ip6-get").apply { isDaemon = true }.start()
            task.get(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (t: Throwable) {
            // An IPv4-only network (no AAAA answer, no route), the timeout, a TLS or HTTP failure.
            log.debug { "public IPv6 unavailable: ${((t as? ExecutionException)?.cause ?: t).javaClass.simpleName}" }
            null
        } finally {
            task.cancel(true)
            try {
                connection.get()?.disconnect()
            } catch (_: Throwable) {
            }
        }
    }

    /** One GET: no redirects, no cache, no cookies of the SDK's own; the answer's `ip`, or null. */
    private fun fetchEcho(echoUrl: String, timeoutMs: Int, connection: AtomicReference<HttpURLConnection?>): String? {
        TrafficStats.setThreadStatsTag(HttpUrlTransport.THREAD_STATS_TAG)
        try {
            val c = URL(echoUrl).openConnection() as HttpURLConnection
            connection.set(c)
            c.connectTimeout = timeoutMs
            c.readTimeout = timeoutMs
            c.instanceFollowRedirects = false
            c.useCaches = false
            c.setRequestProperty("Accept", "application/json")
            if (c.responseCode != 200) return null
            val body = ByteArrayOutputStream()
            c.inputStream.use { input ->
                val buffer = ByteArray(1024)
                while (body.size() < MAX_ECHO_BYTES) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    body.write(buffer, 0, n)
                }
            }
            return PublicIp.parseEcho(String(body.toByteArray(), Charsets.UTF_8))
        } finally {
            connection.get()?.disconnect()
            TrafficStats.clearThreadStatsTag()
        }
    }

    override fun startPlayReferrer(timeoutMs: Long, onResult: (PlayReferrerResult) -> Unit) {
        PlayReferrerReader(context, scheduler, log).start(timeoutMs, onResult)
    }

    private fun Cursor.value(column: String): Any? {
        val i = getColumnIndex(column)
        if (i < 0) return null
        return when (getType(i)) {
            Cursor.FIELD_TYPE_INTEGER -> getLong(i)
            Cursor.FIELD_TYPE_FLOAT -> getDouble(i)
            Cursor.FIELD_TYPE_STRING -> getString(i)
            else -> null
        }
    }

    companion object {
        /** `{"ip": "…"}` is under 64 bytes; anything far larger is not the echo. */
        private const val MAX_ECHO_BYTES = 4 * 1024

        /** `com.kerdly.sdk.META_APP_ID` from the app's manifest meta-data, or null. The Expo config
         * plugin writes it through a string resource; a hand-written numeric literal arrives as a
         * number, hence `get` + `toString`. */
        fun manifestMetaAppId(context: Context): String? = try {
            @Suppress("DEPRECATION")
            val info = context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
            info.metaData?.get("com.kerdly.sdk.META_APP_ID")?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        } catch (t: Throwable) {
            null
        }

        fun isDebuggable(context: Context): Boolean = try {
            (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        } catch (t: Throwable) {
            false
        }

        /** Whether an activity of this process is visible right now (configure may run late, e.g.
         * from the Expo bridge, after the first activity started). */
        fun isProcessForeground(): Boolean = try {
            val info = ActivityManager.RunningAppProcessInfo()
            ActivityManager.getMyMemoryState(info)
            info.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND ||
                info.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
        } catch (t: Throwable) {
            false
        }
    }
}
