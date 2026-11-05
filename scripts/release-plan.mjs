#!/usr/bin/env node
// Which SDKs to release: those whose version has no release tag yet. Needs the full git history
// and tags (`fetch-depth: 0` in CI).
//
//   node scripts/release-plan.mjs            each SDK's version, last release and unreleased changes
//   node scripts/release-plan.mjs --check    fail on a new version that changes nothing its SDK ships,
//                                            or that is not above the SDK's last release (CI)
//   node scripts/release-plan.mjs --github   the same check, then `<sdk>=true|false`, `<sdk>_version`
//                                            and `<sdk>_tag` for each SDK into $GITHUB_OUTPUT
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { ROOT, SDKS, compareVersions, plan, ships, versionOf, versionOnly } from './sdks.mjs';

const git = (...args) => execFileSync('git', args, { cwd: ROOT, encoding: 'utf8', maxBuffer: 1 << 26 });

export const allTags = () => git('tag', '--list').split('\n').filter(Boolean);

/** The SDK's newest release tag, or null before its first release. */
export function lastReleaseTag(sdk, tags = allTags()) {
  const versions = tags.map((t) => SDKS[sdk].versionOf(t)).filter(Boolean).sort(compareVersions);
  return versions.length ? SDKS[sdk].tag(versions.at(-1)) : null;
}

/**
 * Files changed since `tag`, uncommitted changes included, leaving out those where only a version
 * number changed (a version bump is not a change to release); null when there is no tag.
 */
export function changedSince(tag) {
  if (!tag) return null;
  return git('diff', '--name-only', tag).split('\n').filter(Boolean).filter((file) => {
    const now = path.join(ROOT, file);
    if (!fs.existsSync(now)) return true;
    let before = null;
    try { before = git('show', `${tag}:${file}`); } catch { return true; }
    return !versionOnly(file, before, fs.readFileSync(now, 'utf8'));
  });
}

/** Subjects of the commits since `tag` (all history when null) that changed what `sdk` ships. */
export function shippedCommits(sdk, tag) {
  const log = git('log', '--format=@@%s', '--name-only', ...(tag ? [`${tag}..HEAD`] : ['HEAD']), '--', ...SDKS[sdk].paths);
  return log.split('@@').filter(Boolean).flatMap((entry) => {
    const [subject, ...files] = entry.split('\n').filter(Boolean);
    return files.some((f) => ships(sdk, f)) ? [subject] : [];
  });
}

export function planAll() {
  const tags = allTags();
  return Object.keys(SDKS).map((sdk) => {
    const last = lastReleaseTag(sdk, tags);
    return { sdk, ...plan(sdk, { version: versionOf(sdk), tags, changedSinceLast: changedSince(last) }) };
  });
}

function nextPatch(version) {
  const [major, minor, patch] = version.split('-')[0].split('.').map(Number);
  return `${major}.${minor}.${patch + 1}`;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const mode = process.argv[2];
  const plans = planAll();
  const errors = plans.filter((p) => p.error);

  if (mode === '--github') {
    if (!errors.length) {
      const lines = plans.flatMap((p) => [`${p.sdk}=${Boolean(p.release)}`, `${p.sdk}_version=${p.version}`, `${p.sdk}_tag=${p.release ? p.tag : ''}`]);
      fs.appendFileSync(process.env.GITHUB_OUTPUT, `${lines.join('\n')}\n`);
    }
  }
  for (const p of plans) {
    if (p.error) console.error(`${p.sdk.padEnd(8)} ${p.error}`);
    else if (p.release) console.log(`${p.sdk.padEnd(8)} ${p.version}: releases as ${p.tag} on main${p.last ? ` (last ${p.last}, ${p.changes.length} shipped files changed)` : ' (first release)'}`);
    else if (p.pending.length) console.log(`${p.sdk.padEnd(8)} ${p.version}: released; ${p.pending.length} shipped files changed since. To release them: node scripts/version.mjs ${p.sdk} ${nextPatch(p.version)}`);
    else console.log(`${p.sdk.padEnd(8)} ${p.version}: released, nothing new`);
  }
  if (errors.length && mode) process.exit(1);
}
