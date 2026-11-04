import { beforeEach, describe, expect, it } from "vitest";
import { createKerdly } from "../src/index.js";
import { decorateUrl, withQueryParam } from "../src/url.js";
import { beaconTouches, resetPage, stubBeacon } from "./helpers.js";

const VID = "q3k9m2x7a8b4c5d6e7f8g9";

describe("decorateUrl", () => {
  it.each([
    ["https://go.acme-app.com/k3f9q2x", `https://go.acme-app.com/k3f9q2x?afr_v=${VID}`],
    ["https://go.acme-app.com/k3f9q2x?src=hero", `https://go.acme-app.com/k3f9q2x?src=hero&afr_v=${VID}`],
    ["https://go.acme-app.com/k3f9q2x?src=hero#top", `https://go.acme-app.com/k3f9q2x?src=hero&afr_v=${VID}#top`],
    ["https://go.acme-app.com/k3f9q2x#/route?x=1", `https://go.acme-app.com/k3f9q2x?afr_v=${VID}#/route?x=1`],
    ["https://go.acme-app.com/k3f9q2x?", `https://go.acme-app.com/k3f9q2x?afr_v=${VID}`],
    ["/app?lp=failing-exam", `/app?lp=failing-exam&afr_v=${VID}`],
    ["//go.acme-app.com/k3f9q2x", `//go.acme-app.com/k3f9q2x?afr_v=${VID}`],
  ])("%s", (url, expected) => {
    expect(decorateUrl(url, VID)).toBe(expected);
  });

  it("keeps the other parameters exactly as written", () => {
    const url = "https://go.acme-app.com/k3f9q2x?utm_campaign=Spring%20Sale&q=a+b&empty=&flag&utm_campaign=dup";
    expect(decorateUrl(url, VID)).toBe(`${url}&afr_v=${VID}`);
  });

  it("is idempotent and never adds a second afr_v", () => {
    const once = decorateUrl("https://go.acme-app.com/k3f9q2x?src=hero", VID);
    expect(decorateUrl(once, VID)).toBe(once);
    expect(decorateUrl(decorateUrl(once, VID), VID)).toBe(once);
    expect(once.match(/afr_v=/g)).toHaveLength(1);
  });

  it("leaves a URL that already carries this id where it is", () => {
    const url = `https://go.acme-app.com/k3f9q2x?afr_v=${VID}&src=hero`;
    expect(decorateUrl(url, VID)).toBe(url);
  });

  it("replaces another visitor's afr_v, and collapses duplicates", () => {
    expect(decorateUrl("https://go.acme-app.com/k3f9q2x?afr_v=someoneelse&src=hero", VID)).toBe(
      `https://go.acme-app.com/k3f9q2x?src=hero&afr_v=${VID}`,
    );
    expect(decorateUrl(`https://go.acme-app.com/x?afr_v=${VID}&afr_v=${VID}`, VID)).toBe(`https://go.acme-app.com/x?afr_v=${VID}`);
  });

  it("encodes an id that needs it", () => {
    expect(decorateUrl("https://go.acme-app.com/x", "a b&c")).toBe("https://go.acme-app.com/x?afr_v=a%20b%26c");
  });

  it("never touches non-http URLs", () => {
    for (const url of ["mailto:hi@acme-app.com", "tel:+15550100", "javascript:void(0)", "sms:+15550100?body=x"]) {
      expect(decorateUrl(url, VID)).toBe(url);
    }
    expect(decorateUrl("", VID)).toBe("");
  });

  it("does nothing without an id", () => {
    expect(decorateUrl("https://go.acme-app.com/x", "")).toBe("https://go.acme-app.com/x");
  });
});

describe("withQueryParam with null", () => {
  it("removes the parameter and nothing else", () => {
    expect(withQueryParam(`https://go.acme-app.com/x?a=1&afr_v=${VID}#h`, "afr_v", null)).toBe("https://go.acme-app.com/x?a=1#h");
    expect(withQueryParam(`https://go.acme-app.com/x?afr_v=${VID}`, "afr_v", null)).toBe("https://go.acme-app.com/x");
    expect(withQueryParam("https://go.acme-app.com/x?a=1&&b=2", "afr_v", null)).toBe("https://go.acme-app.com/x?a=1&&b=2");
  });
});

describe("Kerdly.decorate, click and eventId", () => {
  beforeEach(() => {
    resetPage();
    document.cookie = `afr_vid=${VID}; Path=/`;
  });

  it("decorates with the visitor id", () => {
    const kerdly = createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoVisit: false, autoDecorate: false });
    expect(kerdly.decorate("https://go.acme-app.com/k3f9q2x")).toBe(`https://go.acme-app.com/k3f9q2x?afr_v=${VID}`);
    expect(kerdly.decorate(kerdly.decorate("https://go.acme-app.com/k3f9q2x"))).toBe(`https://go.acme-app.com/k3f9q2x?afr_v=${VID}`);
  });

  it("click sends the link as given and returns it decorated", async () => {
    const beacon = stubBeacon();
    const kerdly = createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoVisit: false, autoDecorate: false });
    expect(kerdly.click("https://go.acme-app.com/k3f9q2x?src=hero")).toBe(`https://go.acme-app.com/k3f9q2x?src=hero&afr_v=${VID}`);
    const [touch] = await beaconTouches(beacon);
    expect(touch).toMatchObject({ kind: "click", link: "https://go.acme-app.com/k3f9q2x?src=hero", visitor_id: VID });
    expect(kerdly.click("")).toBe("");
    expect(beacon).toHaveBeenCalledOnce();
  });

  it("eventId is <visitor id>:<name>", () => {
    const kerdly = createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoVisit: false, autoDecorate: false });
    expect(kerdly.eventId("StartTrial")).toBe(`${VID}:StartTrial`);
    expect(kerdly.eventId("InitiateCheckout")).toBe(`${VID}:InitiateCheckout`);
  });
});
