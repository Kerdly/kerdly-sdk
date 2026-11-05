# Kerdly Android SDK

`com.kerdly:kerdly-sdk` measures installs, users, events and purchases in your Android app and
sends them to your Kerdly project. minSdk 24, Kotlin or Java.

[Kerdly](https://kerdly.com) is profit analytics for subscription apps: it ties each install to the ad
that brought it and to the store revenue it earns. Docs: [kerdly.com/docs](https://kerdly.com/docs).

- [Install](#install)
- [Configure](#configure)
- [Users and consent](#users-and-consent)
- [Events](#events)
- [Purchases](#purchases)
- [Deep links](#deep-links)
- [Attribution](#attribution)
- [Permissions and manifest](#permissions-and-manifest)
- [Data and privacy](#data-and-privacy)
- [Troubleshooting](#troubleshooting)

## Install

The SDK is on Maven Central.

```kotlin
// app/build.gradle.kts
dependencies {
    implementation("com.kerdly:kerdly-sdk:0.1.0")
}
```

## Configure

Call `configure` once, in `Application.onCreate`:

```kotlin
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        Kerdly.configure(
            this,
            KerdlyOptions(
                key = "pk_live_…",          // your app's public key
                metaAppId = "1234567890",   // optional: your Facebook app id
            ),
        )
    }
}
```

| Option | Default | |
|---|---|---|
| `key` | required | The app's public key from your Kerdly project (`pk_live_…`, or `pk_test_…` for test builds). |
| `endpoint` | `https://app.kerdly.com/api` | Change it only if Kerdly support asks you to. |
| `environment` | `AUTO` | `PRODUCTION`, `SANDBOX` or `DEVELOPMENT`. `AUTO` is `DEVELOPMENT` for a debuggable build. |
| `collectAdvertisingId` | `true` | Read the Google advertising id when allowed. |
| `metaAppId` | none | Your Facebook app id. Enables Meta install attribution. |
| `logLevel` | `WARN` | `NONE`, `ERROR`, `WARN`, `INFO`, `DEBUG`. |

`configure` returns immediately; the work happens on the SDK's own thread. Every method is safe
from any thread and never throws. Calls made before `configure` run right after it.

Each key belongs to one application id. A build with an `applicationIdSuffix` (for example
`.debug`) needs its own key.

## Users and consent

```kotlin
Kerdly.setUserId(user.id)                          // after sign-in; null on sign-out
Kerdly.setConsent(analytics = true, ads = true)    // reflect your consent screen
```

- `analytics = false` stops your custom and standard events; installs and opens are still counted.
- `ads = false` stops reading the advertising id and other ad-measurement signals.

## Events

### Standard events

Use these for the moments ad networks optimize on. Every argument is optional, and Java callers
get overloads.

```kotlin
Kerdly.trackRegistration(method = "google")
Kerdly.trackStartTrial(productId, value = 0.0, currency = "USD", transactionId = orderId)
Kerdly.trackSubscribe(productId, value = 7.99, currency = "USD", transactionId = orderId)
Kerdly.trackPurchase(productId, value = 4.99, currency = "EUR", quantity = 1, transactionId = orderId)
```

- `value` is what the user paid, in `currency` (`0.0` for a free trial).
- `currency` is a three-letter ISO 4217 code. A `value` without a valid currency is dropped.
- `quantity` is a whole number of 1 or more.
- `properties` adds your own fields under the custom-event rules below.

### Custom events

```kotlin
Kerdly.track("quiz_completed", mapOf("score" to 42, "level" to "hard"))
```

- Names and property keys: lowercase letters, digits and `_`, starting with a letter, at most 40
  characters.
- At most 25 properties. Values are strings (up to 256 characters), numbers or booleans.
- An invalid name drops the event; an invalid property is dropped on its own. With
  `logLevel = DEBUG` logcat says why.

## Purchases

Link each Google Play purchase to the install so Kerdly can credit revenue to the right campaign.

```kotlin
// The obfuscatedAccountId your purchases carry (for example Superwall's alias)
Kerdly.setAppAccountToken(accountId)

// From your paywall's or billing client's purchase callback
Kerdly.notifyPurchase(
    KerdlyPurchase(
        purchaseToken = purchase.purchaseToken,
        orderId = purchase.orderId,
        products = purchase.products,
        purchaseTime = purchase.purchaseTime,
        obfuscatedAccountId = purchase.accountIdentifiers?.obfuscatedAccountId,
    ),
)
```

Each purchase token is linked once; calling it again is harmless.

If your app also reports conversions to Meta or TikTok itself, record each send with the same
event id the network receives:

```kotlin
Kerdly.recordNetworkSend(KerdlyNetworkSend("meta", "StartTrial", eventId, 0.0, "USD"))
```

Ids from other SDKs can be attached with `Kerdly.setPartnerIds(mapOf("superwall_alias" to alias))`.

## Deep links

Forward every URL your app is opened with. The SDK records the open and returns the Kerdly
parameters it found; your app keeps its own navigation.

```kotlin
override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    intent?.dataString?.let { Kerdly.handleUrl(it) }
}

override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    intent.dataString?.let { Kerdly.handleUrl(it) }
}
```

Custom schemes and App Links both work.

## Attribution

```kotlin
Kerdly.onAttribution { attribution ->
    // main thread: now if known, and again if it changes
    Log.d("App", "${attribution.network} ${attribution.campaign}")
}

val current = Kerdly.attribution   // null until known
val installId = Kerdly.installId
```

`Kerdly.flush()` sends queued events now.

## Permissions and manifest

The library adds to your merged manifest:

- `android.permission.INTERNET`;
- `com.google.android.gms.permission.AD_ID`;
- `<queries>` for the Facebook, Instagram and Facebook Lite apps, used for Meta install
  attribution on Android 11+.

Apps for children or in the Families program should remove the advertising id permission and
turn its collection off:

```xml
<uses-permission android:name="com.google.android.gms.permission.AD_ID" tools:node="remove"/>
```

```kotlin
KerdlyOptions(key = "pk_live_…", collectAdvertisingId = false)
```

The SDK's data is excluded from Auto Backup, so no backup rules are needed. ProGuard/R8 rules are
included in the library.

## Data and privacy

What the SDK sends, for your Google Play data safety form:

| Data | When |
|---|---|
| An install id generated by the SDK | always |
| Device model, OS version, language, time zone, app version, installer | always |
| Google Play and Meta install referrers | once per install |
| App events you track | with `analytics` consent |
| Purchase identifiers | when you call `notifyPurchase` |
| Google advertising id | with `ads` consent and `collectAdvertisingId`, unless the user limited ad tracking |
| Public IPv6 address | with `ads` consent |
| The user id you set | when you call `setUserId` |
| The Google advertising id and install referrer, sent to TikTok to ask which ad led to the install | only when you turn on deferred deep links in your Kerdly project, with `ads` consent |

The SDK never collects names, email addresses, phone numbers, location or contacts.

## Troubleshooting

- Set `logLevel = KerdlyLogLevel.DEBUG` and filter logcat for `Kerdly`.
- Events show up in your Kerdly project within a minute; call `Kerdly.flush()` to send at once.
- A `pk_test_` key keeps test traffic out of your production reports.
- Questions or problems: [open an issue](https://github.com/Kerdly/kerdly-sdk/issues) or contact
  Kerdly support. Never post your keys.
