import { beforeEach, describe, expect, it, vi } from "vitest";
import { fbcClickId, mintFbc, validFbCookie, validTtp } from "../src/adCookies.js";
import { readCookie } from "../src/cookies.js";
import { createKerdly } from "../src/index.js";
import { beaconTouches, recordCookieWrites, resetPage, stubBeacon } from "./helpers.js";

const NOW = 1_759_700_000_000;
const OPTIONS = { key: "wk_live_example", endpoint: "https://go.acme-app.com", autoDecorate: false } as const;

describe("mintFbc", () => {
  it("wraps the click id in Meta's format", () => {
    expect(mintFbc("IwAR2F4-dbP0l7Mn1IawQQ_GCINEz7", NOW)).toBe(`fb.1.${NOW}.IwAR2F4-dbP0l7Mn1IawQQ_GCINEz7`);
    expect(mintFbc(" IwAR0abc ", NOW)).toBe(`fb.1.${NOW}.IwAR0abc`);
  });

  it("refuses a missing or malformed click id", () => {
    expect(mintFbc(undefined, NOW)).toBeUndefined();
    expect(mintFbc("  ", NOW)).toBeUndefined();
    expect(mintFbc("bad id with spaces", NOW)).toBeUndefined();
    expect(mintFbc("x".repeat(401), NOW)).toBeUndefined();
  });
});

describe("fbcClickId", () => {
  it("reads the click id back, dots included", () => {
    expect(fbcClickId(`fb.1.${NOW}.Iw.AR2`)).toBe("Iw.AR2");
    expect(fbcClickId("fb.1")).toBeUndefined();
    expect(fbcClickId(null)).toBeUndefined();
  });
});

describe("cookie validation", () => {
  it("keeps Meta's and TikTok's formats and drops anything else", () => {
    expect(validFbCookie("fb.1.1758300000000.1116446470")).toBe("fb.1.1758300000000.1116446470");
    expect(validFbCookie("fb.2.1758300000000.IwAR1abcDEF")).toBe("fb.2.1758300000000.IwAR1abcDEF");
    expect(validFbCookie("garbage")).toBeNull();
    expect(validFbCookie("fb.1.123.IwAR1")).toBeNull();
    expect(validFbCookie(undefined)).toBeNull();
    expect(validTtp("2mR8ZPzK7yWdu4kW5Yx0GHUbJbE")).toBe("2mR8ZPzK7yWdu4kW5Yx0GHUbJbE");
    expect(validTtp("short")).toBeNull();
    expect(validTtp("has space in it")).toBeNull();
  });
});

describe("_fbc synthesis", () => {
  beforeEach(() => {
    resetPage();
    vi.spyOn(Date, "now").mockReturnValue(NOW);
  });

  it("stores _fbc for 90 days on the registrable domain when the URL has fbclid and the cookie is missing", async () => {
    history.replaceState(null, "", "/lp/failing-exam?fbclid=IwAR0abc&utm_source=meta");
    const beacon = stubBeacon();
    const writes = recordCookieWrites();
    createKerdly(OPTIONS);
    const fbc = `fb.1.${NOW}.IwAR0abc`;
    expect(writes).toContain(`_fbc=${fbc}; Max-Age=7776000; Path=/; Domain=.acme-app.com; SameSite=Lax; Secure`);
    expect(readCookie(document.cookie, "_fbc")).toBe(fbc);
    const [visit] = await beaconTouches(beacon);
    expect(visit?.cookies.fbc).toBe(fbc);
  });

  it("keeps the _fbc of the same click, with its original creation time", async () => {
    const existing = "fb.1.1759600000000.IwAR0abc";
    document.cookie = `_fbc=${existing}; Path=/`;
    history.replaceState(null, "", "/lp?fbclid=IwAR0abc");
    const beacon = stubBeacon();
    const writes = recordCookieWrites();
    createKerdly(OPTIONS);
    expect(writes.filter((w) => w.startsWith("_fbc="))).toEqual([]);
    expect((await beaconTouches(beacon))[0]?.cookies.fbc).toBe(existing);
  });

  it("replaces an older click's _fbc when a new fbclid arrives, as Meta's pixel does", async () => {
    document.cookie = "_fbc=fb.1.1759600000000.IwAROLD; Path=/; Domain=.acme-app.com";
    history.replaceState(null, "", "/lp?fbclid=IwARNEW");
    const beacon = stubBeacon();
    createKerdly(OPTIONS);
    expect(readCookie(document.cookie, "_fbc")).toBe(`fb.1.${NOW}.IwARNEW`);
    expect((await beaconTouches(beacon))[0]?.cookies.fbc).toBe(`fb.1.${NOW}.IwARNEW`);
  });

  it("sends an existing _fbc as it is when the URL has no fbclid", async () => {
    document.cookie = "_fbc=fb.1.1759600000000.IwAR0abc; Path=/";
    const beacon = stubBeacon();
    const writes = recordCookieWrites();
    createKerdly(OPTIONS);
    expect(writes.filter((w) => w.startsWith("_fbc="))).toEqual([]);
    expect((await beaconTouches(beacon))[0]?.cookies.fbc).toBe("fb.1.1759600000000.IwAR0abc");
  });

  it("mints nothing for a malformed fbclid", async () => {
    history.replaceState(null, "", "/lp?fbclid=not%20valid");
    const beacon = stubBeacon();
    createKerdly(OPTIONS);
    expect(readCookie(document.cookie, "_fbc")).toBeUndefined();
    expect((await beaconTouches(beacon))[0]?.cookies.fbc).toBeNull();
  });

  it("mints once per click: the click touch after the visit carries the same _fbc", async () => {
    history.replaceState(null, "", "/lp?fbclid=IwAR0abc");
    const beacon = stubBeacon();
    const kerdly = createKerdly(OPTIONS);
    vi.spyOn(Date, "now").mockReturnValue(NOW + 5000);
    kerdly.click("https://go.acme-app.com/k3f9q2x");
    const touches = await beaconTouches(beacon);
    expect(touches.map((t) => t.cookies.fbc)).toEqual([`fb.1.${NOW}.IwAR0abc`, `fb.1.${NOW}.IwAR0abc`]);
  });

  it("reads _fbp and _ttp, dropping malformed values", async () => {
    document.cookie = "_fbp=fb.1.1760399000000.123456789; Path=/";
    document.cookie = "_ttp=2mR8ZPzK7yWdu4kW5Yx0GHUbJbE; Path=/";
    const beacon = stubBeacon();
    const kerdly = createKerdly(OPTIONS);
    document.cookie = "_fbp=garbage; Path=/";
    kerdly.click("https://go.acme-app.com/k3f9q2x");
    const [visit, click] = await beaconTouches(beacon);
    expect(visit?.cookies).toEqual({ fbp: "fb.1.1760399000000.123456789", fbc: null, ttp: "2mR8ZPzK7yWdu4kW5Yx0GHUbJbE" });
    expect(click?.cookies).toEqual({ fbp: null, fbc: null, ttp: "2mR8ZPzK7yWdu4kW5Yx0GHUbJbE" });
  });
});
