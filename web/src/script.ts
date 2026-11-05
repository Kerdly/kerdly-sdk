/**
 * The `kerdly.js` snippet's configuration, read from its own `<script>` tag:
 *
 *   <script src="https://cdn.kerdly.com/v1/kerdly.js" data-key="wk_live_…" async></script>
 *
 * `data-key` (required), `data-endpoint` (default: the Kerdly collector when the script comes from
 * a CDN, else the URL it was loaded from without `/kerdly.js`), `data-cookie-domain`,
 * `data-visitor-cookie`, `data-auto-decorate` (a selector, or `false` to turn it off),
 * `data-ipv6-echo-url` (empty to turn the IPv6 lookup off).
 */

import { DEFAULT_ENDPOINT } from "./client.js";
import type { KerdlyOptions } from "./types.js";

/** Hosts that serve the snippet but not the collector: the Kerdly CDN and the public npm CDNs. */
export const CDN_HOSTS = ["cdn.kerdly.com", "cdn.jsdelivr.net", "unpkg.com"];

/**
 * The endpoint for a script's `src`: the Kerdly collector for a CDN, else the directory the
 * script was served from (`https://go.example.com/kerdly.js` → `https://go.example.com`).
 */
export function endpointFromSrc(src: string | null | undefined): string {
  if (!src) return "";
  try {
    const url = new URL(".", src);
    if (CDN_HOSTS.indexOf(url.hostname) !== -1) return DEFAULT_ENDPOINT;
    return url.href.replace(/\/+$/, "");
  } catch {
    return "";
  }
}

/** `data-auto-decorate`: absent, empty or `true` → the default selector; `false`/`off`/`no`/`0` → off; anything else is the selector. */
export function autoDecorateFrom(value: string | null): string | boolean {
  const v = (value || "").trim();
  if (/^(false|off|no|0)$/i.test(v)) return false;
  return v && !/^(true|on|yes|1)$/i.test(v) ? v : true;
}

/** `data-ipv6-echo-url`: absent → the default echo URL; empty → off; anything else is the URL. */
export function ipv6EchoUrlFrom(value: string | null): string | null | undefined {
  if (value === null) return undefined;
  return value.trim() || null;
}

export function optionsFromScript(script: HTMLScriptElement | null): KerdlyOptions {
  const attr = (name: string): string => ((script && script.getAttribute(name)) || "").trim();
  return {
    key: attr("data-key"),
    endpoint: attr("data-endpoint") || endpointFromSrc(script && script.src),
    cookieDomain: attr("data-cookie-domain") || undefined,
    visitorCookie: attr("data-visitor-cookie") || undefined,
    autoVisit: true,
    autoDecorate: autoDecorateFrom(script && script.getAttribute("data-auto-decorate")),
    ipv6EchoUrl: ipv6EchoUrlFrom(script && script.getAttribute("data-ipv6-echo-url")),
  };
}

/**
 * The snippet's own tag: `document.currentScript` while it runs, else the first `kerdly.js` script
 * that carries a key (a loader that executes it some other way).
 */
export function findSnippetScript(): HTMLScriptElement | null {
  const current = document.currentScript;
  if (current && current.tagName === "SCRIPT") return current as HTMLScriptElement;
  return document.querySelector<HTMLScriptElement>('script[data-key][src*="kerdly"]');
}
