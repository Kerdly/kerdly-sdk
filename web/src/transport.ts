/**
 * Delivery of one request to the collector, a touch or an identify:
 * `navigator.sendBeacon`, else `fetch` with `keepalive`. The body is JSON sent as `text/plain`, a
 * CORS-safelisted type, so neither needs a preflight. Fire and forget: the response (204) is never
 * read, and nothing here throws.
 */

export const TOUCH_PATH = "/v1/web/touch";
export const IDENTIFY_PATH = "/v1/web/identify";
export const BODY_CONTENT_TYPE = "text/plain;charset=UTF-8";

/** How a request left the page. */
export type Transport = "beacon" | "fetch" | "none";

/** `<endpoint><path>`, whatever trailing slashes the endpoint was configured with. */
export function endpointUrl(endpoint: string, path: string): string {
  return endpoint.replace(/\/+$/, "") + path;
}

export function post(url: string, body: string): Transport {
  try {
    if (typeof navigator !== "undefined" && typeof navigator.sendBeacon === "function") {
      // `false` means the browser would not queue it (quota); fall through to fetch.
      if (navigator.sendBeacon(url, new Blob([body], { type: BODY_CONTENT_TYPE }))) return "beacon";
    }
  } catch {
    // A throwing beacon (CSP, odd embedders) falls through to fetch.
  }
  try {
    if (typeof fetch === "function") {
      fetch(url, {
        method: "POST",
        body,
        keepalive: true,
        headers: { "Content-Type": BODY_CONTENT_TYPE },
        mode: "no-cors",
      }).catch(() => undefined);
      return "fetch";
    }
  } catch {
    // Nothing left to try.
  }
  return "none";
}
