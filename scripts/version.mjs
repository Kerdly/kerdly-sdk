#!/usr/bin/env node
// All four SDKs release together under one version (the git tag, e.g. `0.2.0`, is what SwiftPM
// resolves). This script reads, checks or sets that version everywhere it is written.
//
//   node scripts/version.mjs              print the version (fails if the files disagree)
//   node scripts/version.mjs --check X    fail unless every file says X (CI, on a release tag)
//   node scripts/version.mjs --set X      write X into every file
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SEMVER = /^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/;

const json = (file, keys) => ({
  file,
  get: (text) => keys.map((k) => k.split('.').reduce((o, p) => o?.[p], JSON.parse(text))),
  set: (text, v) => {
    const j = JSON.parse(text);
    for (const k of keys) {
      const parts = k.split('.');
      const last = parts.pop();
      parts.reduce((o, p) => o[p], j)[last] = v;
    }
    return JSON.stringify(j, null, 2) + '\n';
  },
});
const regex = (file, re) => ({
  file,
  get: (text) => [text.match(re)?.[2]],
  set: (text, v) => text.replace(re, (_, a, _old, b) => `${a}${v}${b}`),
});

const FILES = [
  json('web/package.json', ['version']),
  json('web/package-lock.json', ['version', 'packages..version']),
  json('expo/package.json', ['version']),
  json('expo/package-lock.json', ['version', 'packages..version']),
  regex('expo/src/version.ts', /(SDK_VERSION = ')([^']+)(')/),
  regex('android/gradle.properties', /(KERDLY_VERSION=)(\S+)()/),
  regex('KerdlySDK.podspec', /(s\.version\s*=\s*')([^']+)(')/),
  regex('ios/Sources/KerdlySDK/Core/KerdlyCore.swift', /(static let sdkVersion = ")([^"]+)(")/),
];
// `packages..version` is the lockfile's root package (key "").
for (const f of FILES) if (f.file.endsWith('lock.json')) {
  f.get = (text) => { const j = JSON.parse(text); return [j.version, j.packages?.['']?.version]; };
  f.set = (text, v) => { const j = JSON.parse(text); j.version = v; j.packages[''].version = v; return JSON.stringify(j, null, 2) + '\n'; };
}

const read = (f) => fs.readFileSync(path.join(ROOT, f.file), 'utf8');
const found = FILES.flatMap((f) => f.get(read(f)).map((v) => [f.file, v]));

const [flag, value] = process.argv.slice(2);
if (flag === '--set') {
  if (!SEMVER.test(value || '')) throw new Error(`not a version: ${value}`);
  for (const f of FILES) fs.writeFileSync(path.join(ROOT, f.file), f.set(read(f), value));
  console.log(`version ${value} written to ${FILES.length} files`);
} else {
  const want = flag === '--check' ? value : found[0][1];
  const bad = found.filter(([, v]) => v !== want);
  if (bad.length) {
    for (const [file, v] of bad) console.error(`${file}: ${v} (expected ${want})`);
    process.exit(1);
  }
  console.log(want);
}
