# Kerdly SDKs

[![CI](https://github.com/Kerdly/kerdly-sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/Kerdly/kerdly-sdk/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Client SDKs for [Kerdly](https://kerdly.com): measure installs, users, events, purchases, deep links
and web-to-app clicks, and send them to your Kerdly project.

| Platform | Package | Install | Docs |
|---|---|---|---|
| iOS | `KerdlySDK` | SwiftPM `https://github.com/Kerdly/kerdly-sdk` or `pod 'KerdlySDK'` | [ios/](ios/README.md) |
| Android | `com.kerdly:kerdly-sdk` | `implementation("com.kerdly:kerdly-sdk:0.1.0")` | [android/](android/README.md) |
| Expo / React Native | `@kerdly/expo` | `npx expo install @kerdly/expo` | [expo/](expo/README.md) |
| Web | `@kerdly/web`, `kerdly.js` | `npm install @kerdly/web` or the snippet | [web/](web/README.md) |

You need a Kerdly project and its public key: `pk_live_…` for apps, `wk_live_…` for the web. Keys
are on the project's settings page at [app.kerdly.com](https://app.kerdly.com). Every SDK sends to
`https://app.kerdly.com/api` unless you set another endpoint.

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
