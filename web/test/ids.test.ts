import { describe, expect, it, vi } from "vitest";
import { BASE32_ALPHABET, VISITOR_ID_LENGTH, newVisitorId, uuidv4 } from "../src/ids.js";

const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

describe("newVisitorId", () => {
  it("is 22 characters of lowercase Crockford base32", () => {
    expect(BASE32_ALPHABET).toHaveLength(32);
    expect(BASE32_ALPHABET).not.toMatch(/[ilou]/);
    for (let i = 0; i < 200; i++) {
      const id = newVisitorId();
      expect(id).toHaveLength(VISITOR_ID_LENGTH);
      expect(id).toMatch(/^[0-9abcdefghjkmnpqrstvwxyz]{22}$/);
    }
  });

  it("draws from crypto.getRandomValues", () => {
    const getRandomValues = vi.fn((array: Uint8Array<ArrayBuffer>) => array.fill(33)); // 33 & 31 = 1
    expect(newVisitorId({ getRandomValues })).toBe("1".repeat(22));
    expect(getRandomValues).toHaveBeenCalledOnce();
  });

  it("does not repeat", () => {
    const ids = new Set(Array.from({ length: 1000 }, () => newVisitorId()));
    expect(ids.size).toBe(1000);
  });

  it("still works without Web Crypto", () => {
    expect(newVisitorId({})).toMatch(/^[0-9a-z]{22}$/);
  });
});

describe("uuidv4", () => {
  it("uses crypto.randomUUID when there is one", () => {
    const randomUUID = vi.fn(() => "b7c8d9e0-f1a2-4b3c-8d4e-5f6a7b8c9d0e");
    expect(uuidv4({ randomUUID })).toBe("b7c8d9e0-f1a2-4b3c-8d4e-5f6a7b8c9d0e");
  });

  it("builds a v4 UUID from getRandomValues where randomUUID is missing (insecure contexts)", () => {
    const getRandomValues = (array: Uint8Array<ArrayBuffer>) => array.fill(0xff);
    expect(uuidv4({ getRandomValues })).toBe("ffffffff-ffff-4fff-bfff-ffffffffffff");
    for (let i = 0; i < 200; i++) {
      expect(uuidv4({ getRandomValues: (array) => crypto.getRandomValues(array) })).toMatch(UUID_V4);
    }
  });

  it("is a lowercase v4 UUID from the platform", () => {
    expect(uuidv4()).toMatch(UUID_V4);
  });
});
