package com.kerdly.expo

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import com.kerdly.sdk.Kerdly
import com.kerdly.sdk.KerdlyAttribution
import com.kerdly.sdk.KerdlyDeepLink
import com.kerdly.sdk.KerdlyEnvironment
import com.kerdly.sdk.KerdlyLogLevel
import com.kerdly.sdk.KerdlyNetworkSend
import com.kerdly.sdk.KerdlyOptions
import com.kerdly.sdk.KerdlyPurchase
import expo.modules.kotlin.functions.Queues
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.records.Field
import expo.modules.kotlin.records.Record
import java.lang.ref.WeakReference

/**
 * The Expo bridge over the native Android SDK. The com.kerdly.sdk sources are
 * vendored into this module by scripts/sync-native.mjs.
 *
 * Every function is an AsyncFunction on the main queue, so native calls run in the order JS made
 * them (configure first) and `configure` runs on the main thread like in a native app.
 */
class KerdlySdkModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("KerdlySdk")

    Events(ATTRIBUTION_EVENT)

    OnCreate {
      AttributionRelay.attach(this@KerdlySdkModule)
    }

    OnDestroy {
      AttributionRelay.detach(this@KerdlySdkModule)
    }

    AsyncFunction("configure") { options: ConfigureOptions ->
      val context = appContext.reactContext?.applicationContext
      if (context == null) {
        Log.w(TAG, "configure: no Android context; the SDK was not configured")
      } else if (options.key.isEmpty() || options.endpoint.isEmpty()) {
        Log.w(TAG, "configure: key and endpoint are required; the SDK was not configured")
      } else {
        Kerdly.configure(
          context,
          KerdlyOptions(
            key = options.key,
            endpoint = options.endpoint,
            environment = environment(options.environment),
            collectAdvertisingId = options.collectAdvertisingId,
            // The config plugin's `metaAppId` lands in the manifest; use it when JS passes none.
            metaAppId = options.metaAppId?.takeIf { it.isNotEmpty() } ?: manifestMetaAppId(context),
            logLevel = logLevel(options.logLevel),
            wrapper = options.wrapper,
          ),
        )
      }
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("setUserId") { userId: String? ->
      Kerdly.setUserId(userId)
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("track") { name: String, properties: Map<String, Any?> ->
      Kerdly.track(name, properties)
    }.runOnQueue(Queues.MAIN)

    // Standard events. JS passes every typed field, null when omitted, in the order
    // of the native signature; the SDK validates them again.
    AsyncFunction("trackRegistration") { method: String?, properties: Map<String, Any?> ->
      Kerdly.trackRegistration(method = method, properties = properties)
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("trackStartTrial") {
        productId: String?, value: Double?, currency: String?, transactionId: String?,
        properties: Map<String, Any?> ->
      Kerdly.trackStartTrial(
        productId = productId,
        value = value,
        currency = currency,
        transactionId = transactionId,
        properties = properties,
      )
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("trackSubscribe") {
        productId: String?, value: Double?, currency: String?, transactionId: String?,
        properties: Map<String, Any?> ->
      Kerdly.trackSubscribe(
        productId = productId,
        value = value,
        currency = currency,
        transactionId = transactionId,
        properties = properties,
      )
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("trackPurchase") {
        productId: String?, value: Double?, currency: String?, quantity: Int?, transactionId: String?,
        properties: Map<String, Any?> ->
      Kerdly.trackPurchase(
        productId = productId,
        value = value,
        currency = currency,
        quantity = quantity,
        transactionId = transactionId,
        properties = properties,
      )
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("setConsent") { analytics: Boolean?, ads: Boolean? ->
      Kerdly.setConsent(analytics, ads)
    }.runOnQueue(Queues.MAIN)

    // The second argument is the source the JS layer knows ("initial" for Linking's initial URL,
    // "runtime" for its `url` events, or null); the SDK infers it only when it is null.
    AsyncFunction("handleUrl") { url: String, source: String? ->
      Kerdly.handleUrl(url, source)?.let { toMap(it) }
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("setAppAccountToken") { token: String? ->
      Kerdly.setAppAccountToken(token)
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("setPartnerIds") { ids: Map<String, String> ->
      Kerdly.setPartnerIds(ids)
    }.runOnQueue(Queues.MAIN)

    // Accepts either platform's shape; only the Android fields are read. Android has no
    // entitlement sweep, so a purchase without purchaseToken is ignored.
    AsyncFunction("notifyPurchase") { purchase: PurchaseRecord? ->
      val token = purchase?.purchaseToken?.takeIf { it.isNotEmpty() }
      if (purchase == null || token == null) {
        Log.w(TAG, "notifyPurchase: purchaseToken is required on Android; ignored")
      } else {
        Kerdly.notifyPurchase(
          KerdlyPurchase(
            purchaseToken = token,
            orderId = purchase.orderId,
            products = purchase.products ?: emptyList(),
            purchaseTime = purchase.purchaseTime?.toLong(),
            obfuscatedAccountId = purchase.obfuscatedAccountId,
            obfuscatedProfileId = purchase.obfuscatedProfileId,
          ),
        )
      }
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("recordNetworkSend") { send: NetworkSendRecord ->
      if (send.network.isEmpty() || send.event.isEmpty()) {
        Log.w(TAG, "recordNetworkSend: network and event are required; ignored")
      } else {
        Kerdly.recordNetworkSend(
          KerdlyNetworkSend(
            network = send.network,
            event = send.event,
            eventId = send.eventId,
            value = send.value,
            currency = send.currency,
            flag = send.flag,
          ),
        )
      }
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("getAttribution") {
      Kerdly.attribution?.let { toMap(it) }
    }.runOnQueue(Queues.MAIN)

    // App Tracking Transparency is iOS-only (the JS layer does not even call this on Android).
    AsyncFunction("requestTrackingAuthorization") {
      "not_applicable"
    }

    AsyncFunction("flush") {
      Kerdly.flush()
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("getInstallId") {
      Kerdly.installId
    }.runOnQueue(Queues.MAIN)
  }

  companion object {
    private const val TAG = "Kerdly"
    const val ATTRIBUTION_EVENT = "onAttribution"
    const val META_APP_ID_KEY = "com.kerdly.sdk.META_APP_ID"

    fun environment(name: String): KerdlyEnvironment = when (name) {
      "production" -> KerdlyEnvironment.PRODUCTION
      "sandbox" -> KerdlyEnvironment.SANDBOX
      "development" -> KerdlyEnvironment.DEVELOPMENT
      else -> KerdlyEnvironment.AUTO
    }

    fun logLevel(name: String): KerdlyLogLevel = when (name) {
      "none" -> KerdlyLogLevel.NONE
      "error" -> KerdlyLogLevel.ERROR
      "info" -> KerdlyLogLevel.INFO
      "debug" -> KerdlyLogLevel.DEBUG
      else -> KerdlyLogLevel.WARN
    }

    /**
     * `com.kerdly.sdk.META_APP_ID` from the app manifest. The config plugin writes it as a string
     * resource; a hand-written numeric literal arrives as a number, hence `get` + `toString`.
     */
    @Suppress("DEPRECATION")
    fun manifestMetaAppId(context: Context): String? = try {
      val packageManager = context.packageManager
      val info = if (Build.VERSION.SDK_INT >= 33) {
        packageManager.getApplicationInfo(
          context.packageName,
          PackageManager.ApplicationInfoFlags.of(PackageManager.GET_META_DATA.toLong()),
        )
      } else {
        packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
      }
      info.metaData?.get(META_APP_ID_KEY)?.toString()?.takeIf { it.isNotEmpty() }
    } catch (error: Exception) {
      Log.w(TAG, "Could not read $META_APP_ID_KEY from the manifest", error)
      null
    }

    fun toMap(link: KerdlyDeepLink): Map<String, Any?> = mapOf(
      "url" to link.url,
      "cpp" to link.cpp,
      "ppid" to link.ppid,
      "clickId" to link.clickId,
      "visitId" to link.visitId,
      "campaignIds" to link.campaignIds,
    )

    /** `raw` stays the JSON string the SDK holds; the JS layer parses it. */
    fun toMap(attribution: KerdlyAttribution): Map<String, Any?> = mapOf(
      "state" to attribution.state,
      "network" to attribution.network,
      "status" to attribution.status,
      "method" to attribution.method,
      "campaignId" to attribution.campaignId,
      "campaign" to attribution.campaign,
      "adsetId" to attribution.adsetId,
      "adset" to attribution.adset,
      "adId" to attribution.adId,
      "ad" to attribution.ad,
      "keywordId" to attribution.keywordId,
      "keyword" to attribution.keyword,
      "linkId" to attribution.linkId,
      "cppId" to attribution.cppId,
      "decidedAt" to attribution.decidedAt?.toDouble(),
      "raw" to attribution.raw,
    )
  }
}

/**
 * `Kerdly.onAttribution` has no unregister, so the listener is registered once per process and
 * routed to the live module instance (a JS reload creates a new one).
 */
private object AttributionRelay {
  private var module: WeakReference<KerdlySdkModule>? = null
  private var registered = false

  fun attach(module: KerdlySdkModule) {
    val needsRegistration = synchronized(this) {
      this.module = WeakReference(module)
      val first = !registered
      registered = true
      first
    }
    if (needsRegistration) {
      Kerdly.onAttribution { attribution -> deliver(attribution) }
    }
  }

  fun detach(module: KerdlySdkModule) {
    synchronized(this) {
      if (this.module?.get() === module) this.module = null
    }
  }

  private fun deliver(attribution: KerdlyAttribution) {
    val target = synchronized(this) { module?.get() } ?: return
    try {
      target.sendEvent(KerdlySdkModule.ATTRIBUTION_EVENT, KerdlySdkModule.toMap(attribution))
    } catch (error: Exception) {
      Log.w("Kerdly", "Could not deliver the attribution event", error)
    }
  }
}

// Arguments (src/native.ts is the JS side of this contract).

class ConfigureOptions : Record {
  @Field val key: String = ""
  @Field val endpoint: String = ""
  @Field val environment: String = "auto"
  @Field val collectAdvertisingId: Boolean = true
  @Field val metaAppId: String? = null
  @Field val logLevel: String = "warn"
  @Field val wrapper: String? = null
}

class PurchaseRecord : Record {
  @Field val purchaseToken: String? = null
  @Field val orderId: String? = null
  @Field val products: List<String>? = null
  @Field val purchaseTime: Double? = null
  @Field val obfuscatedAccountId: String? = null
  @Field val obfuscatedProfileId: String? = null
}

class NetworkSendRecord : Record {
  @Field val network: String = ""
  @Field val event: String = ""
  @Field val eventId: String? = null
  @Field val value: Double? = null
  @Field val currency: String? = null
  @Field val flag: String? = null
}
