import { vi, type Mock } from "vitest";
import type { KerdlyTouch } from "../src/types.js";

type Beacon = (url: string, data?: BodyInit | null) => boolean;

/** Every cookie the page can see, expired on the host and on its parent domains. */
export function clearCookies(): void {
  const labels = location.hostname.split(".");
  const domains: (string | undefined)[] = [undefined];
  for (let i = 0; i < labels.length - 1; i++) domains.push("." + labels.slice(i).join("."));
  for (const part of document.cookie.split(";")) {
    const name = part.split("=")[0]?.trim();
    if (!name) continue;
    for (const domain of domains) {
      document.cookie = `${name}=; Max-Age=0; Path=/${domain ? `; Domain=${domain}` : ""}`;
    }
  }
}

/** A clean page in a new tab session: no cookies, no web storage, no SDK state on window, the URL at `path`. */
export function resetPage(path = "/"): void {
  restoreCookieAccessor();
  clearCookies();
  sessionStorage.clear();
  localStorage.clear();
  const holder = window as unknown as Record<string, unknown>;
  delete holder.__kerdlyVisits;
  delete holder.__kerdlyIp6;
  delete holder.__kerdlyUid;
  delete holder.kerdly;
  history.replaceState(null, "", path);
  document.title = "";
  delete (document as unknown as Record<string, unknown>).referrer;
}

export function setReferrer(value: string): void {
  Object.defineProperty(document, "referrer", { value, configurable: true });
}

/** Install `navigator.sendBeacon` (jsdom has none) answering `result`. */
export function stubBeacon(result: boolean | (() => boolean) = true): Mock<Beacon> {
  const beacon = vi.fn<Beacon>(() => (typeof result === "function" ? result() : result));
  Object.defineProperty(navigator, "sendBeacon", { value: beacon, configurable: true, writable: true });
  return beacon;
}

export function removeBeacon(): void {
  delete (navigator as unknown as Record<string, unknown>).sendBeacon;
}

export async function blobText(data: unknown): Promise<string> {
  if (!(data instanceof Blob)) throw new Error("the beacon was not sent a Blob");
  return data.text();
}

/** The touches handed to a beacon mock, parsed. */
export async function beaconTouches(beacon: Mock<Beacon>): Promise<KerdlyTouch[]> {
  return Promise.all(beacon.mock.calls.map(async ([, data]) => JSON.parse(await blobText(data)) as KerdlyTouch));
}

function realCookieAccessor(): { get: () => string; set: (value: string) => void } {
  const descriptor = Object.getOwnPropertyDescriptor(Document.prototype, "cookie");
  if (!descriptor?.get || !descriptor.set) throw new Error("no document.cookie accessor");
  const { get, set } = descriptor;
  return { get: () => get.call(document) as string, set: (value) => set.call(document, value) };
}

/** Replace `document.cookie` on this document until `restoreCookieAccessor`. */
function overrideCookieAccessor(get: () => string, set: (value: string) => void): void {
  Object.defineProperty(document, "cookie", { configurable: true, get, set });
}

export function restoreCookieAccessor(): void {
  delete (document as unknown as Record<string, unknown>).cookie;
}

/** Record `document.cookie` assignments while still applying them. */
export function recordCookieWrites(): string[] {
  const writes: string[] = [];
  const real = realCookieAccessor();
  overrideCookieAccessor(real.get, (value) => {
    writes.push(value);
    real.set(value);
  });
  return writes;
}

/** A browser that refuses to store any cookie (blocked, or a sandboxed frame). */
export function blockCookies(): void {
  overrideCookieAccessor(
    () => "",
    () => undefined,
  );
}
