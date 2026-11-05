import type * as SdkModule from '../src';
import type * as ExpoModulesCoreMock from './mocks/expo-modules-core';
import type * as ReactNativeMock from './mocks/react-native';

export const IOS_ATTRIBUTION = {
  state: 'provisional',
  network: 'meta',
  status: 'probabilistic',
  method: 'ip_match',
  campaignId: '120210000000001',
  campaign: 'US - Permit - iOS',
  adsetId: '120210000000002',
  adset: 'Broad',
  adId: '120210000000003',
  ad: 'Failed 3 times',
  keywordId: null,
  keyword: null,
  linkId: null,
  cppId: null,
  decidedAt: 1759708800000,
  raw: {
    state: 'provisional',
    network: 'meta',
    status: 'probabilistic',
    method: 'ip_match',
    campaign_id: '120210000000001',
    decided_at: 1759708800000,
  },
};

/** A native module double: every bridge function is a jest.fn resolving like the real bridge. */
export function createMockNativeModule(Base: typeof ExpoModulesCoreMock.NativeModule) {
  const module = new Base();
  return Object.assign(module, {
    configure: jest.fn(async (_options: unknown): Promise<void> => undefined),
    setUserId: jest.fn(async (_userId: unknown): Promise<void> => undefined),
    track: jest.fn(async (_name: unknown, _properties: unknown): Promise<void> => undefined),
    trackRegistration: jest.fn(async (_method: unknown, _properties: unknown): Promise<void> => undefined),
    trackStartTrial: jest.fn(
      async (_productId: unknown, _value: unknown, _currency: unknown, _transactionId: unknown, _properties: unknown): Promise<void> =>
        undefined
    ),
    trackSubscribe: jest.fn(
      async (_productId: unknown, _value: unknown, _currency: unknown, _transactionId: unknown, _properties: unknown): Promise<void> =>
        undefined
    ),
    trackPurchase: jest.fn(
      async (
        _productId: unknown,
        _value: unknown,
        _currency: unknown,
        _quantity: unknown,
        _transactionId: unknown,
        _properties: unknown
      ): Promise<void> => undefined
    ),
    setConsent: jest.fn(async (_analytics: unknown, _ads: unknown): Promise<void> => undefined),
    handleUrl: jest.fn(async (url: string, _source: unknown): Promise<unknown> => ({
      url,
      cpp: 'web-meta',
      ppid: null,
      clickId: null,
      visitId: null,
      campaignIds: null,
    })),
    setAppAccountToken: jest.fn(async (_token: unknown): Promise<void> => undefined),
    setPartnerIds: jest.fn(async (_ids: unknown): Promise<void> => undefined),
    notifyPurchase: jest.fn(async (_purchase: unknown): Promise<void> => undefined),
    recordNetworkSend: jest.fn(async (_send: unknown): Promise<void> => undefined),
    getAttribution: jest.fn(async (): Promise<unknown> => null),
    requestTrackingAuthorization: jest.fn(async (): Promise<unknown> => 'authorized'),
    flush: jest.fn(async (): Promise<void> => undefined),
    getInstallId: jest.fn(async (): Promise<unknown> => '8c1f5d0e-2f3a-4c55-9d7e-1b2c3d4e5f60'),
    debugFetchDeferredLinks: jest.fn(
      async (_tiktokAppId: unknown, _storeAppId: unknown): Promise<unknown> => [
        { network: 'meta', status: 'none', httpStatus: 200 },
      ]
    ),
  });
}

export type MockNativeModule = ReturnType<typeof createMockNativeModule>;

export interface LoadedSdk {
  Kerdly: typeof SdkModule.Kerdly;
  /** `null` when loaded with `native: false` (Expo Go, web, app not rebuilt). */
  native: MockNativeModule | null;
  rn: typeof ReactNativeMock;
  emc: typeof ExpoModulesCoreMock;
}

/**
 * Loads a fresh copy of the SDK (its module state — the deep-link subscription, the cached native
 * module, the warn-once keys — is per load) together with the mocks it sees.
 */
export function loadSdk(
  options: { platform?: 'ios' | 'android' | 'web'; native?: boolean; initialUrl?: string | null | Error } = {}
): LoadedSdk {
  let loaded: LoadedSdk | undefined;
  jest.isolateModules(() => {
    const emc = require('./mocks/expo-modules-core') as typeof ExpoModulesCoreMock;
    const rn = require('./mocks/react-native') as typeof ReactNativeMock;
    rn.Platform.OS = options.platform ?? 'ios';
    rn.__setInitialURL(options.initialUrl ?? null);
    const native = options.native === false ? null : createMockNativeModule(emc.NativeModule);
    if (native) emc.__setNativeModule('KerdlySdk', native);
    const sdk = require('../src') as typeof SdkModule;
    loaded = { Kerdly: sdk.Kerdly, native, rn, emc };
  });
  if (!loaded) throw new Error('loadSdk failed');
  return loaded;
}

/** Lets pending promise callbacks (e.g. the initial-URL read) run. */
export function flushPromises(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

export function silenceConsole(): { warn: jest.SpyInstance; error: jest.SpyInstance } {
  return {
    warn: jest.spyOn(console, 'warn').mockImplementation(() => undefined),
    error: jest.spyOn(console, 'error').mockImplementation(() => undefined),
  };
}
