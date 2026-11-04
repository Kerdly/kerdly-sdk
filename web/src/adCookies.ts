/**
 * The ad networks' first-party cookies a touch carries: Meta's `_fbp` and `_fbc`, TikTok's `_ttp`,
 * in the formats the networks' own pixels write.
 */

export const FBP_COOKIE = "_fbp";
export const FBC_COOKIE = "_fbc";
export const TTP_COOKIE = "_ttp";

/** 90 days: the lifetime Meta's pixel gives `_fbc`. */
export const FBC_MAX_AGE_SECONDS = 90 * 24 * 60 * 60;

/**
 * Meta's format, `fb.<subdomain index>.<creation ms>.<payload>`: the payload is the fbclid in
 * `_fbc` and a random number in `_fbp`. Values that are not cookies Meta wrote are not sent.
 */
const FB_COOKIE_VALUE = /^fb\.\d\.\d{10,20}\.[\w.-]{1,400}$/;

/** `_ttp` is an opaque id (27 characters today). */
const TTP_COOKIE_VALUE = /^[\w.|-]{8,128}$/;

export function validFbCookie(value: string | null | undefined): string | null {
  return value && FB_COOKIE_VALUE.test(value) ? value : null;
}

export function validTtp(value: string | null | undefined): string | null {
  return value && TTP_COOKIE_VALUE.test(value) ? value : null;
}

/**
 * `_fbc` for an ad click, as Meta's pixel builds it: `fb.1.<creation ms>.<fbclid>` (index 1 = the
 * registrable domain, where the SDK writes it). `undefined` for a missing or malformed fbclid.
 */
export function mintFbc(fbclid: string | null | undefined, nowMs: number): string | undefined {
  const clickId = fbclid ? fbclid.trim() : "";
  if (!clickId) return undefined;
  const fbc = `fb.1.${Math.floor(nowMs)}.${clickId}`;
  return FB_COOKIE_VALUE.test(fbc) ? fbc : undefined;
}

/** The fbclid inside an `_fbc` value: everything after `fb.<i>.<ms>.`, dots included. */
export function fbcClickId(fbc: string | null | undefined): string | undefined {
  if (!fbc) return undefined;
  const parts = fbc.split(".");
  return parts.length >= 4 ? parts.slice(3).join(".") : undefined;
}
