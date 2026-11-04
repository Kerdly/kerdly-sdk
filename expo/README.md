# @kerdly/expo

The Kerdly SDK for Expo and React Native apps. It runs the native Kerdly SDKs for
[iOS](https://github.com/Kerdly/kerdly-sdk/blob/main/ios/README.md) and [Android](https://github.com/Kerdly/kerdly-sdk/blob/main/android/README.md) inside your app, adds a config plugin, and
captures deep links automatically.

It needs a development or production build (`npx expo prebuild` / EAS Build). Expo Go and web do
not contain the native code: there every call is a no-op, with one development warning. It needs
Expo SDK 52 or newer (native modules as event emitters) and is developed against SDK 57.

## Install

```sh
npx expo install @kerdly/expo
```

Add the config plugin to `app.json` / `app.config.ts`, then run `npx expo prebuild` (or build with EAS):

```json
{
  "expo": {
    "plugins": [
      [
        "@kerdly/expo",
        {
          "metaAppId": "1234567890123456",
          "userTrackingPermission": "Lets us measure which of our ads brought you here.",
          "skanEndpoint": "https://kerdly-skan.com"
        }
      ]
    ]
  }
}
```

| Option | Platform | Writes |
|---|---|---|
| `metaAppId` | Android | `<meta-data android:name="com.kerdly.sdk.META_APP_ID" android:value="@string/afr_meta_app_id">` plus that string resource. A string resource because a numeric literal in `android:value` is compiled as a number, not a string. Removed again when the option is dropped. |
| `userTrackingPermission` | iOS | `NSUserTrackingUsageDescription`, the App Tracking Transparency prompt text. Needed for `requestTrackingAuthorization()`. |
| `skanEndpoint` | iOS | `NSAdvertisingAttributionReportEndpoint`, the https origin that receives copies of SKAdNetwork postbacks. |

The plugin only sets keys it is given and never removes an Info.plist key, so values set in
`ios.infoPlist` survive. Running it twice changes nothing. `Kerdly.configure({ metaAppId })` overrides
the plugin's `metaAppId`.

The module's Android manifest adds `INTERNET`, `com.google.android.gms.permission.AD_ID` and
`<queries>` for `com.facebook.katana`, `com.instagram.android` and `com.facebook.lite` (Meta Install
Referrer). An app that must not read the advertising id removes `AD_ID` (Expo's
`android.blockedPermissions`) and passes `collectAdvertisingId: false`.

## Configure

Call `configure` once, as early as possible: at module scope of the root file (`app/_layout.tsx`
with Expo Router, `App.tsx` otherwise), not inside a component.

```ts
import { Kerdly } from '@kerdly/expo';

Kerdly.configure({
  key: 'pk_live_…',                    // the app's public key (pk_test_… for test builds)
  // endpoint: 'https://app.kerdly.com/api', // default
  // environment: 'auto',              // 'production' | 'sandbox' | 'development'
  // collectAdvertisingId: true,
  // skanWriter: false,                // iOS: write SKAdNetwork conversion values
  // metaAppId: '…',                   // Android; defaults to the plugin's metaAppId
  // logLevel: 'warn',                 // 'none' | 'error' | 'warn' | 'info' | 'debug'
  // autoDeepLinks: true,
});
```

A second `configure` is ignored. Calls made before `configure` are held and run after it.

No function throws and no promise rejects. Invalid input is dropped with a development warning
(`console.warn`, only when `__DEV__`, silenced by `logLevel: 'none' | 'error'`).

## API

| Call | Does |
|---|---|
| `await Kerdly.configure(options)` | Starts the native SDK; resolves once the native `configure` has run. |
| `Kerdly.setUserId(id \| null)` | The app's user id, attached to every later event (`$identify` on change). |
| `Kerdly.track(name, props?)` | A custom event. `name` and prop keys match `^[a-z][a-z0-9_]{0,39}$`; at most 25 props; values are strings (truncated to 256), finite numbers or booleans. An invalid name drops the event; invalid props are dropped one by one. |
| `Kerdly.trackRegistration({ method?, properties? })` | Standard event `registration`: the user signed up (`method`: `anonymous`, `apple`, `google`, `email`, …). See [Standard events](#standard-events). |
| `Kerdly.trackStartTrial({ productId?, value?, currency?, transactionId?, properties? })` | Standard event `start_trial` (`value: 0` for a free trial). |
| `Kerdly.trackSubscribe({ productId?, value?, currency?, transactionId?, properties? })` | Standard event `subscribe`. |
| `Kerdly.trackPurchase({ productId?, value?, currency?, quantity?, transactionId?, properties? })` | Standard event `purchase`, a one-time purchase. |
| `Kerdly.setConsent({ analytics?, ads? })` | An omitted flag keeps its value. `analytics: false` keeps only the SDK's own events; `ads: false` stops IDFA / GAID reads. |
| `await Kerdly.handleUrl(url)` | Records `$deeplink` and returns `{ url, cpp, ppid, afrC, afrV, campaignIds }` (each `null` when absent), or `null`. |
| `Kerdly.setAppAccountToken(token \| null)` | iOS: the StoreKit `appAccountToken` UUID. Android: the Play `obfuscatedAccountId` the purchases carry. |
| `Kerdly.setPartnerIds({ meta_anon_id: '…' })` | Ids other SDKs own; merged, an empty value removes a key. |
| `Kerdly.notifyPurchase(purchase?)` | `$purchase_link`, once per transaction / token. iOS shape `{ originalTransactionId, transactionId, productId, appAccountToken }`; Android shape `{ purchaseToken, orderId, products, purchaseTime, obfuscatedAccountId, obfuscatedProfileId }`. Each platform reads its own fields. On iOS, calling it with no purchase sweeps `Transaction.currentEntitlements`; Android needs `purchaseToken`. |
| `Kerdly.recordNetworkSend({ network, event, eventId?, value?, currency?, flag? })` | `$network_send`: a conversion the app sent to an ad network itself. |
| `await Kerdly.getAttribution()` | The install's attribution (`network`, `campaign`, …; `raw` holds every field), or `null` until it is known. |
| `Kerdly.addAttributionListener(fn)` | Calls `fn` with the current attribution at once (when known) and on every change, like the native `onAttribution`. Returns `{ remove() }`. |
| `await Kerdly.requestTrackingAuthorization()` | iOS: shows the ATT prompt once the app is active and resolves the status. Android: `"not_applicable"`. |
| `await Kerdly.flush()` | Asks the native SDK to send its queue now. |
| `await Kerdly.getInstallId()` | The install id (lowercase UUID), or `null` before `configure`. |

### Standard events

`trackRegistration`, `trackStartTrial`, `trackSubscribe` and `trackPurchase` send Kerdly's standard
events with typed fields. Every field is optional, and a malformed field is dropped with a development
warning, never the event:

- `productId`, `transactionId`: non-empty strings, cut to 128 characters; `method`: cut to 64.
- `value`: what the user paid in `currency`, a finite number ≥ 0 (`0` for a free trial).
- `currency`: three letters (ISO 4217), upper-cased. Without a valid `currency` the `value` is
  dropped, because a value without a currency means nothing to an ad network.
- `quantity`: an integer ≥ 1.
- `properties`: extra custom props under the `track` rules. A key that is one of the event's typed
  props (`value`, `product_id`, …) is dropped: set it through the typed field. A field the event
  does not have (say `quantity` on `trackSubscribe`, or a snake_case `product_id`) is reported and
  ignored.

```ts
Kerdly.trackRegistration({ method: 'apple' });
Kerdly.trackStartTrial({ productId: 'car_weekly_pro', value: 0, currency: 'USD', transactionId });
Kerdly.trackSubscribe({ productId: 'car_weekly_pro', value: 7.99, currency: 'USD', transactionId, properties: { plan: 'weekly' } });
```

`track('start_trial', …)` also works and gets the same checks.

### Deep links

With `autoDeepLinks: true` (the default) `configure` forwards React Native `Linking` URLs to the
native `handleUrl`: the initial URL once per JS runtime, and every `url` event. `expo-dev-client`
launcher URLs (`<scheme>://expo-development-client/…`) are skipped. Do not also call `handleUrl` for
those URLs; use it for links that never reach `Linking` (for example a deferred link from another
SDK), or turn `autoDeepLinks` off and call it yourself.

The automatic capture tells the native SDK which URL it is: `initial` for the launch URL, `runtime`
for a later `url` event. A URL passed to `Kerdly.handleUrl` yourself leaves that to the native SDK: the
first URL after launch, before the app went to the background, counts as `initial` (iOS also
requires it within 60 s of `configure`).

### Attribution

```tsx
const [attribution, setAttribution] = useState<KerdlyAttribution | null>(null);

useEffect(() => {
  const sub = Kerdly.addAttributionListener(setAttribution);
  return () => sub.remove();
}, []);
```

## Superwall hand-off

Tell the SDK which account token the purchases will carry, then link each completed transaction
(`expo-superwall`):

```tsx
import { useEffect } from 'react';
import { Platform } from 'react-native';
import { useSuperwallEvents, useUser } from 'expo-superwall';
import { Kerdly } from '@kerdly/expo';

export function KerdlySuperwallBridge() {
  const { user } = useUser();
  const alias = user?.aliasId; // "$SuperwallAlias:3F2504E0-4F89-41D3-9A0C-0305E82C3301"

  useEffect(() => {
    if (!alias) return;
    const aliasUuid = alias.replace(/^\$SuperwallAlias:/, '');
    // iOS takes the StoreKit appAccountToken (a UUID); Android takes the Play obfuscatedAccountId,
    // which (per the native Android SDK) is the alias string itself before identify.
    Kerdly.setAppAccountToken(Platform.OS === 'ios' ? aliasUuid : alias);
    Kerdly.setPartnerIds({ superwall_alias: alias });
  }, [alias]);

  useSuperwallEvents({
    onSuperwallEvent: ({ event }) => {
      if (event.event !== 'transactionComplete') return;
      const tx = event.transaction;
      if (Platform.OS === 'ios') {
        Kerdly.notifyPurchase({
          originalTransactionId: tx?.originalTransactionIdentifier,
          transactionId: tx?.storeTransactionId,
          productId: event.product.productIdentifier,
          appAccountToken: tx?.appAccountToken,
        });
      } else if (tx?.purchaseToken) {
        Kerdly.notifyPurchase({
          purchaseToken: tx.purchaseToken,
          orderId: tx.storeTransactionId,
          products: [event.product.productIdentifier],
        });
      }
    },
  });

  return null;
}
```

Render it inside `<SuperwallProvider>`. On iOS, `Kerdly.notifyPurchase()` with no argument (after a
restore, say) sweeps the current entitlements instead.

## Recording sends to ad networks

When the app reports a conversion to Meta or TikTok through their SDKs, record the same send right
after it, with the same event id the network gets, so Kerdly can show both sides:

```ts
const eventId = `${originalTransactionId}:trial_start`;

// your existing Meta call (react-native-fbsdk-next, for example), sent with eventId
Kerdly.recordNetworkSend({
  network: 'meta',
  event: 'StartTrial',
  eventId,
  value: 0,
  currency: 'USD',
  flag: 'meta_start_trial_enabled', // the feature flag that allowed the send, if any
});

// your existing TikTok call, sent with eventId
Kerdly.recordNetworkSend({ network: 'tiktok', event: 'Subscribe', eventId, value: 9.99, currency: 'USD' });
```

## Data and privacy

The native SDKs do the collecting. See [iOS: Data and privacy](https://github.com/Kerdly/kerdly-sdk/blob/main/ios/README.md#data-and-privacy) and
[Android: Data and privacy](https://github.com/Kerdly/kerdly-sdk/blob/main/android/README.md#data-and-privacy) for your App Store and Google Play
answers.

## Troubleshooting

- `logLevel: 'debug'` turns on native logs (`[Kerdly]` in the Xcode console and logcat) and
  development warnings for invalid input.
- Questions or problems: [open an issue](https://github.com/Kerdly/kerdly-sdk/issues) or contact
  Kerdly support. Never post your keys.
