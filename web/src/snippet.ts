/**
 * Entry of `dist/kerdly.js`, the drop-in snippet (an IIFE). It reads its configuration from its own
 * `<script>` tag, sends one `visit` touch for the page load, decorates `a[data-kerdly-link]` anchors,
 * and exposes the instance as `window.kerdly`. Loading it twice keeps the first instance.
 */

import { createKerdly } from "./client.js";
import { findSnippetScript, optionsFromScript } from "./script.js";
import type { Kerdly } from "./types.js";

declare global {
  interface Window {
    kerdly?: Kerdly;
  }
}

(function init(): void {
  try {
    if (typeof window === "undefined" || typeof document === "undefined") return;
    const existing = window.kerdly;
    if (existing && typeof existing.visitorId === "function") return;
    window.kerdly = createKerdly(optionsFromScript(findSnippetScript()));
  } catch {
    // A tracking snippet must never break the page that loads it.
  }
})();
