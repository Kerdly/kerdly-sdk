# Changelog

All four packages share one version. Until 1.0, a minor version may change the public API.

## 0.1.0

First public release under the Kerdly name.

- iOS `KerdlySDK`, Android `com.kerdly:kerdly-sdk`, Expo `@kerdly/expo`, web `@kerdly/web` and the
  `kerdly.js` snippet, all on protocol v1.
- The endpoint is optional and defaults to `https://app.kerdly.com/api`.
- `kerdly.js` is served from `https://cdn.kerdly.com/v1/kerdly.js` (always the newest release) and
  `https://cdn.kerdly.com/<version>/kerdly.js` (pinned, with an `integrity` value).
- Apps and sites updating from a pre-release build keep their install ids, visitor ids, queued
  events and link attribution.
- MIT license.
