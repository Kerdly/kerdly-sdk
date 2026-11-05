// Which kerdly.js each cdn.kerdly.com path serves. Pure functions, tested in versions.test.mjs.
import { createHash } from "node:crypto";

const VERSION = /^(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?$/;

/** A published version as path-safe parts, or null for anything that is not plain semver. */
export function parseVersion(version) {
  const m = VERSION.exec(version);
  if (!m) return null;
  return { major: Number(m[1]), minor: Number(m[2]), patch: Number(m[3]), prerelease: Boolean(m[4]) };
}

/**
 * The evergreen path a version belongs to. `/v1/` is the first generation of the snippet's API and
 * holds every 0.x and 1.x release; a release that breaks compatibility starts `/v2/` (major 2).
 */
export function generation(version) {
  const v = parseVersion(version);
  return v ? `v${Math.max(1, v.major)}` : null;
}

function compare(a, b) {
  const x = parseVersion(a);
  const y = parseVersion(b);
  return x.major - y.major || x.minor - y.minor || x.patch - y.patch;
}

/**
 * For each generation, the newest release it serves: stable (no `-pre`) and not deprecated on npm.
 * Deprecating a release on npm and deploying again moves its generation back to the one before.
 */
export function latestByGeneration(releases) {
  const out = {};
  for (const { version, deprecated } of releases) {
    const v = parseVersion(version);
    if (!v || v.prerelease || deprecated) continue;
    const gen = generation(version);
    if (!out[gen] || compare(version, out[gen]) > 0) out[gen] = version;
  }
  return out;
}

/** The `integrity` attribute value for a file. */
export function sri(content) {
  return `sha384-${createHash("sha384").update(content).digest("base64")}`;
}

/** Whether a tarball's bytes match npm's `dist.integrity` (`sha512-…`). */
export function matchesIntegrity(content, integrity) {
  const [algo, expected] = String(integrity || "").split("-", 2);
  if (!["sha512", "sha384", "sha256"].includes(algo) || !expected) return false;
  return createHash(algo).update(content).digest("base64") === expected;
}
