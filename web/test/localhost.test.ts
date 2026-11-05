// @vitest-environment-options {"url": "http://localhost:3000/lp?fbclid=IwAR0abc"}
import { beforeEach, describe, expect, it } from "vitest";
import { createKerdly } from "../src/index.js";
import { recordCookieWrites, resetPage } from "./helpers.js";

beforeEach(() => resetPage("/lp?fbclid=IwAR0abc"));

describe("local development (http://localhost)", () => {
  it("writes host-only cookies without Secure", () => {
    const writes = recordCookieWrites();
    const kerdly = createKerdly({ key: "wk_test_local", endpoint: "http://localhost:3000/api", autoDecorate: false });
    const vid = kerdly.visitorId();
    expect(writes).toContain(`kerdly_vid=${vid}; Max-Age=34560000; Path=/; SameSite=Lax`);
    expect(writes.some((w) => w.startsWith("_fbc=fb.1.") && w.endsWith("; Max-Age=7776000; Path=/; SameSite=Lax"))).toBe(true);
    expect(writes.join("\n")).not.toMatch(/Domain=|Secure/);
  });

  it("uses an explicit cookieDomain the browser refuses only after trying it", () => {
    const writes = recordCookieWrites();
    const vid = createKerdly({
      key: "wk_test_local",
      endpoint: "http://localhost:3000/api",
      cookieDomain: ".acme-app.com",
      autoVisit: false,
      autoDecorate: false,
    }).visitorId();
    expect(writes).toEqual([
      `kerdly_vid=${vid}; Max-Age=34560000; Path=/; Domain=.acme-app.com; SameSite=Lax`,
      `kerdly_vid=${vid}; Max-Age=34560000; Path=/; SameSite=Lax`,
    ]);
  });
});
