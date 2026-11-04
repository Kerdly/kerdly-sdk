#!/usr/bin/env node
// Vendors the native SDK sources into this package, which compiles them together with the bridge:
//
//   ../ios/Sources/KerdlySDK/**              -> ios/KerdlySDK/                 (compiled by ios/KerdlySdk.podspec)
//   ../android/kerdly-sdk/src/main/{java,kotlin,res,assets,resources}
//                                         -> android/vendor/kerdly-sdk/     (compiled by android/build.gradle)
//   ../android/kerdly-sdk/consumer-rules.pro -> android/vendor/kerdly-sdk/consumer-rules.pro
//   KERDLY_VERSION from ../android/gradle.properties
//                                         -> android/vendor/kerdly-sdk/kerdly-sdk.properties (BuildConfig.KERDLY_VERSION)
//
// It also checks what cannot be vendored by copying: the Android manifest entries and Gradle
// dependencies of the native SDK must be declared in android/src/main/AndroidManifest.xml and
// android/build.gradle, and the Swift sources must compile inside a CocoaPods module.
//
// Usage: node scripts/sync-native.mjs [--strict] [--check]
//   (default)  copy; missing native sources keep the existing copy; problems are warnings
//              (npm `prepare`, so `npm install` works before the native SDKs exist)
//   --strict   copy; missing sources or any problem fail (npm `prepack`: never pack a broken module)
//   --check    copy nothing; fail when the vendored copies differ from the sources or on any problem (CI)
// Source locations can be overridden with KERDLY_IOS_SDK_DIR and KERDLY_ANDROID_SDK_DIR.

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const PKG_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const REPO_ROOT = path.resolve(PKG_ROOT, '..');

const args = new Set(process.argv.slice(2));
const unknownArgs = [...args].filter((a) => !['--strict', '--check'].includes(a));
if (unknownArgs.length > 0) {
  console.error(`sync-native: unknown argument(s) ${unknownArgs.join(' ')}`);
  process.exit(2);
}
const CHECK = args.has('--check');
const STRICT = args.has('--strict') || CHECK;

const IOS_SRC = path.resolve(process.env.KERDLY_IOS_SDK_DIR ?? path.join(REPO_ROOT, 'ios', 'Sources', 'KerdlySDK'));
const ANDROID_MODULE = path.resolve(process.env.KERDLY_ANDROID_SDK_DIR ?? path.join(REPO_ROOT, 'android', 'kerdly-sdk'));
const ANDROID_ROOT = path.dirname(ANDROID_MODULE);
const IOS_DEST = path.join(PKG_ROOT, 'ios', 'KerdlySDK');
const ANDROID_DEST = path.join(PKG_ROOT, 'android', 'vendor', 'kerdly-sdk');
const EXPO_MANIFEST = path.join(PKG_ROOT, 'android', 'src', 'main', 'AndroidManifest.xml');
const EXPO_GRADLE = path.join(PKG_ROOT, 'android', 'build.gradle');

const ANDROID_SOURCE_DIRS = ['java', 'kotlin', 'res', 'assets', 'resources'];
const ANDROID_UNSUPPORTED_DIRS = ['aidl', 'jniLibs', 'cpp', 'jni', 'rs', 'shaders'];
// Fields AGP generates for every library BuildConfig; the Expo module has the SDK's namespace, so
// they exist with the same meaning.
const STANDARD_BUILD_CONFIG = new Set(['DEBUG', 'LIBRARY_PACKAGE_NAME', 'BUILD_TYPE']);
// Custom fields android/build.gradle declares from kerdly-sdk.properties.
const KNOWN_BUILD_CONFIG = new Set(['KERDLY_VERSION']);
const IGNORED_FILES = new Set(['.DS_Store']);

const problems = [];
const notes = [];
const rel = (p) => path.relative(PKG_ROOT, p) || '.';

function problem(message) {
  problems.push(message);
}

// ---------------------------------------------------------------------------------------------
// File helpers

function listFiles(root) {
  const out = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (IGNORED_FILES.has(entry.name)) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile()) out.push(path.relative(root, full));
    }
  };
  if (fs.existsSync(root)) walk(root);
  return out.sort();
}

/** `files` maps a destination-relative path to its source file. */
function treeDigest(files) {
  const hash = createHash('sha256');
  for (const [relPath, source] of [...files.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    hash.update(relPath.split(path.sep).join('/'));
    hash.update('\0');
    hash.update(fs.readFileSync(source));
    hash.update('\0');
  }
  return hash.digest('hex');
}

function gitInfo(dir) {
  try {
    const commit = execFileSync('git', ['-C', dir, 'rev-parse', 'HEAD'], { stdio: ['ignore', 'pipe', 'ignore'] })
      .toString()
      .trim();
    const status = execFileSync('git', ['-C', dir, 'status', '--porcelain', '--', '.'], {
      stdio: ['ignore', 'pipe', 'ignore'],
    }).toString();
    return { commit, dirty: status.trim().length > 0 };
  } catch {
    return { commit: null, dirty: null };
  }
}

const STAMP = '.kerdly-sync.json';

/**
 * Makes `dest` hold exactly `files` (plus `generated` contents and a stamp), or in --check mode
 * reports whether it already does.
 */
function vendor(label, dest, files, generated, stampExtra) {
  const digest = treeDigest(files);
  const wanted = new Set([...files.keys(), ...generated.keys()]);
  if (CHECK) {
    const present = listFiles(dest).filter((f) => f !== STAMP);
    const stale = [];
    for (const f of present) if (!wanted.has(f)) stale.push(`extra ${f}`);
    for (const [f, source] of files) {
      const target = path.join(dest, f);
      if (!fs.existsSync(target)) stale.push(`missing ${f}`);
      else if (!fs.readFileSync(target).equals(fs.readFileSync(source))) stale.push(`differs ${f}`);
    }
    for (const [f, content] of generated) {
      const target = path.join(dest, f);
      if (!fs.existsSync(target) || fs.readFileSync(target, 'utf8') !== content) stale.push(`differs ${f}`);
    }
    if (stale.length > 0) {
      problem(`${label}: ${rel(dest)} is stale (${stale.slice(0, 5).join(', ')}${stale.length > 5 ? ', …' : ''}); run npm run sync-native`);
    } else {
      notes.push(`${label}: ${rel(dest)} is up to date (${files.size} files)`);
    }
    return;
  }
  fs.rmSync(dest, { recursive: true, force: true });
  for (const [f, source] of files) {
    const target = path.join(dest, f);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.copyFileSync(source, target);
  }
  for (const [f, content] of generated) {
    const target = path.join(dest, f);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, content);
  }
  const stamp = { ...stampExtra, files: files.size, sha256: digest };
  fs.writeFileSync(path.join(dest, STAMP), `${JSON.stringify(stamp, null, 2)}\n`);
  notes.push(`${label}: vendored ${files.size} files into ${rel(dest)}`);
}

function missingSources(label, sourceDir, dest, marker) {
  if (fs.existsSync(marker)) {
    const message = `${label}: ${sourceDir} not found; keeping the existing ${rel(dest)}`;
    if (STRICT) problem(message);
    else notes.push(message);
  } else {
    problem(`${label}: ${sourceDir} not found and ${rel(dest)} does not exist; the ${label} build will fail`);
  }
}

// ---------------------------------------------------------------------------------------------
// iOS

function syncIos() {
  if (!fs.existsSync(IOS_SRC)) {
    missingSources('iOS', IOS_SRC, IOS_DEST, path.join(IOS_DEST, STAMP));
    return;
  }
  const files = new Map(listFiles(IOS_SRC).map((f) => [f, path.join(IOS_SRC, f)]));
  const swift = [...files.keys()].filter((f) => f.endsWith('.swift'));
  if (swift.length === 0) problem(`iOS: no Swift files under ${IOS_SRC}`);
  if (![...files.keys()].some((f) => path.basename(f) === 'PrivacyInfo.xcprivacy')) {
    problem('iOS: the SDK has no PrivacyInfo.xcprivacy; ios/KerdlySdk.podspec bundles it');
  }
  // These compile under SwiftPM but not inside the CocoaPods module that also holds the bridge.
  for (const f of swift) {
    const text = fs.readFileSync(path.join(IOS_SRC, f), 'utf8');
    if (/^\s*(@testable\s+)?import\s+KerdlySDK\b/m.test(text)) {
      problem(`iOS: ${f} imports KerdlySDK; vendored, the SDK is part of the KerdlySdk pod's module`);
    }
    if (/\bBundle\.module\b/.test(text) && !/#if\s+SWIFT_PACKAGE/.test(text)) {
      problem(`iOS: ${f} uses Bundle.module outside #if SWIFT_PACKAGE; CocoaPods has no Bundle.module`);
    }
  }
  vendor('iOS', IOS_DEST, files, new Map(), { source: path.relative(REPO_ROOT, IOS_SRC), ...gitInfo(IOS_SRC) });
}

// ---------------------------------------------------------------------------------------------
// Android

function readGradleProperty(file, name) {
  if (!fs.existsSync(file)) return null;
  const match = fs.readFileSync(file, 'utf8').match(new RegExp(`^\\s*${name}\\s*=\\s*(.+?)\\s*$`, 'm'));
  return match ? match[1] : null;
}

/** `<tag android:name="…">` occurrences, as "tag name" strings. */
function manifestEntries(xml) {
  const withoutComments = xml.replace(/<!--[\s\S]*?-->/g, '');
  const entries = new Set();
  const tags = ['uses-permission', 'uses-permission-sdk-23', 'uses-feature', 'package', 'activity', 'activity-alias', 'service', 'receiver', 'provider', 'meta-data', 'uses-library', 'action'];
  for (const tag of tags) {
    const re = new RegExp(`<${tag}\\b[^>]*?android:name\\s*=\\s*"([^"]+)"`, 'g');
    for (const m of withoutComments.matchAll(re)) entries.add(`${tag} ${m[1]}`);
  }
  // <intent> elements inside <queries> have no android:name; compare their bodies verbatim.
  for (const m of withoutComments.matchAll(/<queries>([\s\S]*?)<\/queries>/g)) {
    for (const intent of m[1].matchAll(/<intent>([\s\S]*?)<\/intent>/g)) {
      entries.add(`queries-intent ${intent[1].replace(/\s+/g, ' ').trim()}`);
    }
    if (/<provider\b[^>]*android:authorities/.test(m[1])) {
      for (const p of m[1].matchAll(/<provider\b[^>]*android:authorities\s*=\s*"([^"]+)"/g)) entries.add(`queries-provider ${p[1]}`);
    }
  }
  return entries;
}

/** `group:artifact` coordinates of implementation/api dependencies in a Gradle build file. */
function gradleDependencies(text, catalog) {
  const deps = new Map();
  const configurations = 'implementation|api|compileOnly|runtimeOnly';
  const literal = new RegExp(`\\b(${configurations})\\s*\\(?\\s*["']([^"':\\s]+):([^"':\\s]+)(?::([^"'\\s]+))?["']`, 'g');
  for (const m of text.matchAll(literal)) deps.set(`${m[2]}:${m[3]}`, { configuration: m[1], version: m[4] ?? null });
  const alias = new RegExp(`\\b(${configurations})\\s*\\(\\s*libs\\.([A-Za-z0-9_.]+)\\s*\\)`, 'g');
  for (const m of text.matchAll(alias)) {
    const coordinate = catalog.get(m[2].replace(/[._]/g, '-'));
    if (coordinate) deps.set(coordinate.module, { configuration: m[1], version: coordinate.version });
    else problem(`Android: cannot resolve the version-catalog dependency libs.${m[2]} of the native SDK`);
  }
  return deps;
}

/** A minimal reader for gradle/libs.versions.toml: [versions] and [libraries] entries. */
function versionCatalog(file) {
  const catalog = new Map();
  if (!fs.existsSync(file)) return catalog;
  const versions = new Map();
  let section = '';
  for (const raw of fs.readFileSync(file, 'utf8').split('\n')) {
    const line = raw.replace(/#.*$/, '').trim();
    const header = line.match(/^\[(.+)\]$/);
    if (header) {
      section = header[1];
      continue;
    }
    const kv = line.match(/^([A-Za-z0-9_.-]+)\s*=\s*(.+)$/);
    if (!kv) continue;
    const [, key, value] = kv;
    if (section === 'versions') {
      versions.set(key, value.replace(/^"|"$/g, ''));
      continue;
    }
    if (section !== 'libraries') continue;
    const field = (name) => value.match(new RegExp(`\\b${name.replace('.', '\\s*\\.\\s*')}\\s*=\\s*"([^"]+)"`))?.[1];
    const literal = value.match(/^"([^":]+):([^":]+)(?::([^"]+))?"$/);
    const module = literal
      ? `${literal[1]}:${literal[2]}`
      : field('module') ?? (field('group') && field('name') ? `${field('group')}:${field('name')}` : undefined);
    const version = literal ? literal[3] ?? null : field('version') ?? versions.get(field('version.ref') ?? '') ?? null;
    if (module) catalog.set(key.replace(/[._]/g, '-'), { module, version });
  }
  return catalog;
}

function syncAndroid() {
  const main = path.join(ANDROID_MODULE, 'src', 'main');
  if (!fs.existsSync(main)) {
    missingSources('Android', main, ANDROID_DEST, path.join(ANDROID_DEST, STAMP));
    return;
  }

  const files = new Map();
  for (const dir of ANDROID_SOURCE_DIRS) {
    const root = path.join(main, dir);
    for (const f of listFiles(root)) files.set(path.join(dir, f), path.join(root, f));
  }
  for (const dir of ANDROID_UNSUPPORTED_DIRS) {
    if (fs.existsSync(path.join(main, dir))) {
      problem(`Android: the SDK has src/main/${dir}, which android/build.gradle does not compile`);
    }
  }
  const consumerRules = path.join(ANDROID_MODULE, 'consumer-rules.pro');
  if (fs.existsSync(consumerRules)) files.set('consumer-rules.pro', consumerRules);
  const code = [...files.keys()].filter((f) => /\.(kt|java)$/.test(f));
  if (code.length === 0) problem(`Android: no Kotlin or Java files under ${main}`);

  const buildFile = ['build.gradle.kts', 'build.gradle'].map((f) => path.join(ANDROID_MODULE, f)).find((f) => fs.existsSync(f));
  const buildText = buildFile ? fs.readFileSync(buildFile, 'utf8') : '';
  if (!buildFile) problem(`Android: no build.gradle(.kts) in ${ANDROID_MODULE}`);

  // BuildConfig: the Expo module uses the SDK's namespace (com.kerdly.sdk) and declares KERDLY_VERSION.
  const namespace = buildText.match(/namespace\s*=?\s*["']([^"']+)["']/)?.[1];
  const expoGradle = fs.readFileSync(EXPO_GRADLE, 'utf8');
  const expoNamespace = expoGradle.match(/namespace\s*=?\s*["']([^"']+)["']/)?.[1];
  if (namespace && namespace !== expoNamespace) {
    problem(`Android: the SDK's namespace is ${namespace} but android/build.gradle uses ${expoNamespace}; the vendored sources need their own BuildConfig/R`);
  }
  for (const m of buildText.matchAll(/buildConfigField\s*\(?\s*["'][^"']+["']\s*,\s*["']([A-Z0-9_]+)["']/g)) {
    if (!KNOWN_BUILD_CONFIG.has(m[1])) {
      problem(`Android: the SDK declares BuildConfig.${m[1]}; declare it in android/build.gradle and teach this script its value`);
    }
  }
  for (const f of code) {
    const text = fs.readFileSync(files.get(f), 'utf8');
    for (const m of text.matchAll(/\bBuildConfig\.([A-Z][A-Z0-9_]*)/g)) {
      if (!KNOWN_BUILD_CONFIG.has(m[1]) && !STANDARD_BUILD_CONFIG.has(m[1])) {
        problem(`Android: ${f} reads BuildConfig.${m[1]}, which the Expo module does not declare`);
      }
    }
  }
  const generated = new Map();
  const kerdlyVersion = readGradleProperty(path.join(ANDROID_ROOT, 'gradle.properties'), 'KERDLY_VERSION');
  if (kerdlyVersion) {
    generated.set('kerdly-sdk.properties', `# Written by scripts/sync-native.mjs from ${path.relative(REPO_ROOT, ANDROID_ROOT)}/gradle.properties\nKERDLY_VERSION=${kerdlyVersion}\n`);
  } else {
    problem(`Android: KERDLY_VERSION not found in ${path.join(ANDROID_ROOT, 'gradle.properties')}`);
  }

  // Manifest entries must be mirrored in the Expo module's manifest.
  const sdkManifest = path.join(main, 'AndroidManifest.xml');
  if (fs.existsSync(sdkManifest)) {
    const ours = manifestEntries(fs.readFileSync(EXPO_MANIFEST, 'utf8'));
    for (const entry of manifestEntries(fs.readFileSync(sdkManifest, 'utf8'))) {
      if (!ours.has(entry)) problem(`Android: the SDK manifest has <${entry.replace(' ', ' android:name="')}"> but android/src/main/AndroidManifest.xml does not`);
    }
  }

  // Dependencies must be mirrored in android/build.gradle (same group:artifact, any version).
  const catalog = versionCatalog(path.join(ANDROID_ROOT, 'gradle', 'libs.versions.toml'));
  // testImplementation etc. never match: the configuration names are matched case-sensitively.
  const theirs = gradleDependencies(buildText, catalog);
  const ours = gradleDependencies(expoGradle, new Map());
  for (const [module, { version }] of theirs) {
    if (!ours.has(module)) {
      problem(`Android: the SDK depends on ${module}${version ? `:${version}` : ''}; add it to android/build.gradle`);
    } else if (version && ours.get(module).version && ours.get(module).version !== version) {
      notes.push(`Android: ${module} is ${version} in the SDK and ${ours.get(module).version} in android/build.gradle`);
    }
  }

  vendor('Android', ANDROID_DEST, files, generated, {
    source: path.relative(REPO_ROOT, ANDROID_MODULE),
    sdkVersion: kerdlyVersion,
    ...gitInfo(ANDROID_MODULE),
  });
}

// ---------------------------------------------------------------------------------------------

syncIos();
syncAndroid();

for (const note of notes) console.log(`sync-native: ${note}`);
for (const message of problems) console[STRICT ? 'error' : 'warn'](`sync-native: ${STRICT ? 'error' : 'warning'}: ${message}`);
if (problems.length > 0 && STRICT) process.exit(1);
