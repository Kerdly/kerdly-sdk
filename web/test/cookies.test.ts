import { beforeEach, describe, expect, it } from "vitest";
import { cookieLine, readCookie, registrableDomain, writeCookie } from "../src/cookies.js";
import { recordCookieWrites, resetPage } from "./helpers.js";

describe("readCookie", () => {
  it("reads one cookie out of a cookie string, as written", () => {
    expect(readCookie("a=1; afr_vid=q3k9m2x7a8b4c5d6e7f8g9; b=2", "afr_vid")).toBe("q3k9m2x7a8b4c5d6e7f8g9");
    expect(readCookie("x_afr_vid=1; afr_vid_x=2", "afr_vid")).toBeUndefined();
    expect(readCookie("v=a%3Db", "v")).toBe("a%3Db");
    expect(readCookie("", "v")).toBeUndefined();
    expect(readCookie(undefined, "v")).toBeUndefined();
  });

  it("skips an empty value in favour of a later copy", () => {
    expect(readCookie("v=; v=2", "v")).toBe("2");
    expect(readCookie("v=", "v")).toBeUndefined();
  });
});

describe("registrableDomain", () => {
  it.each([
    ["example.com", ".example.com"],
    ["www.example.com", ".example.com"],
    ["a.b.example.com", ".example.com"],
    ["acme-app.com", ".acme-app.com"],
    ["go.acme-app.com", ".acme-app.com"],
    ["WWW.Example.COM", ".example.com"],
    ["www.example.com.", ".example.com"],
    ["shop.co.uk", ".shop.co.uk"],
    ["www.shop.co.uk", ".shop.co.uk"],
    ["a.b.shop.com.au", ".shop.com.au"],
    ["loja.com.br", ".loja.com.br"],
    ["m.site.co.jp", ".site.co.jp"],
  ])("%s → %s", (host, expected) => {
    expect(registrableDomain(host)).toBe(expected);
  });

  it.each([
    "localhost",
    "app.localhost",
    "127.0.0.1",
    "10.0.0.12",
    "[::1]",
    "::1",
    "intranet",
    "co.uk",
    "",
  ])("%s → host-only", (host) => {
    expect(registrableDomain(host)).toBeUndefined();
  });

  it("answers the bare suffix for a two-label suffix it does not know (the write falls back to host-only)", () => {
    expect(registrableDomain("myproj.vercel.app")).toBe(".vercel.app");
    expect(registrableDomain("x.co.ke")).toBe(".co.ke");
  });
});

describe("cookieLine", () => {
  it("writes Max-Age, Path, Domain, SameSite and Secure", () => {
    expect(cookieLine("afr_vid", "abc", 34560000, ".acme-app.com", true)).toBe(
      "afr_vid=abc; Max-Age=34560000; Path=/; Domain=.acme-app.com; SameSite=Lax; Secure",
    );
    expect(cookieLine("afr_vid", "abc", 10, undefined, false)).toBe("afr_vid=abc; Max-Age=10; Path=/; SameSite=Lax");
  });
});

describe("writeCookie", () => {
  beforeEach(() => resetPage());

  it("stores the cookie on the domain asked for", () => {
    const writes = recordCookieWrites();
    expect(writeCookie("v", "1", 60, ".acme-app.com", true)).toBe(true);
    expect(writes).toEqual(["v=1; Max-Age=60; Path=/; Domain=.acme-app.com; SameSite=Lax; Secure"]);
    expect(readCookie(document.cookie, "v")).toBe("1");
  });

  it("falls back to a host-only cookie when the browser refuses the domain", () => {
    const writes = recordCookieWrites();
    expect(writeCookie("v", "2", 60, ".other.com", true)).toBe(true);
    expect(writes).toEqual([
      "v=2; Max-Age=60; Path=/; Domain=.other.com; SameSite=Lax; Secure",
      "v=2; Max-Age=60; Path=/; SameSite=Lax; Secure",
    ]);
    expect(readCookie(document.cookie, "v")).toBe("2");
  });

  it("falls back the same way for a public suffix", () => {
    expect(writeCookie("v", "3", 60, ".us", true)).toBe(true);
    expect(readCookie(document.cookie, "v")).toBe("3");
  });
});
