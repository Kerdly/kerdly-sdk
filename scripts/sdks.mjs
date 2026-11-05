// The four SDKs, each released on its own version. Shared by version.mjs and release-plan.mjs.
//
// A release is tagged in this repository: iOS with the bare version (`0.2.0`, what SwiftPM and
// CocoaPods resolve), the others with their name (`web-v0.2.0`, `expo-v0.2.0`, `android-v0.2.0`).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const SEMVER = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/;

const json = (file) => ({
  file,
  get: (text) => [JSON.parse(text).version],
  set: (text, v) => JSON.stringify({ ...JSON.parse(text), version: v }, null, 2) + '\n',
});
// A lockfile names the version twice: at the top and for its root package (key "").
const lock = (file) => ({
  file,
  get: (text) => { const j = JSON.parse(text); return [j.version, j.packages?.['']?.version]; },
  set: (text, v) => { const j = JSON.parse(text); j.version = v; j.packages[''].version = v; return JSON.stringify(j, null, 2) + '\n'; },
});
const regex = (file, re) => ({
  file,
  get: (text) => [text.match(re)?.[2]],
  set: (text, v) => text.replace(re, (_, a, _old, b) => `${a}${v}${b}`),
});

/** Not part of what an SDK ships: tests, docs, dotfiles (the Expo sync stamp too) and test config. */
const NOT_SHIPPED = [/(^|\/)(test|Tests|androidTest)\//, /\.md$/, /(^|\/)\.[^/]+$/, /(^|\/)(jest|vitest)\.config\.[cm]?[jt]s$/, /(^|\/)tsconfig\.jest\.json$/];

export const SDKS = {
  ios: {
    title: 'iOS SDK',
    tag: (v) => v,
    versionOf: (tag) => (SEMVER.test(tag) ? tag : null),
    changelog: 'ios/CHANGELOG.md',
    paths: ['ios/Sources/', 'Package.swift', 'KerdlySDK.podspec'],
    files: [
      regex('KerdlySDK.podspec', /(s\.version\s*=\s*')([^']+)(')/),
      regex('ios/Sources/KerdlySDK/Core/KerdlyCore.swift', /(static let sdkVersion = ")([^"]+)(")/),
      regex('ios/README.md', /(upToNextMinor\(from: ")([^"]+)(")/),
      regex('ios/README.md', /(pod 'KerdlySDK', '~> )([^']+)(')/),
    ],
  },
  android: {
    title: 'Android SDK',
    tag: (v) => `android-v${v}`,
    versionOf: (tag) => prefixed('android-v', tag),
    changelog: 'android/CHANGELOG.md',
    paths: ['android/'],
    files: [
      regex('android/gradle.properties', /(KERDLY_VERSION=)(\S+)()/),
      regex('android/README.md', /(com\.kerdly:kerdly-sdk:)([^"]+)(")/),
      regex('README.md', /(com\.kerdly:kerdly-sdk:)([^"]+)(")/),
    ],
  },
  web: {
    title: 'Web SDK',
    tag: (v) => `web-v${v}`,
    versionOf: (tag) => prefixed('web-v', tag),
    changelog: 'web/CHANGELOG.md',
    paths: ['web/'],
    files: [
      json('web/package.json'),
      lock('web/package-lock.json'),
      regex('web/README.md', /(cdn\.kerdly\.com\/)(\d[^/]*)(\/kerdly\.js)/),
    ],
  },
  expo: {
    title: 'Expo SDK',
    tag: (v) => `expo-v${v}`,
    versionOf: (tag) => prefixed('expo-v', tag),
    changelog: 'expo/CHANGELOG.md',
    // The package carries the iOS and Android SDK sources, copied in when it is packed.
    paths: ['expo/', 'ios/Sources/', 'android/kerdly-sdk/src/main/', 'android/kerdly-sdk/consumer-rules.pro', 'android/gradle.properties'],
    files: [
      json('expo/package.json'),
      lock('expo/package-lock.json'),
      regex('expo/src/version.ts', /(SDK_VERSION = ')([^']+)(')/),
    ],
  },
};

/** True when `file` changed from `before` to `after` in nothing but a version number. */
export function versionOnly(file, before, after) {
  const targets = Object.values(SDKS).flatMap((s) => s.files).filter((t) => t.file === file);
  if (!targets.length || before == null || after == null) return false;
  try {
    const normalize = (text) => targets.reduce((t, f) => f.set(t, '0.0.0-any'), text);
    return normalize(before) === normalize(after);
  } catch {
    return false;
  }
}

function prefixed(prefix, tag) {
  if (!tag.startsWith(prefix)) return null;
  const v = tag.slice(prefix.length);
  return SEMVER.test(v) ? v : null;
}

/**
 * The SDKs that may be released, from the RELEASES_ENABLED repository variable: `true` or `all` for
 * every SDK, a list such as `web` or `web, expo`, and nothing when empty or `false`.
 */
export function enabledSdks(value) {
  const words = String(value ?? '').toLowerCase().split(/[\s,]+/).filter(Boolean);
  if (words.includes('true') || words.includes('all')) return Object.keys(SDKS);
  const names = words.filter((w) => w !== 'false' && w !== 'none');
  const unknown = names.filter((w) => !SDKS[w]);
  if (unknown.length) throw new Error(`RELEASES_ENABLED: unknown SDK ${unknown.join(', ')}; use ${Object.keys(SDKS).join(', ')} or all`);
  return names;
}

/** True when a change to `file` (repo-relative) changes what `sdk` ships. */
export function ships(sdk, file) {
  return SDKS[sdk].paths.some((p) => (p.endsWith('/') ? file.startsWith(p) : file === p))
    && !NOT_SHIPPED.some((re) => re.test(file));
}

/** Semantic version order; a pre-release sorts before its release. */
export function compareVersions(a, b) {
  const [, ...pa] = a.match(SEMVER);
  const [, ...pb] = b.match(SEMVER);
  for (let i = 0; i < 3; i++) if (Number(pa[i]) !== Number(pb[i])) return Number(pa[i]) - Number(pb[i]);
  if (!pa[3] || !pb[3]) return (pa[3] ? -1 : 0) - (pb[3] ? -1 : 0);
  const xa = pa[3].split('.');
  const xb = pb[3].split('.');
  for (let i = 0; i < Math.max(xa.length, xb.length); i++) {
    if (xa[i] === undefined) return -1;
    if (xb[i] === undefined) return 1;
    const na = /^\d+$/.test(xa[i]);
    const nb = /^\d+$/.test(xb[i]);
    if (na && nb && Number(xa[i]) !== Number(xb[i])) return Number(xa[i]) - Number(xb[i]);
    if (na !== nb) return na ? -1 : 1;
    if (xa[i] !== xb[i]) return xa[i] < xb[i] ? -1 : 1;
  }
  return 0;
}

const read = (file) => fs.readFileSync(path.join(ROOT, file), 'utf8');

/** Every place `sdk` writes its version, as [file, version] pairs. */
export function versionsIn(sdk) {
  return SDKS[sdk].files.flatMap((f) => f.get(read(f.file)).map((v) => [f.file, v]));
}

/** The SDK's version; throws when its files disagree. */
export function versionOf(sdk) {
  const found = versionsIn(sdk);
  const want = found[0][1];
  const bad = found.filter(([, v]) => v !== want);
  if (bad.length) throw new Error(`${sdk}: ${bad.map(([f, v]) => `${f} says ${v}`).join(', ')}; ${found[0][0]} says ${want}`);
  return want;
}

export function writeVersion(sdk, version) {
  for (const f of SDKS[sdk].files) fs.writeFileSync(path.join(ROOT, f.file), f.set(read(f.file), version));
}

/**
 * What to do with one SDK, from its current version, its release tags and the files changed since
 * the newest of them:
 *   { release: true }                        the version has no tag yet: publish it
 *   { release: false, pending: [files] }     released; `pending` lists shipped changes since
 *   { error }                                a new version that is not above the last release, or
 *                                            that changes nothing the SDK ships
 */
export function plan(sdk, { version, tags, changedSinceLast }) {
  const releases = tags.map((t) => SDKS[sdk].versionOf(t)).filter(Boolean).sort(compareVersions);
  const last = releases.at(-1) ?? null;
  const shipped = (changedSinceLast ?? []).filter((f) => ships(sdk, f));
  if (releases.includes(version)) return { release: false, version, last, pending: version === last ? shipped : [] };
  if (last && compareVersions(version, last) <= 0) {
    return { error: `${sdk} ${version} is not above its last release ${last}`, version, last };
  }
  if (last && shipped.length === 0) {
    return { error: `${sdk} ${version}: nothing the ${SDKS[sdk].title} ships changed since ${SDKS[sdk].tag(last)}`, version, last };
  }
  return { release: true, version, last, tag: SDKS[sdk].tag(version), changes: shipped };
}
