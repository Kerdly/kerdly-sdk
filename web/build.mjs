// Builds dist/index.mjs (the ESM library) and dist/kerdly.js (the minified snippet), then checks the
// snippet's gzipped size. Type declarations come from `tsc -p tsconfig.build.json` (npm run build).
import { build } from "esbuild";
import { readFileSync, rmSync } from "node:fs";
import { gzipSync } from "node:zlib";

/** The snippet must stay small enough to load on every landing page. */
const SNIPPET_GZIP_BUDGET = 6 * 1024;

/** Browsers the output must parse in: every in-app browser and phone browser still in use. */
const TARGET = ["es2018"];

rmSync("dist", { recursive: true, force: true });

await build({
  entryPoints: ["src/index.ts"],
  outfile: "dist/index.mjs",
  bundle: true,
  format: "esm",
  platform: "browser",
  target: TARGET,
  legalComments: "none",
  logLevel: "warning",
});

await build({
  entryPoints: ["src/snippet.ts"],
  outfile: "dist/kerdly.js",
  bundle: true,
  format: "iife",
  platform: "browser",
  target: TARGET,
  minify: true,
  legalComments: "none",
  logLevel: "warning",
});

const snippet = readFileSync("dist/kerdly.js");
const gzipped = gzipSync(snippet, { level: 9 }).length;
console.log(`dist/kerdly.js: ${snippet.length} B minified, ${gzipped} B gzipped (budget ${SNIPPET_GZIP_BUDGET} B)`);
if (gzipped > SNIPPET_GZIP_BUDGET) {
  console.error("dist/kerdly.js is over its gzip budget");
  process.exit(1);
}
