/**
 * `createKerdly`: the web SDK. Nothing here runs at import; the browser is touched
 * only inside `createKerdly` and the instance's methods, so the module is safe to import during SSR.
 */

import { FBC_COOKIE, FBC_MAX_AGE_SECONDS, FBP_COOKIE, TTP_COOKIE, fbcClickId, mintFbc, validFbCookie, validTtp } from "./adCookies.js";
import { readCookie, registrableDomain, writeCookie } from "./cookies.js";
import { newVisitorId, uuidv4 } from "./ids.js";
import { DEFAULT_IPV6_ECHO_URL, publicIpv6 } from "./ipv6.js";
import { IDENTIFY_PATH, TOUCH_PATH, endpointUrl, post } from "./transport.js";
import type { Kerdly, KerdlyIdentify, KerdlyOptions, KerdlyTouch, KerdlyTouchCookies, KerdlyTouchKind, KerdlyVisitOptions } from "./types.js";
import { VISIT_PARAM, decorateUrl, queryParam, withQueryParam } from "./url.js";

export const DEFAULT_VISITOR_COOKIE = "afr_vid";
export const DEFAULT_LINK_SELECTOR = "a[data-kerdly-link]";
/** 400 days, the longest lifetime browsers keep a cookie for. */
export const VISITOR_MAX_AGE_SECONDS = 400 * 24 * 60 * 60;

/**
 * The URL of the last visit sent per key, on `window` rather than in module scope so that two copies
 * of the SDK on one page (the snippet and a bundle, or a re-created instance) share it.
 */
const VISITS_GLOBAL = "__kerdlyVisits";

/** The `localStorage` key of the last identify sent: `JSON.stringify([key, visitor_id, user_id])`. */
export const IDENTIFY_STORAGE_KEY = "afr_uid";
/** The same record on `window`, the dedupe of a page whose `localStorage` cannot be read or written. */
const IDENTIFY_GLOBAL = "__kerdlyUid";
export const MAX_USER_ID_LENGTH = 128;

function warn(message: string): void {
  try {
    if (typeof console !== "undefined") console.warn(`[Kerdly] ${message}`);
  } catch {
    // Logging must never break a page either.
  }
}

/** The anchors to decorate, from the `autoDecorate` option. */
function linkSelector(option: string | boolean | undefined): string | null {
  if (option === false) return null;
  return typeof option === "string" && option.trim() ? option.trim() : DEFAULT_LINK_SELECTOR;
}

/** The Kerdly collector, used when `endpoint` is not given. */
export const DEFAULT_ENDPOINT = "https://app.kerdly.com/api";

export function createKerdly(options: KerdlyOptions): Kerdly {
  const opts: Partial<KerdlyOptions> = options || {};
  const key = String(opts.key || "").trim();
  const endpoint = String(opts.endpoint || "").trim() || DEFAULT_ENDPOINT;
  const cookieName = String(opts.visitorCookie || "").trim() || DEFAULT_VISITOR_COOKIE;
  const browser = typeof window !== "undefined" && typeof document !== "undefined";
  // A secret key in a page is a leak: refuse to send it rather than let it work.
  const sendable = Boolean(key && endpoint) && !/^sk_/.test(key);
  const echoOption = opts.ipv6EchoUrl === undefined ? DEFAULT_IPV6_ECHO_URL : opts.ipv6EchoUrl;
  const echoUrl = echoOption === null ? null : String(echoOption).trim();
  let visitor = "";
  let mintedFbc: string | undefined;
  /** The public IPv6 once the tab session's lookup has one. */
  let ipv6 = "";

  function cookieDomain(): string | undefined {
    return String(opts.cookieDomain || "").trim() || registrableDomain(location.hostname);
  }

  function setCookie(name: string, value: string, maxAgeSeconds: number): boolean {
    return writeCookie(name, value, maxAgeSeconds, cookieDomain(), location.protocol === "https:");
  }

  function visitorId(): string {
    if (visitor || !browser) return visitor;
    try {
      visitor = readCookie(document.cookie, cookieName) || "";
      if (!visitor) {
        visitor = newVisitorId();
        // When the cookie cannot be stored the id still holds for this page.
        if (!setCookie(cookieName, visitor, VISITOR_MAX_AGE_SECONDS)) {
          warn(`cannot store the ${cookieName} cookie (blocked, or HttpOnly); the visitor id lasts for this page only`);
        }
      }
    } catch {
      if (!visitor) visitor = newVisitorId();
    }
    return visitor;
  }

  /**
   * The ad cookies for a touch. When the page URL carries an `fbclid` that the `_fbc` cookie does
   * not hold yet, `_fbc` is minted (`fb.1.<now>.<fbclid>`) and stored for 90 days, as Meta's pixel
   * does: a new click replaces an older one's `_fbc`.
   */
  function adCookies(nowMs: number): KerdlyTouchCookies {
    let fbc = validFbCookie(readCookie(document.cookie, FBC_COOKIE));
    const fbclid = queryParam(location.search, "fbclid");
    if (fbclid && fbcClickId(fbc) !== fbclid) {
      if (!mintedFbc || fbcClickId(mintedFbc) !== fbclid) {
        mintedFbc = mintFbc(fbclid, nowMs);
        if (mintedFbc) setCookie(FBC_COOKIE, mintedFbc, FBC_MAX_AGE_SECONDS);
      }
      if (mintedFbc) fbc = mintedFbc;
    }
    const jar = document.cookie;
    return {
      fbp: validFbCookie(readCookie(jar, FBP_COOKIE)),
      fbc,
      ttp: validTtp(readCookie(jar, TTP_COOKIE)),
    };
  }

  function touch(kind: KerdlyTouchKind, link: string | null): boolean {
    if (!browser || !sendable) return false;
    try {
      const now = Date.now();
      const payload: KerdlyTouch = {
        key,
        event_id: uuidv4(),
        kind,
        visitor_id: visitorId(),
        url: location.href,
        referrer: document.referrer || null,
        title: document.title || null,
        chain_from: queryParam(location.search, VISIT_PARAM),
        link,
        cookies: adCookies(now),
        ...(ipv6 ? { ipv6 } : {}),
        ts: now,
      };
      return post(endpointUrl(endpoint, TOUCH_PATH), JSON.stringify(payload)) !== "none";
    } catch {
      return false;
    }
  }

  function visit(visitOptions?: KerdlyVisitOptions): boolean {
    try {
      if (!browser || !sendable) return false;
      const holder = window as unknown as Record<string, Record<string, string> | undefined>;
      const visits = holder[VISITS_GLOBAL] || (holder[VISITS_GLOBAL] = {});
      const href = location.href;
      if (!(visitOptions && visitOptions.force) && visits[key] === href) return false;
      const sent = touch("visit", null);
      if (sent) visits[key] = href;
      return sent;
    } catch {
      return false;
    }
  }

  function decorate(url: string): string {
    try {
      return decorateUrl(url, visitorId());
    } catch {
      return url;
    }
  }

  function click(url: string): string {
    if (!url) return url;
    touch("click", url);
    return decorate(url);
  }

  function eventId(name: string): string {
    try {
      return `${visitorId()}:${name}`;
    } catch {
      return `:${name}`;
    }
  }

  function identify(userId: string): boolean {
    try {
      if (!browser || !sendable) return false;
      if (typeof userId !== "string" || !userId || userId.length > MAX_USER_ID_LENGTH) {
        warn(`identify: the user id must be a non-empty string of at most ${MAX_USER_ID_LENGTH} characters`);
        return false;
      }
      const body: KerdlyIdentify = { key, visitor_id: visitorId(), user_id: userId };
      const record = JSON.stringify([key, body.visitor_id, userId]);
      const holder = window as unknown as Record<string, string | undefined>;
      let stored: string | null = null;
      try {
        stored = localStorage.getItem(IDENTIFY_STORAGE_KEY);
      } catch {
        // Blocked storage (a sandboxed frame, disabled site data): dedupe within this page only.
      }
      // Storage is the record across tabs and page loads; the page's own record covers a browser
      // that reads storage but refuses writes.
      if ((stored !== null ? stored : holder[IDENTIFY_GLOBAL]) === record) return false;
      if (post(endpointUrl(endpoint, IDENTIFY_PATH), JSON.stringify(body)) === "none") return false;
      holder[IDENTIFY_GLOBAL] = record;
      try {
        localStorage.setItem(IDENTIFY_STORAGE_KEY, record);
      } catch {
        // The next page load sends the pair again.
      }
      return true;
    } catch {
      return false;
    }
  }

  const kerdly: Kerdly = { visitorId, visit, click, decorate, eventId, identify };
  if (!browser) return kerdly;

  try {
    if (!sendable) {
      warn(/^sk_/.test(key) ? "secret sk_ keys never go in a page; use the project's wk_ key" : "a key is required; nothing is sent");
    } else if (echoUrl !== null) {
      // Before the automatic visit, so that a tab session's known address goes with it.
      if (!/^https:\/\/./i.test(echoUrl)) {
        warn("ipv6EchoUrl must be an https URL; the IPv6 lookup is off");
      } else {
        const known = publicIpv6(echoUrl);
        if (typeof known === "string") {
          ipv6 = known;
        } else {
          known.then((ip) => {
            ipv6 = ip;
          });
        }
      }
    }

    let selector = linkSelector(opts.autoDecorate);
    if (selector) {
      try {
        document.querySelector(selector);
      } catch {
        warn(`autoDecorate: invalid selector ${JSON.stringify(selector)}`);
        selector = null;
      }
    }
    if (selector) {
      const links = selector;
      // Capture phase, so a page handler that stops propagation cannot hide the click. The href is
      // decorated in place and the browser navigates as it would anyway: modifier keys, middle
      // clicks and target=_blank keep working, and nothing calls preventDefault.
      const onClick = (event: MouseEvent): void => {
        try {
          if (event.defaultPrevented || event.button !== (event.type === "auxclick" ? 1 : 0)) return;
          let node = event.target as Node | null;
          if (node && node.nodeType !== 1) node = node.parentNode;
          const anchor = node && typeof (node as Element).closest === "function" ? (node as Element).closest(links) : null;
          const href = anchor ? (anchor as HTMLAnchorElement).href : null;
          if (typeof href !== "string" || !/^https?:/i.test(href)) return;
          // The link as authored: an href decorated by an earlier click is reported without afr_v.
          const decorated = click(withQueryParam(href, VISIT_PARAM, null));
          if (decorated !== href) (anchor as HTMLAnchorElement).href = decorated;
        } catch {
          // Never block a navigation.
        }
      };
      document.addEventListener("click", onClick, true);
      document.addEventListener("auxclick", onClick, true);
    }

    if (opts.autoVisit !== false) {
      // A prerendered page is not a visit until it is shown.
      if ((document as Document & { prerendering?: boolean }).prerendering) {
        document.addEventListener("prerenderingchange", () => visit(), { once: true });
      } else {
        visit();
      }
    }
  } catch {
    // The instance keeps working without the automatic parts.
  }
  return kerdly;
}
