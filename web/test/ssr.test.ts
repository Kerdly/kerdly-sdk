// @vitest-environment node
import { afterEach, describe, expect, it } from "vitest";

const BROWSER_GLOBALS = ["window", "document", "location", "navigator", "history", "localStorage"] as const;

function trapBrowserGlobals(): string[] {
  const touched: string[] = [];
  for (const name of BROWSER_GLOBALS) {
    Object.defineProperty(globalThis, name, {
      configurable: true,
      get() {
        touched.push(name);
        return undefined;
      },
    });
  }
  return touched;
}

const originals = new Map(BROWSER_GLOBALS.map((name) => [name, Object.getOwnPropertyDescriptor(globalThis, name)]));

afterEach(() => {
  for (const [name, descriptor] of originals) {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor);
    else delete (globalThis as Record<string, unknown>)[name];
  }
});

describe("server-side rendering", () => {
  it("importing the module touches no browser global", async () => {
    const touched = trapBrowserGlobals();
    const module = await import("../src/index.js");
    expect(typeof module.createKerdly).toBe("function");
    expect(touched).toEqual([]);
  });

  it("createKerdly off the browser returns an inert instance that never throws", async () => {
    const { createKerdly } = await import("../src/index.js");
    const kerdly = createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com" });
    expect(kerdly.visitorId()).toBe("");
    expect(kerdly.visit()).toBe(false);
    expect(kerdly.click("https://go.acme-app.com/k3f9q2x")).toBe("https://go.acme-app.com/k3f9q2x");
    expect(kerdly.decorate("https://go.acme-app.com/k3f9q2x")).toBe("https://go.acme-app.com/k3f9q2x");
    expect(kerdly.eventId("StartTrial")).toBe(":StartTrial");
    expect(kerdly.identify("Xq9vK2mT4bR7nP1sL8wZ3cY6hJ5d")).toBe(false);
  });
});
