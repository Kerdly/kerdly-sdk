/**
 * Every test starts offline: `createKerdly` starts the IPv6 lookup (src/ipv6.ts) with `fetch`, and Node
 * has a real one. A test that needs fetch stubs its own; `unstubGlobals` restores this one after it.
 */
import { beforeEach, vi } from "vitest";

beforeEach(() => {
  vi.stubGlobal(
    "fetch",
    vi.fn(() => Promise.reject(new TypeError("Failed to fetch: tests are offline"))),
  );
});
