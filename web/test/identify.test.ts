import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { createKerdly, type KerdlyIdentify } from "../src/index.js";
import { blobText, clearCookies, removeBeacon, resetPage, stubBeacon } from "./helpers.js";

/** The golden identify every SDK that sends one builds (spec/fixtures). */
const FIXTURE = JSON.parse(
  readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), "../../spec/fixtures/web-identify.request.json"), "utf8"),
) as KerdlyIdentify;

const KEY = "wk_live_example";
const ENDPOINT = "https://go.acme-app.com";
const IDENTIFY_URL = "https://go.acme-app.com/v1/web/identify";
const UID = "Xq9vK2mT4bR7nP1sL8wZ3cY6hJ5d";
const OTHER_UID = "Hk3pW8sN2vB6xD9qF1zM4tR7yC5g";

/** An instance that sends nothing on its own, so the transport sees identify calls only. */
function quiet(extra: Record<string, unknown> = {}) {
  return createKerdly({ key: KEY, endpoint: ENDPOINT, autoVisit: false, autoDecorate: false, ipv6EchoUrl: null, ...extra });
}

/** The next page load in the same browser: the cookies and localStorage stay, the page's state goes. */
function nextPageLoad(): void {
  const holder = window as unknown as Record<string, unknown>;
  delete holder.__kerdlyUid;
  delete holder.__kerdlyVisits;
}

function stubFetch() {
  const fetchMock = vi.fn((_url: string, _init?: RequestInit) => Promise.resolve(new Response(null, { status: 204 })));
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

async function identifies(beacon: ReturnType<typeof stubBeacon>): Promise<KerdlyIdentify[]> {
  return Promise.all(beacon.mock.calls.map(async ([, data]) => JSON.parse(await blobText(data)) as KerdlyIdentify));
}

beforeEach(() => {
  resetPage();
  removeBeacon();
});

describe("identify", () => {
  it("builds the fixture's request: key, visitor id and user id, to /v1/web/identify", async () => {
    document.cookie = `afr_vid=${FIXTURE.visitor_id}; Path=/`;
    const beacon = stubBeacon();
    expect(quiet({ key: FIXTURE.key }).identify(FIXTURE.user_id)).toBe(true);
    expect(beacon).toHaveBeenCalledOnce();
    const [url, data] = beacon.mock.calls[0] ?? [];
    expect(url).toBe(IDENTIFY_URL);
    expect((data as Blob).type).toBe("text/plain;charset=utf-8");
    const [body] = await identifies(beacon);
    expect(Object.keys(body ?? {})).toEqual(Object.keys(FIXTURE));
    expect(body).toEqual(FIXTURE);
  });

  it("is the visitor the touches carry, and appends to an endpoint with a path", async () => {
    const beacon = stubBeacon();
    const kerdly = createKerdly({
      key: KEY,
      endpoint: "https://app.kerdly.com/api/",
      autoDecorate: false,
      ipv6EchoUrl: null,
    });
    kerdly.identify(UID);
    expect(beacon.mock.calls.map(([url]) => url)).toEqual([
      "https://app.kerdly.com/api/v1/web/touch",
      "https://app.kerdly.com/api/v1/web/identify",
    ]);
    const [visit, identify] = await identifies(beacon);
    expect(identify).toEqual({ key: KEY, visitor_id: kerdly.visitorId(), user_id: UID });
    expect(identify?.visitor_id).toBe(visit?.visitor_id);
  });

  it("sends the key only in the body", () => {
    const beacon = stubBeacon();
    quiet({ key: "wk_live_secretish" }).identify(UID);
    expect(beacon.mock.calls[0]?.[0]).not.toContain("wk_live");
  });

  it("falls back to a keepalive no-cors fetch when sendBeacon refuses, or is missing", () => {
    stubBeacon(false);
    const fetchMock = stubFetch();
    const kerdly = quiet();
    expect(kerdly.identify(UID)).toBe(true);
    expect(fetchMock).toHaveBeenCalledWith(IDENTIFY_URL, {
      method: "POST",
      body: JSON.stringify({ key: KEY, visitor_id: kerdly.visitorId(), user_id: UID }),
      keepalive: true,
      headers: { "Content-Type": "text/plain;charset=UTF-8" },
      mode: "no-cors",
    });

    removeBeacon();
    expect(kerdly.identify(OTHER_UID)).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(fetchMock.mock.calls[1]?.[0]).toBe(IDENTIFY_URL);
  });

  it("remembers nothing when no transport took the request, so the next call tries again", () => {
    vi.stubGlobal("fetch", undefined);
    const kerdly = quiet();
    expect(kerdly.identify(UID)).toBe(false);
    expect(localStorage.getItem("afr_uid")).toBeNull();
    const beacon = stubBeacon();
    expect(kerdly.identify(UID)).toBe(true);
    expect(beacon).toHaveBeenCalledOnce();
  });
});

describe("identify dedupe", () => {
  it("sends a pair once per page, across instances", () => {
    const beacon = stubBeacon();
    const kerdly = quiet();
    expect(kerdly.identify(UID)).toBe(true);
    expect(kerdly.identify(UID)).toBe(false);
    expect(quiet().identify(UID)).toBe(false);
    expect(beacon).toHaveBeenCalledOnce();
  });

  it("keeps the last pair in localStorage as afr_uid, so later page loads do not resend it", () => {
    const beacon = stubBeacon();
    const kerdly = quiet();
    kerdly.identify(UID);
    expect(JSON.parse(localStorage.getItem("afr_uid") ?? "null")).toEqual([KEY, kerdly.visitorId(), UID]);
    nextPageLoad();
    expect(quiet().identify(UID)).toBe(false);
    expect(beacon).toHaveBeenCalledOnce();
  });

  it("sends a different user id, and the first one again after it (the last pair only)", async () => {
    const beacon = stubBeacon();
    const kerdly = quiet();
    expect(kerdly.identify(UID)).toBe(true);
    expect(kerdly.identify(OTHER_UID)).toBe(true);
    expect(kerdly.identify(OTHER_UID)).toBe(false);
    nextPageLoad();
    expect(quiet().identify(UID)).toBe(true);
    expect((await identifies(beacon)).map((body) => body.user_id)).toEqual([UID, OTHER_UID, UID]);
  });

  it("sends again for a new visitor id, or another key", async () => {
    const beacon = stubBeacon();
    const first = quiet().identify(UID);
    clearCookies();
    nextPageLoad();
    const newVisitor = quiet();
    expect([first, newVisitor.identify(UID)]).toEqual([true, true]);
    expect(quiet({ key: "wk_live_other" }).identify(UID)).toBe(true);
    const bodies = await identifies(beacon);
    expect(bodies[0]?.visitor_id).not.toBe(bodies[1]?.visitor_id);
    expect(bodies.map((body) => body.key)).toEqual([KEY, KEY, "wk_live_other"]);
  });
});

describe("identify no-ops", () => {
  it("refuses a user id that is not a non-empty string of at most 128 characters, and warns", () => {
    const beacon = stubBeacon();
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const kerdly = quiet();
    const invalid: unknown[] = ["", "x".repeat(129), undefined, null, 12345, { uid: UID }];
    for (const value of invalid) expect(kerdly.identify(value as string)).toBe(false);
    expect(beacon).not.toHaveBeenCalled();
    expect(warn).toHaveBeenCalledTimes(invalid.length);
    expect(warn.mock.calls[0]?.[0]).toMatch(/^\[Kerdly\] identify: the user id must be/);
    expect(localStorage.getItem("afr_uid")).toBeNull();
    expect(kerdly.identify("x".repeat(128))).toBe(true);
  });

  it("sends nothing without a key or with a secret key", () => {
    const beacon = stubBeacon();
    const fetchMock = stubFetch();
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    for (const options of [
      { key: "", endpoint: ENDPOINT },
      { key: "sk_live_oops", endpoint: ENDPOINT },
    ]) {
      expect(quiet(options).identify(UID)).toBe(false);
    }
    expect(beacon).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
    expect(localStorage.getItem("afr_uid")).toBeNull();
    // The instance's own warning, once per instance.
    expect(warn.mock.calls.map(([message]) => String(message))).toEqual([
      "[Kerdly] a key is required; nothing is sent",
      "[Kerdly] secret sk_ keys never go in a page; use the project's wk_ key",
    ]);
  });
});

describe("identify without localStorage", () => {
  it("still sends, and dedupes within the page, when localStorage itself throws", () => {
    vi.spyOn(globalThis, "localStorage", "get").mockImplementation(() => {
      throw new DOMException("The operation is insecure.", "SecurityError");
    });
    const beacon = stubBeacon();
    const kerdly = quiet();
    expect(() => kerdly.identify(UID)).not.toThrow();
    expect(beacon).toHaveBeenCalledOnce();
    expect(kerdly.identify(UID)).toBe(false);
    expect(kerdly.identify(OTHER_UID)).toBe(true);
    expect(beacon).toHaveBeenCalledTimes(2);
    nextPageLoad();
    expect(quiet().identify(OTHER_UID)).toBe(true);
  });

  it("still sends, and dedupes within the page, when reads and writes throw", () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new DOMException("denied", "SecurityError");
    });
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new DOMException("quota", "QuotaExceededError");
    });
    expect(() => localStorage.getItem("afr_uid")).toThrow();
    const beacon = stubBeacon();
    const kerdly = quiet();
    expect(kerdly.identify(UID)).toBe(true);
    expect(kerdly.identify(UID)).toBe(false);
    expect(beacon).toHaveBeenCalledOnce();
  });

  it("dedupes within the page when only writes throw (storage reads back nothing)", () => {
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new DOMException("quota", "QuotaExceededError");
    });
    const beacon = stubBeacon();
    const kerdly = quiet();
    expect(kerdly.identify(UID)).toBe(true);
    expect(localStorage.getItem("afr_uid")).toBeNull();
    expect(kerdly.identify(UID)).toBe(false);
    expect(beacon).toHaveBeenCalledOnce();
  });

  it("follows localStorage over the page's record when another tab identified someone else", () => {
    const beacon = stubBeacon();
    const kerdly = quiet();
    kerdly.identify(UID);
    // Another tab of the same visitor signed in as OTHER_UID.
    localStorage.setItem("afr_uid", JSON.stringify([KEY, kerdly.visitorId(), OTHER_UID]));
    expect(kerdly.identify(UID)).toBe(true);
    expect(beacon).toHaveBeenCalledTimes(2);
  });
});
