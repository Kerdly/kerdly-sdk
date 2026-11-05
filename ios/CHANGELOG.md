# Changelog: Kerdly iOS SDK

`KerdlySDK` on Swift Package Manager and CocoaPods. Releases are tagged with the bare version
(`0.1.0`). Until 1.0, a minor version may change the public API.

## 0.1.0

First public release under the Kerdly name, on protocol v1.

- The endpoint is optional and defaults to `https://app.kerdly.com/api`.
- Apps updating from a pre-release build keep their install ids, queued events and link
  attribution.
- A secret `sk_` key leaves the SDK off, as on Android and the web.
- `Kerdly.debugFetchDeferredLinks` works only in debug builds and asks only when tracking is authorized; the
  pre-release `ignoreAtt` option is gone.
- MIT license.
