import assert from 'node:assert/strict';
import { test } from 'node:test';
import { SDKS, compareVersions, enabledSdks, plan, ships, versionOnly } from './sdks.mjs';

test('each SDK ships its sources but not its tests or docs', () => {
  assert.ok(ships('ios', 'ios/Sources/KerdlySDK/Core/KerdlyCore.swift'));
  assert.ok(ships('ios', 'Package.swift'));
  assert.ok(ships('ios', 'KerdlySDK.podspec'));
  assert.ok(!ships('ios', 'ios/Tests/KerdlySDKTests/ConfigTests.swift'));
  assert.ok(!ships('ios', 'ios/README.md'));
  assert.ok(ships('android', 'android/kerdly-sdk/src/main/kotlin/com/kerdly/sdk/Kerdly.kt'));
  assert.ok(ships('android', 'android/gradle.properties'));
  assert.ok(!ships('android', 'android/kerdly-sdk/src/test/kotlin/com/kerdly/sdk/internal/CoreTest.kt'));
  assert.ok(ships('web', 'web/src/client.ts'));
  assert.ok(!ships('web', 'web/test/client.test.ts'));
  assert.ok(!ships('web', 'web/vitest.config.ts'));
  assert.ok(!ships('web', 'web/CHANGELOG.md'));
  assert.ok(ships('expo', 'expo/ios/KerdlySdkModule.swift'));
  assert.ok(ships('expo', 'ios/Sources/KerdlySDK/Core/KerdlyCore.swift'));
  assert.ok(ships('expo', 'android/kerdly-sdk/src/main/kotlin/com/kerdly/sdk/Kerdly.kt'));
  assert.ok(!ships('expo', 'android/kerdly-sdk/src/test/kotlin/com/kerdly/sdk/internal/CoreTest.kt'));
  assert.ok(!ships('expo', 'ios/Tests/KerdlySDKTests/ConfigTests.swift'));
  assert.ok(!ships('expo', 'expo/jest.config.js'));
  assert.ok(!ships('web', 'expo/src/index.ts'));
  assert.ok(!ships('ios', 'cdn/build.mjs'));
});

test('tags: bare versions for iOS, prefixed for the rest', () => {
  assert.equal(SDKS.ios.tag('0.2.0'), '0.2.0');
  assert.equal(SDKS.web.tag('0.2.0'), 'web-v0.2.0');
  assert.equal(SDKS.ios.versionOf('web-v0.2.0'), null);
  assert.equal(SDKS.web.versionOf('0.2.0'), null);
  assert.equal(SDKS.web.versionOf('web-v0.2.0-beta.1'), '0.2.0-beta.1');
  assert.equal(SDKS.expo.versionOf('expo-v1'), null);
});

test('version order', () => {
  const sorted = ['0.10.0', '0.2.0', '0.2.0-beta.2', '0.2.0-beta.10', '0.2.0-alpha', '1.0.0', '0.2.1'].sort(compareVersions);
  assert.deepEqual(sorted, ['0.2.0-alpha', '0.2.0-beta.2', '0.2.0-beta.10', '0.2.0', '0.2.1', '0.10.0', '1.0.0']);
});

test('first release: a version with no tag at all', () => {
  const p = plan('web', { version: '0.1.0', tags: ['0.1.0'], changedSinceLast: null });
  assert.equal(p.release, true);
  assert.equal(p.tag, 'web-v0.1.0');
});

test('released, with or without changes since', () => {
  const tags = ['web-v0.1.0', '0.1.0'];
  assert.deepEqual(plan('web', { version: '0.1.0', tags, changedSinceLast: [] }).pending, []);
  const p = plan('web', { version: '0.1.0', tags, changedSinceLast: ['web/src/client.ts', 'web/test/x.test.ts', 'ios/Sources/A.swift'] });
  assert.equal(p.release, false);
  assert.deepEqual(p.pending, ['web/src/client.ts']);
});

test('a new version releases only when its SDK changed', () => {
  const tags = ['web-v0.1.0', '0.1.0', 'expo-v0.1.0'];
  const changed = ['web/src/client.ts', 'web/CHANGELOG.md', 'web/package.json'];
  const web = plan('web', { version: '0.1.1', tags, changedSinceLast: changed });
  assert.equal(web.release, true);
  assert.equal(web.tag, 'web-v0.1.1');
  assert.deepEqual(web.changes, ['web/src/client.ts', 'web/package.json']);
  const ios = plan('ios', { version: '0.1.1', tags, changedSinceLast: changed });
  assert.match(ios.error, /nothing the iOS SDK ships changed since 0\.1\.0/);
});

test('a new version must be above the last release', () => {
  const p = plan('expo', { version: '0.1.0', tags: ['expo-v0.1.0', 'expo-v0.2.0'], changedSinceLast: ['expo/src/index.ts'] });
  assert.equal(p.release, false);
  const q = plan('expo', { version: '0.1.5', tags: ['expo-v0.1.0', 'expo-v0.2.0'], changedSinceLast: ['expo/src/index.ts'] });
  assert.match(q.error, /not above its last release 0\.2\.0/);
});

test('a version bump alone is not a change', () => {
  const swift = (v) => `enum A {\n    static let sdkVersion = "${v}"\n}\n`;
  assert.ok(versionOnly('ios/Sources/KerdlySDK/Core/KerdlyCore.swift', swift('0.1.0'), swift('0.1.1')));
  assert.ok(!versionOnly('ios/Sources/KerdlySDK/Core/KerdlyCore.swift', swift('0.1.0'), `${swift('0.1.1')}// more\n`));
  const pkg = (v) => `${JSON.stringify({ name: '@kerdly/web', version: v, files: ['dist'] }, null, 2)}\n`;
  assert.ok(versionOnly('web/package.json', pkg('0.1.0'), pkg('0.2.0')));
  assert.ok(!versionOnly('web/package.json', pkg('0.1.0'), pkg('0.2.0').replace('dist', 'lib')));
  assert.ok(!versionOnly('web/src/client.ts', 'a', 'b'));
});

test('RELEASES_ENABLED names the SDKs that may be released', () => {
  assert.deepEqual(enabledSdks('web'), ['web']);
  assert.deepEqual(enabledSdks(' Web, expo '), ['web', 'expo']);
  assert.deepEqual(enabledSdks('true'), ['ios', 'android', 'web', 'expo']);
  assert.deepEqual(enabledSdks('all'), ['ios', 'android', 'web', 'expo']);
  assert.deepEqual(enabledSdks('false'), []);
  assert.deepEqual(enabledSdks(''), []);
  assert.deepEqual(enabledSdks(undefined), []);
  assert.throws(() => enabledSdks('web, swift'), /unknown SDK swift/);
});
