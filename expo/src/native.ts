import { requireOptionalNativeModule } from 'expo-modules-core';

import { devWarn, devWarnOnce } from './log';
import type { KerdlyDeepLinkSource, KerdlyEnvironment, KerdlyEventValue, KerdlyLogLevel } from './types';

/**
 * The JS <-> native contract. ios/KerdlySdkModule.swift and
 * android/src/main/java/com/kerdly/expo/KerdlySdkModule.kt implement exactly these functions (all
 * `AsyncFunction`s on the main queue, so native calls run in JS call order) and the
 * `onAttribution` event. Payloads coming back from native are `unknown` here and normalised in
 * normalize.ts.
 */
export const NATIVE_MODULE_NAME = 'KerdlySdk';
export const ATTRIBUTION_EVENT = 'onAttribution';

export interface NativeConfigureOptions {
  key: string;
  endpoint: string;
  environment: KerdlyEnvironment;
  collectAdvertisingId: boolean;
  /** Read by iOS only. */
  skanWriter: boolean;
  /** Read by Android only. */
  metaAppId?: string;
  logLevel: KerdlyLogLevel;
  wrapper: string;
}

/** Union of both platforms' purchase fields; each bridge reads its own. */
export interface NativePurchase {
  originalTransactionId?: string;
  transactionId?: string;
  productId?: string;
  appAccountToken?: string;
  purchaseToken?: string;
  orderId?: string;
  products?: string[];
  purchaseTime?: number;
  obfuscatedAccountId?: string;
  obfuscatedProfileId?: string;
}

export interface NativeNetworkSend {
  network: string;
  event: string;
  eventId?: string;
  value?: number;
  currency?: string;
  flag?: string;
}

export interface KerdlySdkNativeModule {
  configure(options: NativeConfigureOptions): Promise<void>;
  setUserId(userId: string | null): Promise<void>;
  track(name: string, properties: Record<string, KerdlyEventValue>): Promise<void>;
  // Standard events: the native signatures' arguments in their order, null = omitted.
  trackRegistration(method: string | null, properties: Record<string, KerdlyEventValue>): Promise<void>;
  trackStartTrial(
    productId: string | null,
    value: number | null,
    currency: string | null,
    transactionId: string | null,
    properties: Record<string, KerdlyEventValue>
  ): Promise<void>;
  trackSubscribe(
    productId: string | null,
    value: number | null,
    currency: string | null,
    transactionId: string | null,
    properties: Record<string, KerdlyEventValue>
  ): Promise<void>;
  trackPurchase(
    productId: string | null,
    value: number | null,
    currency: string | null,
    quantity: number | null,
    transactionId: string | null,
    properties: Record<string, KerdlyEventValue>
  ): Promise<void>;
  setConsent(analytics: boolean | null, ads: boolean | null): Promise<void>;
  handleUrl(url: string, source: KerdlyDeepLinkSource | null): Promise<unknown>;
  setAppAccountToken(token: string | null): Promise<void>;
  setPartnerIds(ids: Record<string, string>): Promise<void>;
  notifyPurchase(purchase: NativePurchase | null): Promise<void>;
  recordNetworkSend(send: NativeNetworkSend): Promise<void>;
  getAttribution(): Promise<unknown>;
  requestTrackingAuthorization(): Promise<unknown>;
  flush(): Promise<void>;
  getInstallId(): Promise<unknown>;
  debugFetchDeferredLinks(tiktokAppId: string | null, storeAppId: string | null, ignoreAtt: boolean): Promise<unknown>;
  addListener(eventName: typeof ATTRIBUTION_EVENT, listener: (payload: unknown) => void): {
    remove(): void;
  };
}

export type NativeMethod = Exclude<keyof KerdlySdkNativeModule, 'addListener'>;

// undefined = not looked up yet; null = not available (Expo Go, web, app not rebuilt).
let cached: KerdlySdkNativeModule | null | undefined;

export function getNativeModule(): KerdlySdkNativeModule | null {
  if (cached !== undefined) return cached;
  try {
    cached = requireOptionalNativeModule<KerdlySdkNativeModule>(NATIVE_MODULE_NAME) ?? null;
  } catch {
    cached = null;
  }
  if (cached === null) {
    devWarnOnce(
      'native-missing',
      `The native module '${NATIVE_MODULE_NAME}' is not available, so every Kerdly call is a no-op. ` +
        'Rebuild the native app after installing @kerdly/expo (npx expo prebuild, then ' +
        'npx expo run:ios / run:android, or an EAS build). Expo Go and web do not include it.'
    );
  }
  return cached;
}

/**
 * Calls a native function. Never throws and never rejects: a missing module or method, a
 * synchronous throw and a rejected promise all resolve to `undefined` (with a development warning).
 */
export function callNative<M extends NativeMethod>(
  method: M,
  ...args: Parameters<KerdlySdkNativeModule[M]>
): Promise<Awaited<ReturnType<KerdlySdkNativeModule[M]>> | undefined> {
  const native = getNativeModule();
  if (!native) return Promise.resolve(undefined);
  try {
    const fn = native[method] as unknown;
    if (typeof fn !== 'function') {
      devWarnOnce(
        `native-method-${method}`,
        `The native module '${NATIVE_MODULE_NAME}' has no function '${method}'. ` +
          'The JS and native parts of @kerdly/expo are out of sync: rebuild the native app.'
      );
      return Promise.resolve(undefined);
    }
    const result = (fn as (...a: unknown[]) => unknown).apply(native, args);
    return Promise.resolve(result as Awaited<ReturnType<KerdlySdkNativeModule[M]>>).catch(
      (error: unknown) => {
        devWarn(`Native ${method} failed:`, error);
        return undefined;
      }
    );
  } catch (error) {
    devWarn(`Native ${method} threw:`, error);
    return Promise.resolve(undefined);
  }
}
