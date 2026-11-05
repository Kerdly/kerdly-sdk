import { beforeEach, describe, expect, it, vi } from "vitest";
import { createKerdly } from "../src/index.js";
import { beaconTouches, resetPage, stubBeacon } from "./helpers.js";

const VID = "q3k9m2x7a8b4c5d6e7f8g9";
const LINK = "https://go.acme-app.com/k3f9q2x?utm_campaign=failed3";
const DECORATED = `${LINK}&kerdly_v=${VID}`;

/**
 * Listeners added in one test stay on the document, so each test decorates its own attribute
 * (`data-t1`, `data-t2`, …) and anchors from earlier tests never match later instances.
 */
function anchor(attribute: string, href = LINK, extra: Record<string, string> = {}): HTMLAnchorElement {
  const a = document.createElement("a");
  a.setAttribute(attribute, "");
  a.href = href;
  for (const [name, value] of Object.entries(extra)) a.setAttribute(name, value);
  a.innerHTML = "<span>Get the app</span>";
  document.body.appendChild(a);
  return a;
}

interface Outcome {
  defaultPrevented: boolean;
  hrefAtNavigation: string;
}

/**
 * Click like a person would and capture what the browser would navigate to. A listener added after
 * the SDK's sees the event once the SDK is done, records the href and stops jsdom from navigating.
 */
function press(target: Element, init: MouseEventInit & { type?: "click" | "auxclick" } = {}): Outcome {
  const { type = "click", ...mouse } = init;
  const outcome: Outcome = { defaultPrevented: false, hrefAtNavigation: "" };
  const a = target.closest("a");
  const watch = (event: Event) => {
    outcome.defaultPrevented = event.defaultPrevented;
    outcome.hrefAtNavigation = a ? a.href : "";
    event.preventDefault();
  };
  document.addEventListener(type, watch, true);
  target.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, button: 0, ...mouse }));
  document.removeEventListener(type, watch, true);
  return outcome;
}

beforeEach(() => {
  resetPage();
  document.body.innerHTML = "";
  document.cookie = `kerdly_vid=${VID}; Path=/`;
});

describe("autoDecorate", () => {
  it("decorates a[data-kerdly-link] in place on click and sends a click touch, without preventing navigation", async () => {
    const beacon = stubBeacon();
    createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoVisit: false });
    const a = anchor("data-kerdly-link");
    const outcome = press(a.querySelector("span") as Element);
    expect(outcome).toEqual({ defaultPrevented: false, hrefAtNavigation: DECORATED });
    expect(a.href).toBe(DECORATED);
    const [touch] = await beaconTouches(beacon);
    expect(touch).toMatchObject({ kind: "click", link: LINK, visitor_id: VID, url: "https://acme-app.com/" });
  });

  it("decorates for modifier-key clicks, target=_blank and middle clicks too", async () => {
    const beacon = stubBeacon();
    createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoVisit: false, autoDecorate: "a[data-t1]" });
    const cases: [HTMLAnchorElement, Parameters<typeof press>[1]][] = [
      [anchor("data-t1"), { metaKey: true }],
      [anchor("data-t1"), { ctrlKey: true }],
      [anchor("data-t1"), { shiftKey: true }],
      [anchor("data-t1", LINK, { target: "_blank", rel: "noopener" }), {}],
      [anchor("data-t1"), { type: "auxclick", button: 1 }],
    ];
    for (const [a, init] of cases) {
      expect(press(a, init)).toEqual({ defaultPrevented: false, hrefAtNavigation: DECORATED });
    }
    expect((await beaconTouches(beacon)).map((t) => t.link)).toEqual(Array(5).fill(LINK));
  });

  it("ignores right clicks, unmatched anchors and non-http links", () => {
    const beacon = stubBeacon();
    createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoVisit: false, autoDecorate: "a[data-t2]" });
    const matched = anchor("data-t2");
    press(matched, { type: "auxclick", button: 2 });
    expect(matched.href).toBe(LINK);
    const other = anchor("data-other");
    press(other);
    expect(other.href).toBe(LINK);
    const mail = anchor("data-t2", "mailto:hi@acme-app.com");
    press(mail);
    expect(mail.href).toBe("mailto:hi@acme-app.com");
    expect(beacon).not.toHaveBeenCalled();
  });

  it("reports the authored link on a repeat click and decorates only once", async () => {
    const beacon = stubBeacon();
    createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoVisit: false, autoDecorate: "a[data-t3]" });
    const a = anchor("data-t3");
    press(a);
    press(a);
    expect(a.href).toBe(DECORATED);
    expect((await beaconTouches(beacon)).map((t) => t.link)).toEqual([LINK, LINK]);
  });

  it("leaves a click another handler already cancelled alone", () => {
    const beacon = stubBeacon();
    const cancel = (event: Event) => event.preventDefault();
    window.addEventListener("click", cancel, true);
    try {
      createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoVisit: false, autoDecorate: "a[data-t4]" });
      const a = anchor("data-t4");
      press(a);
      expect(a.href).toBe(LINK);
      expect(beacon).not.toHaveBeenCalled();
    } finally {
      window.removeEventListener("click", cancel, true);
    }
  });

  it("still decorates when a page handler stops propagation", () => {
    stubBeacon();
    createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoVisit: false, autoDecorate: "a[data-t5]" });
    const a = anchor("data-t5");
    a.addEventListener("click", (event) => event.stopPropagation());
    press(a);
    expect(a.href).toBe(DECORATED);
  });

  it("is off with autoDecorate: false, and an invalid selector only warns", () => {
    const beacon = stubBeacon();
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoVisit: false, autoDecorate: false });
    createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoVisit: false, autoDecorate: "a[data-t6]!!" });
    expect(warn).toHaveBeenCalledOnce();
    const a = anchor("data-t6");
    press(a);
    expect(a.href).toBe(LINK);
    expect(beacon).not.toHaveBeenCalled();
  });
});
