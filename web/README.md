# @kerdly/web

The Kerdly SDK for websites and landing pages. It gives each visitor a first-party id, records
page visits and clicks on your app links, and passes the visitor on to the app store, so Kerdly
can connect ad clicks on the web to installs and revenue in your app.

[Kerdly](https://kerdly.com) is profit analytics for subscription apps. The full guide is at
[kerdly.com/docs/sdks/web](https://kerdly.com/docs/sdks/web).

- [Install](#install)
- [Options](#options)
- [API](#api)
- [App links](#app-links)
- [Identify signed-in users](#identify-signed-in-users)
- [Ad pixels](#ad-pixels)
- [Cookies and storage](#cookies-and-storage)
- [Consent](#consent)
- [Troubleshooting](#troubleshooting)

No runtime dependencies; the snippet is about 4 KB gzipped.

## Install

Pick one. Both behave the same.

### The snippet

```html
<script src="https://cdn.kerdly.com/v1/kerdly.js" data-key="wk_live_…" async></script>
```

It records a visit for the page, handles clicks on your app links, and exposes the instance as
`window.kerdly`. Because it loads `async`, check that `window.kerdly` exists before calling it.

`/v1/kerdly.js` is always the newest release, so your site gets fixes without a change on your
side. Every release behind that address stays compatible with the one before it; a change that
isn't would get a new address (`/v2/`).

To review each update yourself instead, pin a release. Its file never changes, and the
`integrity` attribute makes the browser refuse anything else:

```html
<script src="https://cdn.kerdly.com/0.1.0/kerdly.js"
        integrity="sha384-…" crossorigin="anonymous"
        data-key="wk_live_…" async></script>
```

The `integrity` value of every release is in its
[GitHub release notes](https://github.com/Kerdly/kerdly-sdk/releases) and in
[cdn.kerdly.com/versions.json](https://cdn.kerdly.com/versions.json). Every file on
cdn.kerdly.com is the `dist/kerdly.js` of the same `@kerdly/web` release on npm.

If your site sends a Content-Security-Policy, allow `https://cdn.kerdly.com` in `script-src` and
`https://app.kerdly.com` and `https://api6.ipify.org` (the IPv6 lookup) in `connect-src`.

TypeScript:

```ts
import type { Kerdly } from "@kerdly/web";
declare global { interface Window { kerdly?: Kerdly } }
```

### npm

```sh
npm install @kerdly/web
```

```ts
import { createKerdly } from "@kerdly/web";

const kerdly = createKerdly({ key: "wk_live_…" });
```

Create one instance per page, once, on the client. Importing the package is safe in
server-rendered code; on the server `createKerdly` returns an instance that does nothing.

## Options

| Option | Snippet attribute | Default | |
|---|---|---|---|
| `key` | `data-key` | required | Your project's public web key (`wk_live_…`). Never use a secret `sk_` key in a page; the SDK refuses it. |
| `endpoint` | `data-endpoint` | `https://app.kerdly.com/api` | Where data is sent. A snippet you host yourself sends to the address it was loaded from unless you set this. |
| `cookieDomain` | `data-cookie-domain` | your site's main domain | Set it if your site is on a shared hosting domain (`*.vercel.app`, `*.github.io`) or an unusual country domain. |
| `visitorCookie` | `data-visitor-cookie` | `kerdly_vid` | Name an existing first-party id cookie to reuse it. It must be readable by JavaScript (not `HttpOnly`). |
| `autoVisit` | | `true` | Record a visit when the SDK starts. |
| `autoDecorate` | `data-auto-decorate` | `a[data-kerdly-link]` | Which links are app links: a CSS selector, or `false` to turn it off. |
| `ipv6EchoUrl` | `data-ipv6-echo-url` | on | Looks up the visitor's public IPv6 address once per tab. `null` (or an empty attribute) turns it off. |

## API

No method throws.

| Method | Returns | |
|---|---|---|
| `kerdly.visit(options?)` | `boolean` | Records a visit to the current page. Safe to call on every route change in a single-page app; a repeat for the same URL is ignored unless `{ force: true }`. |
| `kerdly.click(url)` | `string` | Records a click on an app link and returns the URL to navigate to: `location.href = kerdly.click(url)`. |
| `kerdly.decorate(url)` | `string` | Returns the URL with the visitor id added, without recording a click. |
| `kerdly.identify(userId)` | `boolean` | Links this visitor to your own user id. See below. |
| `kerdly.eventId(name)` | `string` | An event id to share between a browser pixel event and the same event sent from your server. |
| `kerdly.visitorId()` | `string` | The visitor id. |

## App links

Mark the links that lead to your app (your Kerdly links or store links):

```html
<a href="https://go.example.com/k3f9q2x" data-kerdly-link>Get the app</a>
```

When one is clicked, the SDK records the click and adds the visitor id to the link, then lets the
browser navigate as usual. New-tab and middle clicks work, and links added to the page later are
covered. For navigation in your own code, use `kerdly.click(url)`.

## Identify signed-in users

If your site has accounts, tell Kerdly who the visitor is after sign-in, so events your server
reports for that user are credited to the visitor's ad click:

```js
onAuthStateChanged(auth, (user) => { if (user) kerdly.identify(user.uid); });
```

`userId` is a string of 1 to 128 characters. Repeating the same call is free; it is sent once.

## Ad pixels

Give pixel events an id from `eventId`, and send the same id from your server, so the ad network
counts the event once:

```js
fbq("track", "Lead", {}, { eventID: kerdly.eventId("Lead") });
ttq.track("ViewContent", {}, { event_id: kerdly.eventId("ViewContent") });
```

## Cookies and storage

| Name | Where | Lifetime | Purpose |
|---|---|---|---|
| `kerdly_vid` (or your `visitorCookie`) | first-party cookie | 400 days (7 days in Safari for script-set cookies) | The visitor id |
| `_fbc` | first-party cookie | 90 days | Meta's click cookie, written when the page URL has an `fbclid`, the same way Meta's pixel does |
| `kerdly_uid` | `localStorage` | until cleared | Remembers the last `identify`, so it is not sent twice |
| `kerdly_ip6` | `sessionStorage` | the tab session | The result of the IPv6 lookup |

The SDK reads Meta's `_fbp` and TikTok's `_ttp` cookies but never writes them. Cookies are
`SameSite=Lax`, and `Secure` on https pages.

## Consent

Nothing is stored or sent before `createKerdly` runs (or the snippet loads). On a page that waits
for consent, load the snippet or call `createKerdly` after the visitor agrees.

To start fully passive and decide yourself when to send:

```ts
const kerdly = createKerdly({ key: "wk_live_…", autoVisit: false, autoDecorate: false, ipv6EchoUrl: null });
```

What the SDK sends with each visit or click: the page URL and title, the referrer, the visitor id,
the Meta and TikTok cookies above, and the visitor's public IPv6 address when available.

## Troubleshooting

- Warnings in the browser console start with `[Kerdly]`.
- The visitor id changes on every page load: the cookie named in `visitorCookie` is `HttpOnly`, or
  the browser refused `cookieDomain`. Use the default cookie or fix the domain.
- Questions or problems: [open an issue](https://github.com/Kerdly/kerdly-sdk/issues) or contact
  Kerdly support. Never post your keys.
