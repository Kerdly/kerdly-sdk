// Builds cdn/public, the files cdn.kerdly.com serves, from the @kerdly/web releases on npm:
//
//   /<version>/kerdly.js   every release, unchanged forever (cached for a year)
//   /v1/kerdly.js          the newest stable, non-deprecated release of that generation (5 minutes)
//   /versions.json         those mappings, with each file's `integrity` value
//
// npm is the source of truth: its releases are immutable and carry provenance, so every deploy
// rebuilds all paths from it and an old release never disappears from the CDN.
//
//   node cdn/build.mjs --expect 0.2.0   fail unless 0.2.0 is on npm (waits up to 10 minutes for it)
//   node cdn/build.mjs --local          also serve web/dist/kerdly.js as its package.json version
//                                       when npm does not have it yet (a preview before publishing)
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { latestByGeneration, matchesIntegrity, parseVersion, sri } from "./versions.mjs";

const PACKAGE = "@kerdly/web";
const REGISTRY = "https://registry.npmjs.org";
const root = dirname(fileURLToPath(import.meta.url));
const out = join(root, "public");
const args = process.argv.slice(2);
const expect = args.includes("--expect") ? args[args.indexOf("--expect") + 1] : null;
const local = args.includes("--local");

async function registryDocument() {
  for (let attempt = 1; ; attempt++) {
    const res = await fetch(`${REGISTRY}/${PACKAGE.replace("/", "%2F")}`, { headers: { accept: "application/json" } });
    const doc = res.status === 404 ? { versions: {} } : res.ok ? await res.json() : null;
    if (!doc) throw new Error(`npm registry: HTTP ${res.status}`);
    if (!expect || doc.versions?.[expect] || attempt >= 40) return doc;
    console.log(`${PACKAGE}@${expect} is not on npm yet; retrying in 15 s`);
    await new Promise((r) => setTimeout(r, 15_000));
  }
}

/**
 * `package/dist/kerdly.js` out of a release's tarball, after checking the tarball's integrity; null
 * when the tarball has none (npm's `0.0.0-stage` placeholder for staged publishing, for one).
 */
async function snippetOf(version, dist) {
  const res = await fetch(dist.tarball);
  if (!res.ok) throw new Error(`${version}: tarball HTTP ${res.status}`);
  const tarball = Buffer.from(await res.arrayBuffer());
  if (!matchesIntegrity(tarball, dist.integrity)) throw new Error(`${version}: tarball does not match npm's integrity`);
  const tar = spawnSync("tar", ["-xzO", "-f", "-", "package/dist/kerdly.js"], { input: tarball, maxBuffer: 1 << 24 });
  return tar.status === 0 && tar.stdout.length ? tar.stdout : null;
}

const doc = await registryDocument();
if (expect && !doc.versions?.[expect]) throw new Error(`${PACKAGE}@${expect} is not on npm`);

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

const releases = [];
const files = {};
for (const [version, meta] of Object.entries(doc.versions ?? {})) {
  if (!parseVersion(version)) continue;
  const body = await snippetOf(version, meta.dist);
  if (!body) {
    if (version === expect) throw new Error(`${version}: no dist/kerdly.js in the tarball`);
    console.log(`${version}: no dist/kerdly.js in the tarball; not served`);
    continue;
  }
  mkdirSync(join(out, version));
  writeFileSync(join(out, version, "kerdly.js"), body);
  releases.push({ version, deprecated: meta.deprecated });
  files[version] = { integrity: sri(body), ...(meta.deprecated ? { deprecated: true } : {}) };
}

if (local) {
  const version = JSON.parse(readFileSync(join(root, "../web/package.json"), "utf8")).version;
  if (!files[version]) {
    const body = readFileSync(join(root, "../web/dist/kerdly.js"));
    mkdirSync(join(out, version));
    writeFileSync(join(out, version, "kerdly.js"), body);
    releases.push({ version });
    files[version] = { integrity: sri(body), local: true };
  }
}

const latest = latestByGeneration(releases);
for (const [gen, version] of Object.entries(latest)) {
  mkdirSync(join(out, gen));
  copyFileSync(join(out, version, "kerdly.js"), join(out, gen, "kerdly.js"));
}
writeFileSync(join(out, "versions.json"), `${JSON.stringify({ latest, versions: files }, null, 2)}\n`);
writeFileSync(join(out, "robots.txt"), "User-agent: *\nDisallow: /\n");
writeFileSync(join(out, "404.html"), "Not found\n");

console.log(`cdn/public: ${Object.keys(files).length} release(s); ${Object.entries(latest).map(([g, v]) => `/${g}/ → ${v}`).join(", ") || "no stable release yet"}`);
