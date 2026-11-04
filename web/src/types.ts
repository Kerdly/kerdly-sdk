/**
 * Public types of the web SDK and the request bodies it sends (`KerdlyTouch`, `KerdlyIdentify`).
 */

/** Options for `createKerdly`. */
export interface KerdlyOptions {
  /** The project's public web key (`wk_live_…`). It travels in the request body, never in a header. */
  key: string;
  /**
   * Base URL of the project's link host or the collector, e.g. `https://go.example.com`.
   * `/v1/web/touch` and `/v1/web/identify` are appended. Default: `https://app.kerdly.com/api`.
   */
  endpoint?: string;
  /**
   * Domain of the cookies the SDK writes (the visitor cookie and a synthesized `_fbc`), e.g.
   * `.example.com`. Default: the page's registrable domain; host-only on `localhost` and IP hosts,
   * and whenever the browser refuses the domain.
   */
  cookieDomain?: string;
  /**
   * Name of the visitor id cookie. Default `afr_vid`. Name an existing first-party id cookie to
   * reuse its value as the visitor id; it must be readable by page script (not `HttpOnly`).
   */
  visitorCookie?: string;
  /** Send a `visit` touch from `createKerdly`. Default `true`. */
  autoVisit?: boolean;
  /**
   * Anchors to decorate with `afr_v` and count as clicks: a CSS selector, `true` for the default
   * `a[data-kerdly-link]`, or `false` to turn it off. Default `true`.
   */
  autoDecorate?: string | boolean;
  /**
   * An https URL that answers `{"ip": "…"}` over IPv6 only; the SDK asks it for the browser's public
   * IPv6 once per tab session and sends the address with every touch. Default
   * `https://api6.ipify.org?format=json`; `null` turns the lookup off.
   */
  ipv6EchoUrl?: string | null;
}

export interface KerdlyVisitOptions {
  /** Send even when this page already sent a visit for the current URL. */
  force?: boolean;
}

/** The instance `createKerdly` returns, and the snippet exposes as `window.kerdly`. No method throws. */
export interface Kerdly {
  /** The visitor id: the visitor cookie's value, minted and stored on first use. `""` off the browser. */
  visitorId(): string;
  /**
   * Send a `visit` touch. Once per page URL: a repeat call for the URL of the last visit sent from
   * this page is a no-op unless `force` is set. Returns whether a touch was handed to the browser.
   */
  visit(options?: KerdlyVisitOptions): boolean;
  /** Send a `click` touch with `link` = `url`, and return `url` decorated with `afr_v`. */
  click(url: string): string;
  /** Return `url` with `afr_v=<visitor id>` in its query; other parameters are kept as written. */
  decorate(url: string): string;
  /** `<visitor id>:<name>`, the event id shared by pixel and server events so they dedupe. */
  eventId(name: string): string;
  /**
   * Link this visitor to the site's own user id (for example your auth provider's uid), so events
   * your server reports under that user id are credited to this visitor's touches: sends
   * `POST <endpoint>/v1/web/identify`. A repeat of the last pair sent (kept in `localStorage` as
   * `afr_uid`) is a no-op, also on later page loads; a different user id sends again. `userId` must
   * be a non-empty string of at most 128 characters. Returns whether a request was handed to the
   * browser.
   */
  identify(userId: string): boolean;
}

export type KerdlyTouchKind = "visit" | "click";

/** First-party ad cookies read at the moment of the touch (`null` when absent or malformed). */
export interface KerdlyTouchCookies {
  /** Meta's browser id, `_fbp`. */
  fbp: string | null;
  /** Meta's click id cookie, `_fbc`, synthesized from `fbclid` when missing. */
  fbc: string | null;
  /** TikTok's browser id, `_ttp`. */
  ttp: string | null;
}

/** The body of `POST <endpoint>/v1/web/touch`. */
export interface KerdlyTouch {
  key: string;
  /** Lowercase UUIDv4, new for every touch; the server's dedupe key. */
  event_id: string;
  kind: KerdlyTouchKind;
  visitor_id: string;
  /** The page URL, query included. */
  url: string;
  referrer: string | null;
  title: string | null;
  /** The `afr_v` parameter of the page URL, when this page continues a chain. */
  chain_from: string | null;
  /** The URL the click goes to (`kind: "click"`); `null` for a visit. */
  link: string | null;
  cookies: KerdlyTouchCookies;
  /** The browser's public IPv6 (global unicast); absent until the tab session's lookup has one. */
  ipv6?: string;
  /** Browser clock, ms since the epoch. */
  ts: number;
}

/** The body of `POST <endpoint>/v1/web/identify`. */
export interface KerdlyIdentify {
  key: string;
  /** `visitorId()`, the visitor this links. */
  visitor_id: string;
  /** The site's own user id, 1–128 characters, as given. */
  user_id: string;
}
