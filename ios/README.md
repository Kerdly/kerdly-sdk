# Kerdly iOS SDK

`KerdlySDK` measures installs, users, events and purchases in your iOS app and sends them to your
Kerdly project. iOS 15+, Swift 5.9+, no third-party dependencies.

[Kerdly](https://kerdly.com) is profit analytics for subscription apps: it ties each install to the ad
that brought it and to the store revenue it earns. Docs: [kerdly.com/docs](https://kerdly.com/docs).

- [Install](#install)
- [Configure](#configure)
- [Users and consent](#users-and-consent)
- [Events](#events)
- [Purchases](#purchases)
- [Deep links](#deep-links)
- [Attribution](#attribution)
- [App Tracking Transparency](#app-tracking-transparency)
- [SKAdNetwork](#skadnetwork)
- [Data and privacy](#data-and-privacy)
- [Troubleshooting](#troubleshooting)

## Install

### Swift Package Manager

In Xcode: **File → Add Package Dependencies…**, enter `https://github.com/Kerdly/kerdly-sdk`,
choose **Up to Next Minor Version**, and add `KerdlySDK` to your app target.

In a `Package.swift`:

```swift
.package(url: "https://github.com/Kerdly/kerdly-sdk", .upToNextMinor(from: "0.1.0")),
// …
.product(name: "KerdlySDK", package: "kerdly-sdk")
```

### CocoaPods

```ruby
pod 'KerdlySDK', '~> 0.1.0'
```

## Configure

Call `configure` once, as early as possible, from `application(_:didFinishLaunchingWithOptions:)`
(or your SwiftUI `App` initializer). It returns immediately; the work happens in the background.

```swift
import KerdlySDK

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    var options = KerdlyOptions(key: "pk_live_…")   // your app's public key
    options.logLevel = .warn                         // .none, .error, .warn, .info, .debug
    Kerdly.configure(options)
    return true
}
```

| Option | Default | |
|---|---|---|
| `key` | required | The app's public key from your Kerdly project (`pk_live_…`, or `pk_test_…` for test builds). |
| `endpoint` | `https://app.kerdly.com/api` | Change it only if Kerdly support asks you to. |
| `environment` | `.auto` | `.production`, `.sandbox` or `.development`. `.auto` detects it from the build. |
| `collectAdvertisingId` | `true` | Read the IDFA when the user allowed tracking. |
| `skanWriter` | `false` | Let Kerdly write SKAdNetwork conversion values. See [SKAdNetwork](#skadnetwork). |
| `logLevel` | `.warn` | Console verbosity. |

Every other method is safe to call from any thread, before or after `configure` (earlier calls
run once the SDK has started), and never throws.

## Users and consent

```swift
Kerdly.setUserId(user.id)                      // after sign-in; nil on sign-out
Kerdly.setConsent(analytics: true, ads: true)  // reflect your consent screen
```

- `analytics: false` stops your custom and standard events; installs and opens are still counted.
- `ads: false` stops reading the advertising identifier and other ad-measurement signals.

## Events

### Standard events

Use these for the moments ad networks optimize on. Every argument is optional.

```swift
Kerdly.trackRegistration(method: "apple")
Kerdly.trackStartTrial(productId: "pro_weekly", value: 0, currency: "USD", transactionId: tx)
Kerdly.trackSubscribe(productId: "pro_weekly", value: 7.99, currency: "USD", transactionId: tx)
Kerdly.trackPurchase(productId: "coins_100", value: 4.99, currency: "USD", quantity: 1, transactionId: tx)
```

- `value` is what the user paid, in `currency` (`0` for a free trial).
- `currency` is a three-letter ISO 4217 code. A `value` without a valid currency is dropped.
- `quantity` is a whole number of 1 or more.
- `properties:` adds your own fields under the custom-event rules below.

### Custom events

```swift
Kerdly.track("quiz_completed", properties: ["score": 42, "level": "hard"])
```

- Names and property keys: lowercase letters, digits and `_`, starting with a letter, at most 40
  characters.
- At most 25 properties. Values are strings (up to 256 characters), numbers or booleans.
- An invalid name drops the event; an invalid property is dropped on its own. With
  `logLevel = .debug` the console says why.

## Purchases

Link each App Store purchase to the install so Kerdly can credit revenue to the right campaign.

```swift
// The appAccountToken your purchases carry (for example Superwall's alias UUID)
Kerdly.setAppAccountToken(accountTokenUUID)

// From your paywall's purchase callback
Kerdly.notifyPurchase(KerdlyPurchase(originalTransactionId: String(tx.originalID),
                                     transactionId: String(tx.id),
                                     productId: tx.productID,
                                     appAccountToken: tx.appAccountToken))

// Or with no argument, after a restore: links the current entitlements
Kerdly.notifyPurchase()
```

Each transaction is linked once; calling it again is harmless.

If your app also reports conversions to Meta or TikTok itself, record each send with the same
event id the network receives, so Kerdly can show both sides:

```swift
Kerdly.recordNetworkSend(KerdlyNetworkSend(network: "meta", event: "StartTrial",
                                           eventId: eventId, value: 0, currency: "USD"))
```

Ids from other SDKs can be attached with `Kerdly.setPartnerIds(["meta_anon_id": "…"])`.

## Deep links

Pass every URL your app is opened with to `Kerdly.handleUrl`. It records the open and returns
the Kerdly parameters it found; your app keeps its own navigation.

```swift
// UIApplicationDelegate
func application(_ app: UIApplication, open url: URL,
                 options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    Kerdly.handleUrl(url)
    return true
}

// UISceneDelegate
func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
           options connectionOptions: UIScene.ConnectionOptions) {
    connectionOptions.urlContexts.forEach { Kerdly.handleUrl($0.url) }
    connectionOptions.userActivities.compactMap(\.webpageURL).forEach { Kerdly.handleUrl($0) }
}
func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
    contexts.forEach { Kerdly.handleUrl($0.url) }
}
func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if let url = userActivity.webpageURL { Kerdly.handleUrl(url) }
}

// SwiftUI
.onOpenURL { Kerdly.handleUrl($0) }
```

Custom schemes and universal links both work.

## Attribution

```swift
Kerdly.onAttribution { attribution in
    // called on the main thread: now if known, and again if it changes
    print(attribution.network, attribution.campaign ?? "")
}

let current = Kerdly.attribution   // nil until known
let installId = Kerdly.installId
```

`Kerdly.flush()` sends queued events now, for example before a test ends.

## App Tracking Transparency

The SDK never shows the tracking prompt on its own. To ask:

```swift
let status = await Kerdly.requestTrackingAuthorization()
```

Add `NSUserTrackingUsageDescription` to your Info.plist first; without it the SDK does not ask
and returns the current status. The prompt appears once the app is active, and the answer is
recorded automatically.

## SKAdNetwork

Keep your `SKAdNetworkItems` and, if you receive postback copies,
`NSAdvertisingAttributionReportEndpoint` in Info.plist. To have Kerdly write conversion values,
set `options.skanWriter = true` and enable SKAdNetwork in your Kerdly project. Only one SDK in an
app should write conversion values, so turn off any other writer in the same release.

## Data and privacy

What the SDK sends, for your App Store privacy answers:

| Data | When |
|---|---|
| An install id generated by the SDK, and the IDFV | always |
| Device model, OS version, language, time zone, app version | always |
| Apple Ads attribution token and the App Store's install record (AppTransaction) | once per install |
| App events you track | with `analytics` consent |
| Purchase identifiers | when you call `notifyPurchase` |
| IDFA | only with tracking authorized, `ads` consent and `collectAdvertisingId` |
| Public IPv6 address | with `ads` consent |
| The user id you set | when you call `setUserId` |
| The IDFA (when allowed), sent to Meta and TikTok to ask which ad led to the install | only when you turn on deferred deep links in your Kerdly project, with `ads` consent |

The SDK never collects names, email addresses, phone numbers, location or clipboard contents.
It ships a privacy manifest (`PrivacyInfo.xcprivacy`) that Xcode includes in your app's privacy
report.

## Troubleshooting

- Set `options.logLevel = .debug` and filter the Xcode console for `[Kerdly]`.
- Events show up in your Kerdly project within a minute; call `Kerdly.flush()` to send at once.
- A `pk_test_` key keeps test traffic out of your production reports.
- Questions or problems: [open an issue](https://github.com/Kerdly/kerdly-sdk/issues) or contact
  Kerdly support. Never post your keys.
