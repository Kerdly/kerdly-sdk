import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { DEFAULT_ENDPOINT, createKerdly, type KerdlyTouch } from "../src/index.js";
import { beaconTouches, resetPage, setReferrer, stubBeacon } from "./helpers.js";

/** The golden request every SDK's tests build (spec/fixtures). */
const FIXTURE = JSON.parse(
  readFileSync(
    resolve(dirname(fileURLToPath(import.meta.url)), "../../spec/fixtures/web-touch-visit.request.json"),
    "utf8",
  ),
) as KerdlyTouch;

const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

beforeEach(() => resetPage());

describe("touch payload", () => {
  it("builds the fixture's visit from the fixture's page", async () => {
    const fixtureUrl = new URL(FIXTURE.url);
    history.replaceState(null, "", fixtureUrl.pathname + fixtureUrl.search);
    setReferrer(FIXTURE.referrer ?? "");
    document.title = FIXTURE.title ?? "";
    document.cookie = `_fbp=${FIXTURE.cookies.fbp}; Path=/`;
    document.cookie = `afr_vid=${FIXTURE.visitor_id}; Path=/`;
    vi.spyOn(Date, "now").mockReturnValue(FIXTURE.ts);
    vi.spyOn(crypto, "randomUUID").mockReturnValue(FIXTURE.event_id as ReturnType<Crypto["randomUUID"]>);
    const beacon = stubBeacon();

    createKerdly({ key: FIXTURE.key, endpoint: "https://go.acme-app.com", autoDecorate: false });

    expect(beacon).toHaveBeenCalledOnce();
    expect(beacon.mock.calls[0]?.[0]).toBe("https://go.acme-app.com/v1/web/touch");
    const [body] = await beaconTouches(beacon);
    expect(Object.keys(body ?? {})).toEqual(Object.keys(FIXTURE));
    expect(Object.keys(body?.cookies ?? {})).toEqual(Object.keys(FIXTURE.cookies));
    // The fixture's URL carries fbclid=IwAR0abc but its cookies say fbc: null. The
    // SDK synthesizes _fbc in that case, so the one field that differs is the synthesized fbc.
    expect(body).toEqual({
      ...FIXTURE,
      cookies: { ...FIXTURE.cookies, fbc: `fb.1.${FIXTURE.ts}.IwAR0abc` },
    });
  });

  it("gives a click the same keys, with link set and a fresh event id", async () => {
    const beacon = stubBeacon();
    const kerdly = createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com/", autoDecorate: false });
    kerdly.click("https://go.acme-app.com/k3f9q2x?utm_campaign=failed3");
    const [visit, click] = await beaconTouches(beacon);
    expect(Object.keys(click ?? {})).toEqual(Object.keys(FIXTURE));
    expect(click).toMatchObject({ kind: "click", link: "https://go.acme-app.com/k3f9q2x?utm_campaign=failed3" });
    expect(visit).toMatchObject({ kind: "visit", link: null });
    expect(visit?.event_id).toMatch(UUID_V4);
    expect(click?.event_id).toMatch(UUID_V4);
    expect(click?.event_id).not.toBe(visit?.event_id);
    expect(beacon.mock.calls.map(([url]) => url)).toEqual([
      "https://go.acme-app.com/v1/web/touch",
      "https://go.acme-app.com/v1/web/touch",
    ]);
  });

  it("sends null for an empty referrer, title, chain and cookies", async () => {
    const beacon = stubBeacon();
    createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoDecorate: false });
    const [visit] = await beaconTouches(beacon);
    expect(visit).toMatchObject({
      url: "https://acme-app.com/",
      referrer: null,
      title: null,
      chain_from: null,
      link: null,
      cookies: { fbp: null, fbc: null, ttp: null },
    });
    expect(typeof visit?.ts).toBe("number");
  });

  it("takes chain_from from the page's afr_v parameter", async () => {
    history.replaceState(null, "", "/lp/failing-exam?afr_v=7h3k9q2x7a8b4c&src=qr");
    const beacon = stubBeacon();
    createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoDecorate: false });
    const [visit] = await beaconTouches(beacon);
    expect(visit?.chain_from).toBe("7h3k9q2x7a8b4c");
    expect(visit?.url).toBe("https://acme-app.com/lp/failing-exam?afr_v=7h3k9q2x7a8b4c&src=qr");
  });

  it("puts the key in the body, never in a URL or header", async () => {
    const beacon = stubBeacon();
    createKerdly({ key: "wk_live_secretish", endpoint: "https://go.acme-app.com", autoDecorate: false });
    expect(beacon.mock.calls[0]?.[0]).not.toContain("wk_live");
    expect((await beaconTouches(beacon))[0]?.key).toBe("wk_live_secretish");
  });
});

describe("visit", () => {
  it("sends once per page URL unless forced", () => {
    const beacon = stubBeacon();
    const kerdly = createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoDecorate: false });
    expect(beacon).toHaveBeenCalledTimes(1);
    expect(kerdly.visit()).toBe(false);
    expect(kerdly.visit({ force: true })).toBe(true);
    history.pushState(null, "", "/next-route");
    expect(kerdly.visit()).toBe(true);
    expect(kerdly.visit()).toBe(false);
    expect(beacon).toHaveBeenCalledTimes(3);
  });

  it("is shared by every instance on the page, per key", () => {
    const beacon = stubBeacon();
    createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoDecorate: false });
    createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoDecorate: false });
    createKerdly({ key: "wk_live_other", endpoint: "https://go.acme-app.com", autoDecorate: false });
    expect(beacon).toHaveBeenCalledTimes(2);
  });

  it("is not sent automatically with autoVisit: false", () => {
    const beacon = stubBeacon();
    const kerdly = createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoVisit: false, autoDecorate: false });
    expect(beacon).not.toHaveBeenCalled();
    expect(kerdly.visit()).toBe(true);
    expect(beacon).toHaveBeenCalledOnce();
  });

  it("waits for a prerendered page to be shown", () => {
    const beacon = stubBeacon();
    Object.defineProperty(document, "prerendering", { value: true, configurable: true });
    try {
      createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoDecorate: false });
      expect(beacon).not.toHaveBeenCalled();
      document.dispatchEvent(new Event("prerenderingchange"));
      document.dispatchEvent(new Event("prerenderingchange"));
      expect(beacon).toHaveBeenCalledOnce();
    } finally {
      delete (document as unknown as Record<string, unknown>).prerendering;
    }
  });

  it("sends nothing without a key or with a secret key, and warns", () => {
    const beacon = stubBeacon();
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const noKey = createKerdly({ key: "", endpoint: "https://go.acme-app.com", autoDecorate: false });
    const secret = createKerdly({ key: "sk_live_oops", endpoint: "https://go.acme-app.com", autoDecorate: false });
    expect(noKey.visit({ force: true })).toBe(false);
    expect(noKey.click("https://go.acme-app.com/k3f9q2x")).toMatch(/afr_v=/);
    expect(secret.visit({ force: true })).toBe(false);
    expect(beacon).not.toHaveBeenCalled();
    expect(warn).toHaveBeenCalledTimes(2);
    expect(warn.mock.calls[1]?.[0]).toMatch(/sk_ keys/);
  });

  it("sends to the Kerdly collector when no endpoint is given", () => {
    const beacon = stubBeacon();
    const kerdly = createKerdly({ key: "wk_live_example", autoDecorate: false });
    expect(kerdly.visit({ force: true })).toBe(true);
    expect(beacon.mock.calls[0]?.[0]).toBe(`${DEFAULT_ENDPOINT}/v1/web/touch`);
  });
});
