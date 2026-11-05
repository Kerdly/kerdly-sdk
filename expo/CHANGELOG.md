# Changelog: Kerdly Expo SDK

`@kerdly/expo` on npm. It contains the iOS and Android SDKs, so each release lists the versions it
carries. Releases are tagged `expo-v<version>`. Until 1.0, a minor version may change the public
API.

## 0.1.0

First public release under the Kerdly name, on protocol v1, with iOS SDK 0.1.0 and Android SDK
0.1.0.

- The endpoint is optional and defaults to `https://app.kerdly.com/api`.
- Apps updating from a pre-release build keep their install ids, queued events and link
  attribution.
- A secret `sk_` key leaves the SDK off, as on Android and the web.
- `Kerdly.debugFetchDeferredLinks` works only in debug builds and asks only when tracking is authorized; the
  pre-release `ignoreAtt` option is gone.
- MIT license.
