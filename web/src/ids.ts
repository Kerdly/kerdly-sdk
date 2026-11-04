/**
 * Random ids: the visitor id and the per-touch event id.
 */

/**
 * Crockford base32 in lowercase: `0-9a-z` without `i l o u`. The alphabet of link codes and click
 * ids, so every id the platform mints survives case-folding and reading aloud.
 */
export const BASE32_ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz";

/** 22 characters of base32 = 110 random bits. */
export const VISITOR_ID_LENGTH = 22;

/** The parts of Web Crypto the SDK uses; `randomUUID` exists only in secure contexts. */
export interface RandomSource {
  getRandomValues?(array: Uint8Array<ArrayBuffer>): Uint8Array<ArrayBuffer>;
  randomUUID?(): string;
}

function webCrypto(): RandomSource | undefined {
  return typeof crypto === "undefined" ? undefined : crypto;
}

/** `n` random bytes from `getRandomValues`; `Math.random` only where Web Crypto is missing. */
export function randomBytes(n: number, source: RandomSource | undefined = webCrypto()): Uint8Array<ArrayBuffer> {
  const bytes = new Uint8Array(n);
  if (source && typeof source.getRandomValues === "function") {
    source.getRandomValues(bytes);
  } else {
    for (let i = 0; i < n; i++) bytes[i] = Math.floor(Math.random() * 256);
  }
  return bytes;
}

/** A new visitor id: 22 characters of lowercase base32. 256 is a multiple of 32, so `byte & 31` is uniform. */
export function newVisitorId(source: RandomSource | undefined = webCrypto()): string {
  const bytes = randomBytes(VISITOR_ID_LENGTH, source);
  let id = "";
  for (let i = 0; i < bytes.length; i++) id += BASE32_ALPHABET.charAt(bytes[i] & 31);
  return id;
}

/** A lowercase UUIDv4: `crypto.randomUUID` when available, else built from `getRandomValues`. */
export function uuidv4(source: RandomSource | undefined = webCrypto()): string {
  if (source && typeof source.randomUUID === "function") return source.randomUUID();
  const b = randomBytes(16, source);
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // RFC 4122 variant
  let hex = "";
  for (let i = 0; i < 16; i++) hex += (b[i] + 0x100).toString(16).slice(1);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
