import assert from "node:assert/strict";
import { test } from "node:test";
import { generation, latestByGeneration, matchesIntegrity, parseVersion, sri } from "./versions.mjs";
import { createHash } from "node:crypto";

test("only plain semver is a version", () => {
  assert.deepEqual(parseVersion("0.1.0"), { major: 0, minor: 1, patch: 0, prerelease: false });
  assert.equal(parseVersion("1.2.3-beta.1").prerelease, true);
  for (const bad of ["v1.0.0", "1.0", "1.0.0/../x", "../1.0.0", "1.0.0 "]) assert.equal(parseVersion(bad), null);
});

test("0.x and 1.x are v1; 2.x starts v2", () => {
  assert.equal(generation("0.1.0"), "v1");
  assert.equal(generation("1.9.0"), "v1");
  assert.equal(generation("2.0.0"), "v2");
  assert.equal(generation("x"), null);
});

test("each generation serves its newest stable, non-deprecated release", () => {
  const releases = [
    { version: "0.1.0" },
    { version: "0.10.0" },
    { version: "0.9.1" },
    { version: "0.11.0-beta.1" },
    { version: "0.12.0", deprecated: "bad build" },
    { version: "2.0.0" },
  ];
  assert.deepEqual(latestByGeneration(releases), { v1: "0.10.0", v2: "2.0.0" });
  assert.deepEqual(latestByGeneration([{ version: "1.0.0-rc.1" }]), {});
});

test("integrity values", () => {
  const body = Buffer.from("console.log(1)");
  assert.match(sri(body), /^sha384-[A-Za-z0-9+/]+=*$/);
  const npm = `sha512-${createHash("sha512").update(body).digest("base64")}`;
  assert.equal(matchesIntegrity(body, npm), true);
  assert.equal(matchesIntegrity(Buffer.from("other"), npm), false);
  assert.equal(matchesIntegrity(body, "md5-abc"), false);
});
