import { beforeEach, describe, expect, it, vi } from "vitest";
import { createKerdly } from "../src/index.js";
import { readCookie } from "../src/cookies.js";
import { beaconTouches, blockCookies, recordCookieWrites, resetPage, stubBeacon } from "./helpers.js";

const KEY = "wk_live_example";
const ENDPOINT = "https://go.acme-app.com";
const GUEST_ID = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";

/** An instance that sends nothing on its own. */
function quiet(extra: Record<string, unknown> = {}) {
  return createKerdly({ key: KEY, endpoint: ENDPOINT, autoVisit: false, autoDecorate: false, ...extra });
}

beforeEach(() => resetPage());

describe("visitor id", () => {
  it("mints a 22-character base32 id and stores it in kerdly_vid for 400 days on the registrable domain", () => {
    const writes = recordCookieWrites();
    const id = quiet().visitorId();
    expect(id).toMatch(/^[0-9abcdefghjkmnpqrstvwxyz]{22}$/);
    expect(writes).toEqual([`kerdly_vid=${id}; Max-Age=34560000; Path=/; Domain=.acme-app.com; SameSite=Lax; Secure`]);
    expect(readCookie(document.cookie, "kerdly_vid")).toBe(id);
  });

  it("reuses the cookie on the next page load and never rewrites it", () => {
    document.cookie = "kerdly_vid=q3k9m2x7a8b4c5d6e7f8g9; Path=/";
    const writes = recordCookieWrites();
    expect(quiet().visitorId()).toBe("q3k9m2x7a8b4c5d6e7f8g9");
    expect(writes).toEqual([]);
  });

  it("adopts a visitor id from the afr_vid cookie of builds before 0.1.0, and clears that cookie", () => {
    document.cookie = "afr_vid=q3k9m2x7a8b4c5d6e7f8g9; Path=/";
    const writes = recordCookieWrites();
    expect(quiet().visitorId()).toBe("q3k9m2x7a8b4c5d6e7f8g9");
    expect(writes[0]).toBe("kerdly_vid=q3k9m2x7a8b4c5d6e7f8g9; Max-Age=34560000; Path=/; Domain=.acme-app.com; SameSite=Lax; Secure");
    expect(readCookie(document.cookie, "kerdly_vid")).toBe("q3k9m2x7a8b4c5d6e7f8g9");
    expect(readCookie(document.cookie, "afr_vid")).toBeUndefined();
    expect(quiet().visitorId()).toBe("q3k9m2x7a8b4c5d6e7f8g9");
  });

  it("prefers kerdly_vid over an afr_vid cookie left behind", () => {
    document.cookie = "afr_vid=oldoldoldoldoldoldold0; Path=/";
    document.cookie = "kerdly_vid=q3k9m2x7a8b4c5d6e7f8g9; Path=/";
    const writes = recordCookieWrites();
    expect(quiet().visitorId()).toBe("q3k9m2x7a8b4c5d6e7f8g9");
    expect(writes).toEqual([]);
  });

  it("never reads afr_vid when visitorCookie names another cookie", () => {
    document.cookie = "afr_vid=q3k9m2x7a8b4c5d6e7f8g9; Path=/";
    const id = quiet({ visitorCookie: "my_vid" }).visitorId();
    expect(id).not.toBe("q3k9m2x7a8b4c5d6e7f8g9");
    expect(readCookie(document.cookie, "afr_vid")).toBe("q3k9m2x7a8b4c5d6e7f8g9");
  });

  it("is one id per page across instances", () => {
    const first = quiet().visitorId();
    expect(quiet().visitorId()).toBe(first);
  });

  it("reuses an existing id cookie named by visitorCookie as it is", () => {
    document.cookie = `__guest_id=${GUEST_ID}; Path=/`;
    const writes = recordCookieWrites();
    const kerdly = quiet({ visitorCookie: "__guest_id" });
    expect(kerdly.visitorId()).toBe(GUEST_ID);
    expect(kerdly.eventId("StartTrial")).toBe(`${GUEST_ID}:StartTrial`);
    expect(kerdly.decorate("https://go.acme-app.com/k3f9q2x")).toBe(`https://go.acme-app.com/k3f9q2x?kerdly_v=${GUEST_ID}`);
    expect(writes).toEqual([]);
    expect(readCookie(document.cookie, "kerdly_vid")).toBeUndefined();
  });

  it("mints into the named cookie when it does not exist yet", () => {
    const writes = recordCookieWrites();
    const id = quiet({ visitorCookie: "my_vid" }).visitorId();
    expect(writes).toEqual([`my_vid=${id}; Max-Age=34560000; Path=/; Domain=.acme-app.com; SameSite=Lax; Secure`]);
    expect(readCookie(document.cookie, "kerdly_vid")).toBeUndefined();
  });

  it("writes on cookieDomain when it is given", () => {
    const writes = recordCookieWrites();
    const id = quiet({ cookieDomain: "acme-app.com" }).visitorId();
    expect(writes).toEqual([`kerdly_vid=${id}; Max-Age=34560000; Path=/; Domain=acme-app.com; SameSite=Lax; Secure`]);
  });

  it("falls back to a host-only cookie when the browser refuses cookieDomain", () => {
    const writes = recordCookieWrites();
    const id = quiet({ cookieDomain: ".example.com" }).visitorId();
    expect(writes).toEqual([
      `kerdly_vid=${id}; Max-Age=34560000; Path=/; Domain=.example.com; SameSite=Lax; Secure`,
      `kerdly_vid=${id}; Max-Age=34560000; Path=/; SameSite=Lax; Secure`,
    ]);
    expect(readCookie(document.cookie, "kerdly_vid")).toBe(id);
  });

  it("keeps one id for the page when cookies are blocked, and says so once", () => {
    blockCookies();
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const kerdly = quiet();
    const id = kerdly.visitorId();
    expect(id).toMatch(/^[0-9a-z]{22}$/);
    expect(kerdly.visitorId()).toBe(id);
    expect(kerdly.eventId("Lead")).toBe(`${id}:Lead`);
    expect(warn).toHaveBeenCalledOnce();
    expect(warn.mock.calls[0]?.[0]).toMatch(/^\[Kerdly\] cannot store the kerdly_vid cookie/);
  });

  it("writes no cookie until something needs the id", () => {
    const writes = recordCookieWrites();
    const kerdly = quiet();
    expect(writes).toEqual([]);
    kerdly.eventId("Lead");
    expect(writes).toHaveLength(1);
  });

  it("is the visitor_id every touch carries", async () => {
    const beacon = stubBeacon();
    const kerdly = createKerdly({ key: KEY, endpoint: ENDPOINT, autoDecorate: false });
    kerdly.click("https://go.acme-app.com/k3f9q2x");
    const touches = await beaconTouches(beacon);
    expect(touches.map((t) => t.visitor_id)).toEqual([kerdly.visitorId(), kerdly.visitorId()]);
  });
});
