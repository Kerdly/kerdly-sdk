import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createKerdly } from "../src/index.js";
import { IPV6_STORAGE_KEY, IPV6_TIMEOUT_MS, globalIpv6 } from "../src/ipv6.js";
import { beaconTouches, resetPage, stubBeacon } from "./helpers.js";

const IP6 = "2600:1700:5f20:8a10:1c2e:3d4f:5a6b:7c8d";
const LINK = "https://go.acme-app.com/k3f9q2x";
const OPTIONS = { key: "wk_live_example", endpoint: "https://go.acme-app.com", autoDecorate: false } as const;

type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

/**
 * An echo host that answers when the test says so: `answer(body, status)` resolves the pending
 * request, `fail()` rejects it. An aborted request rejects, as a browser's does.
 */
function stubEcho() {
  let resolve: (response: Response) => void = () => undefined;
  let reject: (error: unknown) => void = () => undefined;
  const fetchMock = vi.fn<Fetch>(
    (_url, init) =>
      new Promise<Response>((res, rej) => {
        resolve = res;
        reject = rej;
        init?.signal?.addEventListener("abort", () => rej(new DOMException("The operation was aborted", "AbortError")));
      }),
  );
  vi.stubGlobal("fetch", fetchMock);
  return {
    fetchMock,
    answer: (body: string, status = 200) => resolve(new Response(body, { status })),
    fail: () => reject(new TypeError("Failed to fetch")),
  };
}

/** The page's lookup, once it has ended (every instance on the page shares it). */
async function lookupEnded(): Promise<void> {
  await (window as unknown as Record<string, Promise<string> | undefined>).__kerdlyIp6;
}

/** A new page load in the same tab: the window's SDK state is gone, sessionStorage stays. */
function nextPageLoad(): void {
  const holder = window as unknown as Record<string, unknown>;
  delete holder.__kerdlyIp6;
  delete holder.__kerdlyVisits;
}

beforeEach(() => {
  resetPage();
  document.body.innerHTML = "";
});

afterEach(() => {
  vi.useRealTimers();
});

describe("public IPv6 lookup", () => {
  it("asks the default echo URL once at init, without cookies or cache", async () => {
    const echo = stubEcho();
    createKerdly({ ...OPTIONS, autoVisit: false });
    expect(echo.fetchMock).toHaveBeenCalledOnce();
    const [url, init] = echo.fetchMock.mock.calls[0] ?? [];
    expect(url).toBe("https://api6.ipify.org?format=json");
    expect(init).toMatchObject({ credentials: "omit", cache: "no-store" });
    expect(init?.signal).toBeInstanceOf(AbortSignal);
    echo.answer(JSON.stringify({ ip: IP6 }));
    await lookupEnded();
    expect(sessionStorage.getItem(IPV6_STORAGE_KEY)).toBe(IP6);
  });

  it("sends touches before the answer without ipv6, and every touch after it with ipv6", async () => {
    const beacon = stubBeacon();
    const echo = stubEcho();
    const kerdly = createKerdly(OPTIONS);
    kerdly.click(LINK);
    echo.answer(JSON.stringify({ ip: IP6 }));
    await lookupEnded();
    kerdly.click(LINK);
    kerdly.visit({ force: true });
    const touches = await beaconTouches(beacon);
    expect(touches.map((t) => [t.kind, t.ipv6])).toEqual([
      ["visit", undefined],
      ["click", undefined],
      ["click", IP6],
      ["visit", IP6],
    ]);
    expect(touches[0]).not.toHaveProperty("ipv6");
    // Where puts it: after cookies, before ts.
    expect(Object.keys(touches[2] ?? {}).slice(-3)).toEqual(["cookies", "ipv6", "ts"]);
  });

  it("sends it with the auto-decorate click", async () => {
    document.body.innerHTML = `<a data-ip6 href="${LINK}">Get the app</a>`;
    const anchor = document.querySelector("a") as HTMLAnchorElement;
    // jsdom cannot navigate; the SDK's capture listener on document runs before this one.
    anchor.addEventListener("click", (event) => event.preventDefault());
    const beacon = stubBeacon();
    const echo = stubEcho();
    createKerdly({ ...OPTIONS, autoVisit: false, autoDecorate: "a[data-ip6]" });
    echo.answer(JSON.stringify({ ip: IP6 }));
    await lookupEnded();
    anchor.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
    expect((await beaconTouches(beacon)).map((t) => [t.kind, t.link, t.ipv6])).toEqual([["click", LINK, IP6]]);
  });

  it("reuses the tab session's answer on later page loads: no lookup, and the first visit carries it", async () => {
    const beacon = stubBeacon();
    const echo = stubEcho();
    createKerdly({ ...OPTIONS, autoVisit: false });
    echo.answer(JSON.stringify({ ip: IP6 }));
    await lookupEnded();

    nextPageLoad();
    createKerdly(OPTIONS);
    expect(echo.fetchMock).toHaveBeenCalledOnce();
    expect((await beaconTouches(beacon)).map((t) => [t.kind, t.ipv6])).toEqual([["visit", IP6]]);
  });

  it("remembers for the tab session that there is no IPv6", async () => {
    const beacon = stubBeacon();
    const echo = stubEcho();
    createKerdly({ ...OPTIONS, autoVisit: false });
    echo.fail();
    await lookupEnded();
    expect(sessionStorage.getItem(IPV6_STORAGE_KEY)).toBe("");

    nextPageLoad();
    createKerdly(OPTIONS);
    expect(echo.fetchMock).toHaveBeenCalledOnce();
    expect((await beaconTouches(beacon))[0]).not.toHaveProperty("ipv6");
  });

  it("shares one lookup between the instances on a page", async () => {
    const beacon = stubBeacon();
    const echo = stubEcho();
    const first = createKerdly({ ...OPTIONS, autoVisit: false });
    const second = createKerdly({ ...OPTIONS, key: "wk_live_other", autoVisit: false });
    expect(echo.fetchMock).toHaveBeenCalledOnce();
    echo.answer(JSON.stringify({ ip: IP6 }));
    await lookupEnded();
    first.click(LINK);
    second.click(LINK);
    expect((await beaconTouches(beacon)).map((t) => [t.key, t.ipv6])).toEqual([
      ["wk_live_example", IP6],
      ["wk_live_other", IP6],
    ]);
  });

  it.each([
    ["an IPv4 address", JSON.stringify({ ip: "203.0.113.7" }), 200],
    ["a v4-mapped address", JSON.stringify({ ip: "::ffff:203.0.113.7" }), 200],
    ["a link-local address", JSON.stringify({ ip: "fe80::1c2e:3d4f:5a6b:7c8d" }), 200],
    ["a unique local address", JSON.stringify({ ip: "fd12:3456:789a::1" }), 200],
    ["garbage", JSON.stringify({ ip: "<html>" }), 200],
    ["no ip", JSON.stringify({ address: IP6 }), 200],
    ["a body that is not JSON", IP6, 200],
    ["an error status", JSON.stringify({ ip: IP6 }), 503],
  ])("drops %s", async (_name, body, status) => {
    const beacon = stubBeacon();
    const echo = stubEcho();
    const kerdly = createKerdly({ ...OPTIONS, autoVisit: false });
    echo.answer(body, status);
    await lookupEnded();
    kerdly.click(LINK);
    expect((await beaconTouches(beacon))[0]).not.toHaveProperty("ipv6");
    expect(sessionStorage.getItem(IPV6_STORAGE_KEY)).toBe("");
  });

  it("gives up after the timeout, aborting the request", async () => {
    vi.useFakeTimers();
    const beacon = stubBeacon();
    const echo = stubEcho();
    const kerdly = createKerdly({ ...OPTIONS, autoVisit: false });
    const signal = echo.fetchMock.mock.calls[0]?.[1]?.signal;
    vi.advanceTimersByTime(IPV6_TIMEOUT_MS - 1);
    expect(signal?.aborted).toBe(false);
    vi.advanceTimersByTime(1);
    expect(signal?.aborted).toBe(true);
    vi.useRealTimers();
    await lookupEnded();
    expect(sessionStorage.getItem(IPV6_STORAGE_KEY)).toBe("");
    kerdly.click(LINK);
    expect((await beaconTouches(beacon))[0]).not.toHaveProperty("ipv6");
  });

  it("ignores an answer after the timeout where the request cannot be aborted", async () => {
    vi.useFakeTimers();
    vi.stubGlobal("AbortController", undefined);
    const beacon = stubBeacon();
    const echo = stubEcho();
    const kerdly = createKerdly({ ...OPTIONS, autoVisit: false });
    expect(echo.fetchMock.mock.calls[0]?.[1]?.signal).toBeUndefined();
    vi.advanceTimersByTime(IPV6_TIMEOUT_MS);
    vi.useRealTimers();
    echo.answer(JSON.stringify({ ip: IP6 }));
    await lookupEnded();
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(sessionStorage.getItem(IPV6_STORAGE_KEY)).toBe("");
    kerdly.click(LINK);
    expect((await beaconTouches(beacon))[0]).not.toHaveProperty("ipv6");
  });

  it("is off with ipv6EchoUrl: null, and when touches cannot be sent", () => {
    stubBeacon();
    const echo = stubEcho();
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    createKerdly({ ...OPTIONS, ipv6EchoUrl: null });
    createKerdly({ ...OPTIONS, key: "", autoVisit: false });
    createKerdly({ ...OPTIONS, key: "sk_live_oops", autoVisit: false });
    expect(echo.fetchMock).not.toHaveBeenCalled();
    expect(sessionStorage.getItem(IPV6_STORAGE_KEY)).toBeNull();
  });

  it("asks a custom https echo URL, and only warns about one that is not https", async () => {
    const echo = stubEcho();
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    createKerdly({ ...OPTIONS, autoVisit: false, ipv6EchoUrl: "http://api6.example.com/" });
    expect(echo.fetchMock).not.toHaveBeenCalled();
    expect(warn).toHaveBeenCalledOnce();
    expect(warn.mock.calls[0]?.[0]).toMatch(/\[Kerdly\] ipv6EchoUrl must be an https URL/);

    createKerdly({ ...OPTIONS, autoVisit: false, ipv6EchoUrl: " https://api6.example.com/echo " });
    expect(echo.fetchMock.mock.calls.map(([url]) => url)).toEqual(["https://api6.example.com/echo"]);
    echo.answer(JSON.stringify({ ip: IP6 }));
    await lookupEnded();
  });

  it("works without sessionStorage, looking up on every page load", async () => {
    const denied = () => {
      throw new DOMException("The operation is insecure.", "SecurityError");
    };
    vi.stubGlobal("sessionStorage", { getItem: denied, setItem: denied });
    const beacon = stubBeacon();
    const echo = stubEcho();
    const kerdly = createKerdly({ ...OPTIONS, autoVisit: false });
    echo.answer(JSON.stringify({ ip: IP6 }));
    await lookupEnded();
    kerdly.click(LINK);
    expect((await beaconTouches(beacon))[0]?.ipv6).toBe(IP6);
    nextPageLoad();
    createKerdly({ ...OPTIONS, autoVisit: false });
    expect(echo.fetchMock).toHaveBeenCalledTimes(2);
    echo.fail();
    await lookupEnded();
  });

  it("never throws when fetch does", () => {
    vi.stubGlobal("fetch", () => {
      throw new TypeError("Refused by CSP");
    });
    const beacon = stubBeacon();
    expect(() => createKerdly(OPTIONS)).not.toThrow();
    expect(beacon).toHaveBeenCalledOnce();
  });
});

describe("globalIpv6", () => {
  it.each([
    [IP6, IP6],
    ["2001:4860:4860::8888", "2001:4860:4860::8888"],
    [" 2A02:C7F:1234:5678::1 ", "2a02:c7f:1234:5678::1"],
    ["3fff::", "3fff::"],
    ["2001:db8:1:2:3:4:5::", "2001:db8:1:2:3:4:5::"],
  ])("keeps %j", (value, expected) => {
    expect(globalIpv6(value)).toBe(expected);
  });

  it.each([
    "203.0.113.7",
    "::ffff:203.0.113.7",
    "::ffff:cb00:7107",
    "::1",
    "::",
    "fe80::1",
    "fd12:3456:789a::1",
    "ff02::1",
    "1fff::1",
    "4000::1",
    "2001:db8::1::2",
    "2001:db8:1:2:3:4:5",
    "2001:db8:1:2:3:4:5:6:7",
    "2001:db8:1:2:3:4:5:6::",
    "2001:db8::12345",
    "2001:db8::1%en0",
    "2001:db8::203.0.113.7",
    ":2001:db8::1",
    "2001:db8::1:",
    "",
    null,
    42,
    { ip: IP6 },
  ])("drops %j", (value) => {
    expect(globalIpv6(value)).toBeNull();
  });
});
