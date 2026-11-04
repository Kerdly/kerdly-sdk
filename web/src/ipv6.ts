/**
 * The browser's public IPv6. The collector answers over IPv4 only, so the SDK
 * asks an IPv6-only echo host for the address, once per tab session, and touches carry it. Nothing
 * here throws, and nothing waits for the lookup.
 */

export const DEFAULT_IPV6_ECHO_URL = "https://api6.ipify.org?format=json";
/** The `sessionStorage` key of the tab session's outcome: the address, or `""` when there is none. */
export const IPV6_STORAGE_KEY = "afr_ip6";
export const IPV6_TIMEOUT_MS = 3000;

/** The lookup of this page, on `window` so that every instance on the page shares one. */
const LOOKUP_GLOBAL = "__kerdlyIp6";

const HEXTET = /^[0-9a-f]{1,4}$/;

/**
 * `value` lowercased when it is a global unicast IPv6 address (2000::/3), else `null`: IPv4,
 * v4-mapped, loopback, link-local, ULA, multicast, zone ids, dotted tails and garbage are dropped.
 */
export function globalIpv6(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const ip = value.trim().toLowerCase();
  if (!/^[0-9a-f:]{2,39}$/.test(ip)) return null;
  const halves = ip.split("::");
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(":") : [];
  const tail = halves[1] ? halves[1].split(":") : [];
  const groups = head.length + tail.length;
  // Without `::` there are exactly 8 groups; `::` stands for at least one.
  if (halves.length === 1 ? groups !== 8 : groups > 7) return null;
  if (!head.concat(tail).every((group) => HEXTET.test(group))) return null;
  // An address that starts with `::` has a first group of 0.
  const first = head.length ? parseInt(head[0], 16) : 0;
  return first >= 0x2000 && first <= 0x3fff ? ip : null;
}

/** Fetch the echo URL's `{"ip": "…"}` with a timeout, and keep the outcome for the tab session. */
function lookup(echoUrl: string): Promise<string> {
  return new Promise((resolve) => {
    let done = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let controller: AbortController | null = null;
    const finish = (ip: string | null): void => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      const value = ip || "";
      try {
        sessionStorage.setItem(IPV6_STORAGE_KEY, value);
      } catch {
        // Without storage the next page load looks up again.
      }
      resolve(value);
    };
    try {
      if (typeof AbortController === "function") controller = new AbortController();
      timer = setTimeout(() => {
        if (controller) controller.abort();
        finish(null);
      }, IPV6_TIMEOUT_MS);
      fetch(echoUrl, { credentials: "omit", cache: "no-store", signal: controller ? controller.signal : undefined })
        .then((response) => (response.ok ? response.json() : null))
        .then(
          (body: { ip?: unknown } | null) => finish(globalIpv6(body && body.ip)),
          () => finish(null),
        );
    } catch {
      finish(null);
    }
  });
}

/**
 * The tab's public IPv6, or `""` for none: at once when this tab session already has an outcome,
 * else a promise of the lookup, which never rejects.
 */
export function publicIpv6(echoUrl: string): string | Promise<string> {
  try {
    const stored = sessionStorage.getItem(IPV6_STORAGE_KEY);
    if (stored !== null) return globalIpv6(stored) || "";
  } catch {
    // No storage (blocked, or a sandboxed frame): look up on every page load.
  }
  const holder = window as unknown as Record<string, Promise<string> | undefined>;
  return holder[LOOKUP_GLOBAL] || (holder[LOOKUP_GLOBAL] = lookup(echoUrl));
}
