# Changelog: Kerdly web SDK

`@kerdly/web` on npm and the `kerdly.js` snippet on cdn.kerdly.com. Releases are tagged
`web-v<version>`. Until 1.0, a minor version may change the public API; `/v1/kerdly.js` only ever
moves to a release that works with the one before it.

## 0.1.0

First public release under the Kerdly name, on protocol v1.

- The endpoint is optional and defaults to `https://app.kerdly.com/api`.
- `kerdly.js` is served from `https://cdn.kerdly.com/v1/kerdly.js` (always the newest release) and
  `https://cdn.kerdly.com/<version>/kerdly.js` (pinned, with an `integrity` value).
- Sites updating from a pre-release build keep their visitor ids and link attribution.
- MIT license.
