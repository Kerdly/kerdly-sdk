#!/usr/bin/env node
// Each SDK has its own version. This script reads, checks or sets them.
//
//   node scripts/version.mjs                  print each SDK's version (fails if an SDK's files disagree)
//   node scripts/version.mjs web 0.2.0        set the web SDK's version and open its CHANGELOG section
//
// The Expo package carries the iOS and Android SDKs, so a change to either is also an Expo change
// to release. See release-plan.mjs for what is unreleased.
import fs from 'node:fs';
import path from 'node:path';
import { ROOT, SDKS, SEMVER, versionOf, writeVersion } from './sdks.mjs';
import { lastReleaseTag, shippedCommits } from './release-plan.mjs';

const [sdk, version] = process.argv.slice(2);

if (!sdk) {
  let failed = false;
  for (const name of Object.keys(SDKS)) {
    try {
      console.log(`${name.padEnd(8)} ${versionOf(name)}`);
    } catch (e) {
      console.error(e.message);
      failed = true;
    }
  }
  process.exit(failed ? 1 : 0);
}

if (!SDKS[sdk]) throw new Error(`unknown SDK ${sdk}; one of ${Object.keys(SDKS).join(', ')}`);
if (!SEMVER.test(version || '')) throw new Error(`not a version: ${version}`);

writeVersion(sdk, version);
console.log(`${sdk} ${version}`);

// A `## <version>` section at the top of the SDK's changelog, listing the commits since its last
// release that changed what it ships. Edit it into release notes before merging.
const file = path.join(ROOT, SDKS[sdk].changelog);
const text = fs.readFileSync(file, 'utf8');
if (!text.includes(`\n## ${version}\n`)) {
  const subjects = [...new Set(shippedCommits(sdk, lastReleaseTag(sdk)))];
  if (sdk === 'expo') subjects.unshift(`Contains iOS SDK ${versionOf('ios')} and Android SDK ${versionOf('android')}.`);
  const section = `## ${version}\n\n${(subjects.length ? subjects : ['…']).map((s) => `- ${s}`).join('\n')}\n\n`;
  const at = text.indexOf('\n## ');
  fs.writeFileSync(file, at === -1 ? `${text.trimEnd()}\n\n${section}` : `${text.slice(0, at + 1)}${section}${text.slice(at + 1)}`);
  console.log(`${SDKS[sdk].changelog}: added "## ${version}"; edit it before merging`);
}

