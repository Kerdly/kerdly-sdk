import { beforeEach, describe, expect, it, vi } from "vitest";
import { BODY_CONTENT_TYPE, IDENTIFY_PATH, TOUCH_PATH, endpointUrl, post } from "../src/transport.js";
import { createKerdly } from "../src/index.js";
import { blobText, removeBeacon, resetPage, stubBeacon } from "./helpers.js";

const URL_ = "https://go.acme-app.com/v1/web/touch";
const BODY = '{"key":"wk_live_example","kind":"visit"}';

function stubFetch(result: Promise<unknown> = Promise.resolve(new Response(null, { status: 204 }))) {
  const fetchMock = vi.fn((_url: string, _init?: RequestInit) => result);
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

beforeEach(() => {
  resetPage();
  removeBeacon();
});

describe("endpointUrl", () => {
  it("appends the path to the endpoint", () => {
    expect(endpointUrl("https://go.acme-app.com", TOUCH_PATH)).toBe(URL_);
    expect(endpointUrl("https://go.acme-app.com//", TOUCH_PATH)).toBe(URL_);
    expect(endpointUrl("https://app.kerdly.com/api", TOUCH_PATH)).toBe(
      "https://app.kerdly.com/api/v1/web/touch",
    );
    expect(endpointUrl("https://go.acme-app.com/", IDENTIFY_PATH)).toBe("https://go.acme-app.com/v1/web/identify");
  });
});

describe("post", () => {
  it("uses sendBeacon with a text/plain Blob when the browser queues it", async () => {
    const beacon = stubBeacon(true);
    const fetchMock = stubFetch();
    expect(post(URL_, BODY)).toBe("beacon");
    expect(beacon).toHaveBeenCalledOnce();
    const [url, data] = beacon.mock.calls[0] ?? [];
    expect(url).toBe(URL_);
    expect(data).toBeInstanceOf(Blob);
    // Blob types are lowercased by the platform; the charset value itself is case-insensitive.
    expect((data as Blob).type).toBe(BODY_CONTENT_TYPE.toLowerCase());
    expect(await blobText(data)).toBe(BODY);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("falls back to a keepalive no-cors fetch when sendBeacon refuses", () => {
    stubBeacon(false);
    const fetchMock = stubFetch();
    expect(post(URL_, BODY)).toBe("fetch");
    expect(fetchMock).toHaveBeenCalledWith(URL_, {
      method: "POST",
      body: BODY,
      keepalive: true,
      headers: { "Content-Type": "text/plain;charset=UTF-8" },
      mode: "no-cors",
    });
  });

  it("falls back to fetch when there is no sendBeacon", () => {
    const fetchMock = stubFetch();
    expect(post(URL_, BODY)).toBe("fetch");
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it("falls back to fetch when sendBeacon throws", () => {
    stubBeacon(() => {
      throw new TypeError("Refused by CSP");
    });
    const fetchMock = stubFetch();
    expect(post(URL_, BODY)).toBe("fetch");
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it("swallows a failing fetch", async () => {
    const unhandled = vi.fn();
    process.on("unhandledRejection", unhandled);
    try {
      stubFetch(Promise.reject(new TypeError("Failed to fetch")));
      expect(post(URL_, BODY)).toBe("fetch");
      await new Promise((resolve) => setTimeout(resolve, 10));
      expect(unhandled).not.toHaveBeenCalled();
    } finally {
      process.off("unhandledRejection", unhandled);
    }
  });

  it("gives up quietly with neither beacon nor fetch", () => {
    vi.stubGlobal("fetch", undefined);
    expect(post(URL_, BODY)).toBe("none");
  });

  it("sends the key only in the body", () => {
    stubBeacon(false);
    const fetchMock = stubFetch();
    // No IPv6 lookup, so the one fetch is the touch.
    createKerdly({ key: "wk_live_example", endpoint: "https://go.acme-app.com", autoDecorate: false, ipv6EchoUrl: null });
    expect(fetchMock).toHaveBeenCalledOnce();
    const [url, init] = fetchMock.mock.calls[0] ?? [];
    expect(url).toBe(URL_);
    expect(init?.headers).toEqual({ "Content-Type": "text/plain;charset=UTF-8" });
    expect(JSON.parse(String(init?.body)).key).toBe("wk_live_example");
  });
});
