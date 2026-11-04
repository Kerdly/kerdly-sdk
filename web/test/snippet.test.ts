// @vitest-environment node
/**
 * The real snippet: src/snippet.ts bundled and minified the way build.mjs builds dist/kerdly.js, served
 * at https://go.acme-app.com/kerdly.js to a fresh jsdom page that loads it with an ordinary script tag.
 */
import { build } from "esbuild";
import { JSDOM, VirtualConsole, requestInterceptor, type DOMWindow } from "jsdom";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { beforeAll, describe, expect, it, vi, type Mock } from "vitest";
import { autoDecorateFrom, endpointFromSrc, ipv6EchoUrlFrom, optionsFromScript } from "../src/script.js";
import type { Kerdly, KerdlyTouch } from "../src/types.js";

const SNIPPET_URL = "https://go.acme-app.com/kerdly.js";
const PAGE_URL = "https://acme-app.com/lp/failing-exam?fbclid=IwAR0abc&utm_source=meta";
const GUEST_ID = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";
const IP6 = "2600:1700:5f20:8a10:1c2e:3d4f:5a6b:7c8d";

let snippet = "";

beforeAll(async () => {
  const result = await build({
    entryPoints: [resolve(dirname(fileURLToPath(import.meta.url)), "../src/snippet.ts")],
    bundle: true,
    format: "iife",
    platform: "browser",
    target: ["es2018"],
    minify: true,
    write: false,
  });
  snippet = result.outputFiles[0]?.text ?? "";
});

type Beacon = (url: string, data?: unknown) => boolean;
type Fetch = (url: string, init?: unknown) => Promise<Response>;

interface Page {
  window: DOMWindow & { kerdly?: Kerdly; __kerdlyIp6?: Promise<string> };
  document: Document;
  beacon: Mock<Beacon>;
  warnings: string[];
  touches(): Promise<KerdlyTouch[]>;
}

/**
 * A landing page that includes `head` in its <head>, with `cookies` already set, once it has loaded.
 * jsdom has no `fetch`, so the snippet's IPv6 lookup finds nothing unless `fetch` is given.
 */
async function open(head: string, body = "", cookies: string[] = [], fetch?: Mock<Fetch>): Promise<Page> {
  const beacon = vi.fn<Beacon>(() => true);
  const warnings: string[] = [];
  const virtualConsole = new VirtualConsole();
  virtualConsole.on("warn", (message: string) => warnings.push(message));
  virtualConsole.on("jsdomError", () => undefined);
  const dom = new JSDOM(
    `<!doctype html><html><head><title>Failed the DMV test?</title>${head}</head><body>${body}</body></html>`,
    {
      url: PAGE_URL,
      referrer: "https://l.facebook.com/",
      runScripts: "dangerously",
      virtualConsole,
      resources: {
        interceptors: [
          requestInterceptor((request) =>
            request.url === SNIPPET_URL
              ? new Response(snippet, { headers: { "Content-Type": "application/javascript" } })
              : new Response("", { status: 404 }),
          ),
        ],
      },
      beforeParse(window) {
        Object.defineProperty(window.navigator, "sendBeacon", { value: beacon, configurable: true });
        if (fetch) Object.defineProperty(window, "fetch", { value: fetch, configurable: true });
        for (const cookie of cookies) window.document.cookie = cookie;
      },
    },
  );
  const window = dom.window as Page["window"];
  if (window.document.readyState !== "complete") {
    await new Promise((resolve) => window.addEventListener("load", resolve));
  }
  // Clicks below would make jsdom try to navigate, which it cannot do.
  window.addEventListener("click", (event) => event.preventDefault());
  return {
    window,
    document: window.document,
    beacon,
    warnings,
    touches: () =>
      Promise.all(beacon.mock.calls.map(async ([, data]) => JSON.parse(await (data as Blob).text()) as KerdlyTouch)),
  };
}

function click(page: Page, selector: string): HTMLAnchorElement {
  const anchor = page.document.querySelector(selector) as HTMLAnchorElement;
  anchor.dispatchEvent(new page.window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
  return anchor;
}

const cookieOf = (page: Page, name: string) =>
  page.document.cookie
    .split("; ")
    .find((c) => c.startsWith(`${name}=`))
    ?.slice(name.length + 1);

describe("kerdly.js snippet", () => {
  it("initialises from its script tag: one visit per page load, window.kerdly, decorated links", async () => {
    const page = await open(
      `<script src="${SNIPPET_URL}" data-key="wk_live_example" async></script>`,
      `<a data-kerdly-link href="https://go.acme-app.com/k3f9q2x">Get the app</a>`,
    );
    const kerdly = page.window.kerdly;
    expect(kerdly).toBeDefined();
    for (const method of ["visitorId", "visit", "click", "decorate", "eventId", "identify"] as const) {
      expect(typeof kerdly?.[method]).toBe("function");
    }

    // The endpoint defaults to where the script came from.
    expect(page.beacon).toHaveBeenCalledOnce();
    expect(page.beacon.mock.calls[0]?.[0]).toBe("https://go.acme-app.com/v1/web/touch");
    const vid = cookieOf(page, "afr_vid") ?? "";
    expect(vid).toMatch(/^[0-9abcdefghjkmnpqrstvwxyz]{22}$/);
    expect(kerdly?.visitorId()).toBe(vid);
    expect(kerdly?.eventId("StartTrial")).toBe(`${vid}:StartTrial`);
    expect(cookieOf(page, "_fbc")).toMatch(/^fb\.1\.\d{13}\.IwAR0abc$/);

    const anchor = click(page, "a[data-kerdly-link]");
    expect(anchor.href).toBe(`https://go.acme-app.com/k3f9q2x?afr_v=${vid}`);

    const [visit, linkClick] = await page.touches();
    expect(visit).toMatchObject({
      key: "wk_live_example",
      kind: "visit",
      visitor_id: vid,
      url: PAGE_URL,
      referrer: "https://l.facebook.com/",
      title: "Failed the DMV test?",
      chain_from: null,
      link: null,
      cookies: { fbp: null, fbc: cookieOf(page, "_fbc"), ttp: null },
    });
    expect(linkClick).toMatchObject({ kind: "click", link: "https://go.acme-app.com/k3f9q2x", visitor_id: vid });
  });

  it("identifies the visitor through window.kerdly, once per pair", async () => {
    const page = await open(`<script src="${SNIPPET_URL}" data-key="wk_live_example" async></script>`);
    const kerdly = page.window.kerdly;
    expect(kerdly?.identify("Xq9vK2mT4bR7nP1sL8wZ3cY6hJ5d")).toBe(true);
    expect(kerdly?.identify("Xq9vK2mT4bR7nP1sL8wZ3cY6hJ5d")).toBe(false);
    expect(page.beacon.mock.calls.map(([url]) => url)).toEqual([
      "https://go.acme-app.com/v1/web/touch",
      "https://go.acme-app.com/v1/web/identify",
    ]);
    const identify = JSON.parse(await (page.beacon.mock.calls[1]?.[1] as Blob).text());
    expect(identify).toEqual({
      key: "wk_live_example",
      visitor_id: cookieOf(page, "afr_vid"),
      user_id: "Xq9vK2mT4bR7nP1sL8wZ3cY6hJ5d",
    });
    expect(JSON.parse(page.window.localStorage.getItem("afr_uid") ?? "null")).toEqual([
      "wk_live_example",
      cookieOf(page, "afr_vid"),
      "Xq9vK2mT4bR7nP1sL8wZ3cY6hJ5d",
    ]);
  });

  it("reads data-endpoint, data-cookie-domain, data-visitor-cookie and data-auto-decorate", async () => {
    const page = await open(
      `<script src="${SNIPPET_URL}" data-key="wk_live_example" data-endpoint="https://collector.example.com/api/"` +
        ` data-cookie-domain=".acme-app.com" data-visitor-cookie="__guest_id" data-auto-decorate="a.cta" async></script>`,
      `<a class="cta" href="https://go.acme-app.com/k3f9q2x">CTA</a><a data-kerdly-link href="https://go.acme-app.com/other">Other</a>`,
      [`__guest_id=${GUEST_ID}; Path=/`],
    );
    expect(page.beacon.mock.calls[0]?.[0]).toBe("https://collector.example.com/api/v1/web/touch");
    expect(page.window.kerdly?.visitorId()).toBe(GUEST_ID);
    expect(cookieOf(page, "afr_vid")).toBeUndefined();
    expect(click(page, "a.cta").href).toBe(`https://go.acme-app.com/k3f9q2x?afr_v=${GUEST_ID}`);
    expect(click(page, "a[data-kerdly-link]").href).toBe("https://go.acme-app.com/other");
    expect((await page.touches()).map((t) => [t.kind, t.visitor_id])).toEqual([
      ["visit", GUEST_ID],
      ["click", GUEST_ID],
    ]);
  });

  it("turns link decoration off with data-auto-decorate=false", async () => {
    const page = await open(
      `<script src="${SNIPPET_URL}" data-key="wk_live_example" data-auto-decorate="false" async></script>`,
      `<a data-kerdly-link href="https://go.acme-app.com/k3f9q2x">Get the app</a>`,
    );
    expect(click(page, "a[data-kerdly-link]").href).toBe("https://go.acme-app.com/k3f9q2x");
    expect(page.beacon).toHaveBeenCalledOnce();
  });

  it("keeps the first instance when the snippet is included twice", async () => {
    const page = await open(
      `<script src="${SNIPPET_URL}" data-key="wk_live_example"></script>` +
        `<script>window.firstKerdly = window.kerdly;</script>` +
        `<script src="${SNIPPET_URL}" data-key="wk_live_example"></script>`,
    );
    expect(page.window.kerdly).toBe(page.window.firstKerdly);
    expect(page.beacon).toHaveBeenCalledOnce();
  });

  it("sends the IPv6 from the echo URL in data-ipv6-echo-url once it is known; an empty one turns it off", async () => {
    const echo = vi.fn<Fetch>(async () => new Response(JSON.stringify({ ip: IP6 })));
    const page = await open(
      `<script src="${SNIPPET_URL}" data-key="wk_live_example" data-ipv6-echo-url="https://api6.example.com/echo" async></script>`,
      `<a data-kerdly-link href="https://go.acme-app.com/k3f9q2x">Get the app</a>`,
      [],
      echo,
    );
    expect(echo.mock.calls.map(([url]) => url)).toEqual(["https://api6.example.com/echo"]);
    await page.window.__kerdlyIp6;
    click(page, "a[data-kerdly-link]");
    expect((await page.touches()).map((t) => [t.kind, t.ipv6])).toEqual([
      ["visit", undefined],
      ["click", IP6],
    ]);
    expect(page.window.sessionStorage.getItem("afr_ip6")).toBe(IP6);

    const off = vi.fn<Fetch>();
    await open(`<script src="${SNIPPET_URL}" data-key="wk_live_example" data-ipv6-echo-url="" async></script>`, "", [], off);
    expect(off).not.toHaveBeenCalled();
  });

  it("works as an inline script given data-endpoint", async () => {
    const page = await open("");
    const script = page.document.createElement("script");
    script.setAttribute("data-key", "wk_live_example");
    script.setAttribute("data-endpoint", "https://go.acme-app.com");
    script.textContent = snippet;
    page.document.head.appendChild(script);
    expect(page.beacon).toHaveBeenCalledOnce();
    expect(page.beacon.mock.calls[0]?.[0]).toBe("https://go.acme-app.com/v1/web/touch");
  });

  it("exposes an inert window.kerdly and warns when data-key is missing", async () => {
    const page = await open(`<script src="${SNIPPET_URL}" async></script>`);
    expect(page.window.kerdly?.visit({ force: true })).toBe(false);
    expect(page.beacon).not.toHaveBeenCalled();
    expect(page.warnings.join("\n")).toMatch(/\[Kerdly\] a key is required/);
  });
});

describe("snippet options", () => {
  const { document } = new JSDOM("", { url: PAGE_URL }).window;

  function script(attributes: Record<string, string>): HTMLScriptElement {
    const element = document.createElement("script");
    for (const [name, value] of Object.entries(attributes)) element.setAttribute(name, value);
    return element;
  }

  it("maps the data attributes to createKerdly options", () => {
    expect(
      optionsFromScript(
        script({
          src: SNIPPET_URL,
          "data-key": " wk_live_example ",
          "data-cookie-domain": ".acme-app.com",
          "data-visitor-cookie": "__guest_id",
          "data-auto-decorate": "a.cta",
          "data-ipv6-echo-url": "https://api6.example.com/echo",
        }),
      ),
    ).toEqual({
      key: "wk_live_example",
      endpoint: "https://go.acme-app.com",
      cookieDomain: ".acme-app.com",
      visitorCookie: "__guest_id",
      autoVisit: true,
      autoDecorate: "a.cta",
      ipv6EchoUrl: "https://api6.example.com/echo",
    });
    expect(optionsFromScript(null)).toMatchObject({ key: "", endpoint: "", autoDecorate: true });
  });

  it("derives the endpoint from the script's own URL", () => {
    expect(endpointFromSrc("https://go.acme-app.com/kerdly.js")).toBe("https://go.acme-app.com");
    expect(endpointFromSrc("https://go.acme-app.com/kerdly.js?v=3")).toBe("https://go.acme-app.com");
    expect(endpointFromSrc("https://app.kerdly.com/api/kerdly.js")).toBe(
      "https://app.kerdly.com/api",
    );
    expect(endpointFromSrc("")).toBe("");
    expect(endpointFromSrc("not a url")).toBe("");
  });

  it.each([
    [null, true],
    ["", true],
    ["true", true],
    ["false", false],
    ["off", false],
    ["0", false],
    ["a.cta, a[data-store]", "a.cta, a[data-store]"],
  ])("data-auto-decorate=%j → %j", (value, expected) => {
    expect(autoDecorateFrom(value)).toBe(expected);
  });

  it.each([
    [null, undefined],
    ["", null],
    ["  ", null],
    [" https://api6.example.com/echo ", "https://api6.example.com/echo"],
  ])("data-ipv6-echo-url=%j → %j", (value, expected) => {
    expect(ipv6EchoUrlFrom(value)).toBe(expected);
  });
});
