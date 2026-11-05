# Kerdly SDKs

[![CI](https://github.com/Kerdly/kerdly-sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/Kerdly/kerdly-sdk/actions/workflows/ci.yml)
[![npm @kerdly/web](https://img.shields.io/npm/v/@kerdly/web?label=%40kerdly%2Fweb)](https://www.npmjs.com/package/@kerdly/web)
[![npm @kerdly/expo](https://img.shields.io/npm/v/@kerdly/expo?label=%40kerdly%2Fexpo)](https://www.npmjs.com/package/@kerdly/expo)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[Kerdly](https://kerdly.com) is profit analytics for subscription apps: your app's P&L, down to the
ad. It lines up App Store, Google Play and RevenueCat revenue with ad spend from Meta, TikTok, Apple
Ads, Google Ads and Reddit, and shows which ads pay back.

This repository holds Kerdly's open-source SDKs for iOS, Android, Expo / React Native and the web.
They give your app and website first-party attribution, with no third-party MMP: they measure
installs, users, in-app events, trials, subscriptions and purchases, deep links and web-to-app
clicks, and send them to your Kerdly project. Kerdly ties each install to the ad that brought it
and to the revenue the stores report.

**[Docs](https://kerdly.com/docs)** · **[Quickstart](https://kerdly.com/docs/get-started)** ·
**[Dashboard](https://app.kerdly.com)** · **[Docs for AI coding agents](https://kerdly.com/llms.txt)**

## What Kerdly does with this data

- **[Attribution and links](https://kerdly.com/product/attribution):** first-party attribution for
  iOS, Android and the web, smart links, deferred deep links, web-to-app funnels and SKAdNetwork.
- **[Revenue and cohorts](https://kerdly.com/product/cohorts):** LTV, retention and ROAS at day 7
  and day 30 for every install day, by network, campaign and ad.
- **[P&L](https://kerdly.com/product/pl):** store proceeds, Apple and Google payouts and ad spend in
  one statement, with a break-even cost per install for every market.
- **[Postbacks and server events](https://kerdly.com/product/postbacks):** trials, subscriptions and
  purchases sent back to Meta, TikTok and Google from the server, so their algorithms learn from
  paying users.

See [pricing](https://kerdly.com/pricing) and [integrations](https://kerdly.com/integrations).

## SDKs

| Platform | Package | Install | Guide |
|---|---|---|---|
| iOS | `KerdlySDK` | SwiftPM `https://github.com/Kerdly/kerdly-sdk` or `pod 'KerdlySDK'` | [ios/README](ios/README.md) |
| Android | `com.kerdly:kerdly-sdk` | `implementation("com.kerdly:kerdly-sdk:0.1.0")` | [android/README](android/README.md) |
| Expo / React Native | `@kerdly/expo` | `npx expo install @kerdly/expo` | [kerdly.com/docs/sdks/expo](https://kerdly.com/docs/sdks/expo), [expo/README](expo/README.md) |
| Web | `@kerdly/web`, `kerdly.js` | `npm install @kerdly/web` or the snippet | [kerdly.com/docs/sdks/web](https://kerdly.com/docs/sdks/web), [web/README](web/README.md) |

You need a Kerdly project and its public key: `pk_live_…` for apps, `wk_live_…` for the web. Keys
are in each app's settings at [app.kerdly.com](https://app.kerdly.com). Every SDK sends to
`https://app.kerdly.com/api` unless you set another endpoint. To see how a click, a visit, an
install, a trial and a renewal connect, read [Track the whole funnel](https://kerdly.com/docs/sdks/funnel).

## Quick start

**iOS**

```swift
import KerdlySDK

Kerdly.configure(KerdlyOptions(key: "pk_live_…"))
```

**Android**

```kotlin
Kerdly.configure(this, KerdlyOptions(key = "pk_live_…"))
```

**Expo / React Native**

```ts
import { Kerdly } from '@kerdly/expo';

Kerdly.configure({ key: 'pk_live_…' });
```

**Web**

```ts
import { createKerdly } from '@kerdly/web';

const kerdly = createKerdly({ key: 'wk_live_…' });
```

Each platform's README covers deep links, users and consent, purchases, standard events and what the
SDK collects on its own.

## Versions and releases

Each SDK has its own version and is released only when it changes. Releases are tagged in this
repository: iOS with the bare version (`0.1.0`, what Swift Package Manager and CocoaPods resolve),
the others as `android-v0.1.0`, `expo-v0.1.0` and `web-v0.1.0`. Each SDK's folder has its
changelog. Until 1.0, a minor version may change the public API.

## Support

Open an issue for bugs and questions. Never post API keys, user data or crash logs that contain
them. Report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
