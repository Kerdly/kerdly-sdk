import type { ExpoConfig } from '@expo/config-types';

const plugin = require('../plugin/withKerdly') as typeof import('../plugin/withKerdly');
const appPlugin = require('../app.plugin.js') as typeof plugin.withKerdly;

type AnyMod = (config: Record<string, unknown>) => Promise<{ modResults: any }>;

function baseConfig(): ExpoConfig {
  return { name: 'Acme', slug: 'acme' };
}

function emptyManifest() {
  return {
    manifest: {
      $: { 'xmlns:android': 'http://schemas.android.com/apk/res/android' },
      application: [{ $: { 'android:name': '.MainApplication' } }],
    },
  } as any;
}

/** Runs one registered mod over `modResults`, the way `expo prebuild` does. */
async function runMod(config: any, platform: 'ios' | 'android', mod: string, modResults: unknown) {
  const fn = config.mods?.[platform]?.[mod] as AnyMod | undefined;
  if (!fn) throw new Error(`mod ${platform}.${mod} not registered`);
  const result = await fn({
    ...config,
    modResults,
    modRequest: { platform, modName: mod, projectRoot: '/tmp/app', platformProjectRoot: `/tmp/app/${platform}`, introspect: false },
  });
  return result.modResults;
}

describe('config plugin', () => {
  it('app.plugin.js exports the plugin', () => {
    expect(appPlugin).toBe(plugin.withKerdly);
    expect(typeof appPlugin).toBe('function');
  });

  it('writes the iOS keys it is given', async () => {
    const config = appPlugin(baseConfig(), {
      userTrackingPermission: 'Lets us measure which ads bring drivers.',
      skanEndpoint: 'https://sdk.example.com',
    });
    const plist = await runMod(config, 'ios', 'infoPlist', { CFBundleName: 'Acme' });
    expect(plist).toEqual({
      CFBundleName: 'Acme',
      NSUserTrackingUsageDescription: 'Lets us measure which ads bring drivers.',
      NSAdvertisingAttributionReportEndpoint: 'https://sdk.example.com',
    });
  });

  it('leaves existing iOS keys alone when an option is not given', async () => {
    const config = appPlugin(baseConfig());
    const plist = await runMod(config, 'ios', 'infoPlist', {
      NSUserTrackingUsageDescription: 'from app.json',
      NSAdvertisingAttributionReportEndpoint: 'https://existing.example.com',
    });
    expect(plist).toEqual({
      NSUserTrackingUsageDescription: 'from app.json',
      NSAdvertisingAttributionReportEndpoint: 'https://existing.example.com',
    });
  });

  it('writes META_APP_ID as a string-resource reference', async () => {
    const config = appPlugin(baseConfig(), { metaAppId: '1234567890123456' });
    const manifest = await runMod(config, 'android', 'manifest', emptyManifest());
    expect(manifest.manifest.application[0]['meta-data']).toEqual([
      { $: { 'android:name': plugin.META_APP_ID_KEY, 'android:value': `@string/${plugin.META_APP_ID_STRING}` } },
    ]);
    const strings = await runMod(config, 'android', 'strings', { resources: {} });
    expect(strings.resources.string).toEqual([
      { $: { name: plugin.META_APP_ID_STRING, translatable: 'false' }, _: '1234567890123456' },
    ]);
  });

  it('is idempotent', async () => {
    let manifest = emptyManifest();
    let strings: any = { resources: {} };
    for (let i = 0; i < 2; i++) {
      const config = appPlugin(baseConfig(), { metaAppId: '1234567890123456' });
      manifest = await runMod(config, 'android', 'manifest', manifest);
      strings = await runMod(config, 'android', 'strings', strings);
    }
    expect(manifest.manifest.application[0]['meta-data']).toHaveLength(1);
    expect(strings.resources.string).toHaveLength(1);
  });

  it('removes META_APP_ID when metaAppId is no longer set', async () => {
    const withId = appPlugin(baseConfig(), { metaAppId: '1234567890123456' });
    let manifest = await runMod(withId, 'android', 'manifest', emptyManifest());
    let strings = await runMod(withId, 'android', 'strings', { resources: {} });
    const withoutId = appPlugin(baseConfig());
    manifest = await runMod(withoutId, 'android', 'manifest', manifest);
    strings = await runMod(withoutId, 'android', 'strings', strings);
    expect(manifest.manifest.application[0]['meta-data']).toEqual([]);
    expect(strings.resources.string).toEqual([]);
  });

  it('replaces the afr_meta_app_id string that plugin builds before 0.1.0 wrote', async () => {
    const config = appPlugin(baseConfig(), { metaAppId: '1234567890123456' });
    const old = { resources: { string: [{ $: { name: 'afr_meta_app_id', translatable: 'false' }, _: '1234567890123456' }] } };
    const strings = await runMod(config, 'android', 'strings', old);
    expect(plugin.META_APP_ID_STRING).toBe('kerdly_meta_app_id');
    expect(strings.resources.string).toEqual([
      { $: { name: 'kerdly_meta_app_id', translatable: 'false' }, _: '1234567890123456' },
    ]);
  });

  it('accepts a numeric app id and rejects other types', () => {
    expect(plugin.normalizeProps({ metaAppId: 1234567890123456 }).metaAppId).toBe('1234567890123456');
    expect(() => plugin.normalizeProps({ userTrackingPermission: true })).toThrow(/must be a string/);
    expect(() => plugin.normalizeProps('nope')).toThrow(/must be an object/);
  });
});
