/**
 * The `kerdly.js` snippet's configuration, read from its own `<script>` tag:
 *
 *   <script src="https://go.example.com/kerdly.js" data-key="wk_live_…" async></script>
 *
 * `data-key` (required), `data-endpoint` (default: the URL the script was loaded from, without
 * `/kerdly.js`), `data-cookie-domain`, `data-visitor-cookie`, `data-auto-decorate` (a selector, or
 * `false` to turn it off), `data-ipv6-echo-url` (empty to turn the IPv6 lookup off).
 */

import type { KerdlyOptions } from "./types.js";

/** The directory a script was served from, as an endpoint: `https://go.example.com/kerdly.js` → `https://go.example.com`. */
export function endpointFromSrc(src: string | null | undefined): string {
  if (!src) return "";
  try {
    return new URL(".", src).href.replace(/\/+$/, "");
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
 * The snippet's own tag: `document.currentScript` while it runs, else the first `kerdly.js` (or legacy
 * `afr.js`) script that carries a key (a loader that executes it some other way).
 */
export function findSnippetScript(): HTMLScriptElement | null {
  const current = document.currentScript;
  if (current && current.tagName === "SCRIPT") return current as HTMLScriptElement;
  return document.querySelector<HTMLScriptElement>('script[data-key][src*="kerdly"], script[data-key][src*="afr"]');
}
