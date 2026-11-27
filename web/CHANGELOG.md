# Changelog: Kerdly web SDK

`@kerdly/web` on npm and the `kerdly.js` snippet on cdn.kerdly.com. Releases are tagged
`web-v<version>`. Until 1.0, a minor version may change the public API; `/v1/kerdly.js` only ever
moves to a release that works with the one before it.

## 0.1.1

- Each visit and click carries the browser's user agent (`ua`, at most 512 characters). Some
  hosting front ends replace the request's `User-Agent` on its way to the collector, which then
  lost the device type and the user agent that Meta's website events need. The collector reads the
  body's only when the request's own is missing or replaced.
- Dev dependencies: fix the Dependabot alerts (undici, glob, minimatch, uuid).
- README and package pages: what Kerdly is, links to kerdly.com and its docs.

## 0.1.0

First public release under the Kerdly name, on protocol v1.

- The endpoint is optional and defaults to `https://app.kerdly.com/api`.
- `kerdly.js` is served from `https://cdn.kerdly.com/v1/kerdly.js` (always the newest release) and
  `https://cdn.kerdly.com/<version>/kerdly.js` (pinned, with an `integrity` value).
- Sites updating from a pre-release build keep their visitor ids and link attribution.
- MIT license.
