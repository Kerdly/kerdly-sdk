import { Linking, Platform } from 'react-native';

import { devError, devWarn, isLogLevel, setLogLevel } from './log';
import { ATTRIBUTION_EVENT, callNative, getNativeModule, type NativeConfigureOptions } from './native';
import { normalizeAttribution, normalizeDeepLink } from './normalize';
import type {
  KerdlyAttStatus,
  KerdlyAttribution,
  KerdlyAttributionListener,
  KerdlyConfigureOptions,
  KerdlyConsent,
  KerdlyDeepLink,
  KerdlyDeepLinkSource,
  KerdlyEnvironment,
  KerdlyEventProperties,
  KerdlyNetworkSend,
  KerdlyPurchase,
  KerdlyPurchaseEvent,
  KerdlyRegistrationEvent,
  KerdlyRevenueEvent,
  KerdlySubscription,
} from './types';
import {
  isUuid,
  sanitizeNetworkSend,
  sanitizePartnerIds,
  sanitizePurchase,
  validateEvent,
  validateStandardEvent,
  type StandardEventMethod,
  type StandardEventValidation,
} from './validation';
import { WRAPPER } from './version';

// Every public function is total: it validates its input, never throws, and its promise never
// rejects. Calls go straight to the native SDK, which holds calls made before `configure` and runs
// them after it. The only behaviour of this layer is the automatic deep-link capture.

const ENVIRONMENTS: readonly KerdlyEnvironment[] = ['auto', 'production', 'sandbox', 'development'];
const ATT_STATUSES: readonly KerdlyAttStatus[] = [
  'authorized',
  'denied',
  'restricted',
  'not_determined',
  'not_applicable',
];

const NOOP_SUBSCRIPTION: KerdlySubscription = { remove() {} };

// Deep-link capture: one `url` subscription, and one read of the initial URL per JS runtime.
let urlSubscription: { remove(): void } | null = null;
let initialUrlRequested = false;

function warnProblems(context: string, problems: string[]): void {
  if (problems.length > 0) devWarn(`${context}: ${problems.join('; ')}`);
}

function shown(value: unknown): string {
  try {
    return typeof value === 'string' ? JSON.stringify(value) : String(value);
  } catch {
    return typeof value;
  }
}

// expo-dev-client opens the app with `<scheme>://expo-development-client/?url=<dev server>`;
// that is the development server, not a deep link.
function isDevLauncherUrl(url: string): boolean {
  return /^[a-z][a-z0-9+.-]*:\/\/expo-development-client(?:[/?#]|$)/i.test(url);
}

function forwardUrl(url: unknown, source: KerdlyDeepLinkSource): void {
  if (typeof url !== 'string' || url.length === 0 || isDevLauncherUrl(url)) return;
  void callNative('handleUrl', url, source);
}

function setDeepLinkCapture(enabled: boolean): void {
  if (!enabled) {
    if (urlSubscription) {
      try {
        urlSubscription.remove();
      } catch (error) {
        devWarn('Removing the Linking url listener failed:', error);
      }
      urlSubscription = null;
    }
    return;
  }
  if (!urlSubscription) {
    try {
      urlSubscription = Linking.addEventListener('url', (event: { url: string }) =>
        forwardUrl(event?.url, 'runtime')
      );
    } catch (error) {
      devWarn('Could not subscribe to Linking url events:', error);
    }
  }
  if (!initialUrlRequested) {
    initialUrlRequested = true;
    try {
      Promise.resolve(Linking.getInitialURL()).then(
        (url) => forwardUrl(url, 'initial'),
        (error: unknown) => devWarn('Linking.getInitialURL failed:', error)
      );
    } catch (error) {
      devWarn('Linking.getInitialURL failed:', error);
    }
  }
}

/**
 * Starts the native SDK. Call it once, as early as possible (module scope of the root component).
 * Resolves when the native `configure` has run; never rejects.
 */
/** The Kerdly collector, used when `endpoint` is not given. */
export const DEFAULT_ENDPOINT = 'https://app.kerdly.com/api';

async function configure(options: KerdlyConfigureOptions): Promise<void> {
  try {
    if (options === null || typeof options !== 'object') {
      devWarn('configure: an options object with `key` is required; ignored');
      return;
    }
    const { key } = options;
    const endpoint = options.endpoint === undefined ? DEFAULT_ENDPOINT : options.endpoint;
    if (typeof key !== 'string' || key.length === 0) {
      devWarn('configure: `key` (pk_live_… / pk_test_…) is required; ignored');
      return;
    }
    if (typeof endpoint !== 'string' || endpoint.length === 0) {
      devWarn('configure: `endpoint` must be the collector base URL; ignored');
      return;
    }
    if (!/^pk_(live|test)_/.test(key)) {
      devWarn('configure: `key` should be the app public key (pk_live_… / pk_test_…)');
    }

    let logLevel = options.logLevel ?? 'warn';
    if (!isLogLevel(logLevel)) {
      devWarn(`configure: unknown logLevel ${shown(logLevel)}; using "warn"`);
      logLevel = 'warn';
    }
    setLogLevel(logLevel);

    let environment = options.environment ?? 'auto';
    if (!ENVIRONMENTS.includes(environment)) {
      devWarn(`configure: unknown environment ${shown(environment)}; using "auto"`);
      environment = 'auto';
    }

    const nativeOptions: NativeConfigureOptions = {
      key,
      endpoint,
      environment,
      collectAdvertisingId: options.collectAdvertisingId !== false,
      skanWriter: options.skanWriter === true,
      logLevel,
      wrapper: WRAPPER,
    };
    if (typeof options.metaAppId === 'string' && options.metaAppId.length > 0) {
      nativeOptions.metaAppId = options.metaAppId;
    }

    if (!getNativeModule()) return;
    // Native calls run in call order, so URLs forwarded below reach a configured SDK.
    const configured = callNative('configure', nativeOptions);
    setDeepLinkCapture(options.autoDeepLinks !== false);
    await configured;
  } catch (error) {
    devWarn('configure failed:', error);
  }
}

/** Sets (or, with `null`, clears) the app's user id; attached to every later event. */
function setUserId(userId: string | null): void {
  try {
    if (userId === null || userId === undefined) {
      void callNative('setUserId', null);
    } else if (typeof userId === 'string' && userId.length > 0) {
      void callNative('setUserId', userId);
    } else {
      devWarn(`setUserId: expected a non-empty string or null, got ${shown(userId)}; ignored`);
    }
  } catch (error) {
    devWarn('setUserId failed:', error);
  }
}

/** Records a custom event. Invalid names drop the event, invalid props are dropped. */
function track(name: string, properties?: KerdlyEventProperties): void {
  try {
    const { event, problems } = validateEvent(name, properties);
    if (!event) {
      warnProblems('track: event dropped', problems);
      return;
    }
    warnProblems(`track(${shown(event.name)}): dropped`, problems);
    void callNative('track', event.name, event.properties);
  } catch (error) {
    devWarn('track failed:', error);
  }
}

// Standard events: a malformed typed field is dropped, never the event.
function validStandardEvent(method: StandardEventMethod, input: unknown): StandardEventValidation['event'] {
  const { event, problems } = validateStandardEvent(method, input);
  warnProblems(event ? `${method}: dropped` : `${method}: event dropped`, problems);
  return event;
}

/** Records `registration`: the user signed up (`method`: `anonymous`, `apple`, `google`, `email`, …). */
function trackRegistration(event?: KerdlyRegistrationEvent): void {
  try {
    const clean = validStandardEvent('trackRegistration', event);
    if (!clean) return;
    void callNative('trackRegistration', clean.fields.method, clean.properties);
  } catch (error) {
    devWarn('trackRegistration failed:', error);
  }
}

/** Records `start_trial`. `value` is what the user paid (0 for a free trial) and needs `currency`. */
function trackStartTrial(event?: KerdlyRevenueEvent): void {
  try {
    const clean = validStandardEvent('trackStartTrial', event);
    if (!clean) return;
    const { productId, value, currency, transactionId } = clean.fields;
    void callNative('trackStartTrial', productId, value, currency, transactionId, clean.properties);
  } catch (error) {
    devWarn('trackStartTrial failed:', error);
  }
}

/** Records `subscribe`: the first paid period started. `value` needs `currency`. */
function trackSubscribe(event?: KerdlyRevenueEvent): void {
  try {
    const clean = validStandardEvent('trackSubscribe', event);
    if (!clean) return;
    const { productId, value, currency, transactionId } = clean.fields;
    void callNative('trackSubscribe', productId, value, currency, transactionId, clean.properties);
  } catch (error) {
    devWarn('trackSubscribe failed:', error);
  }
}

/** Records `purchase`: a one-time purchase. `value` needs `currency`; `quantity` is an integer ≥ 1. */
function trackPurchase(event?: KerdlyPurchaseEvent): void {
  try {
    const clean = validStandardEvent('trackPurchase', event);
    if (!clean) return;
    const { productId, value, currency, quantity, transactionId } = clean.fields;
    void callNative('trackPurchase', productId, value, currency, quantity, transactionId, clean.properties);
  } catch (error) {
    devWarn('trackPurchase failed:', error);
  }
}

/** Updates consent flags; an omitted flag keeps its current value. */
function setConsent(consent: KerdlyConsent): void {
  try {
    if (consent === null || typeof consent !== 'object') {
      devWarn('setConsent: expected { analytics?: boolean, ads?: boolean }; ignored');
      return;
    }
    const flag = (name: 'analytics' | 'ads'): boolean | null => {
      const value: unknown = consent[name];
      if (value === undefined || value === null) return null;
      if (typeof value === 'boolean') return value;
      devWarn(`setConsent: \`${name}\` must be a boolean, got ${shown(value)}; ignored`);
      return null;
    };
    const analytics = flag('analytics');
    const ads = flag('ads');
    if (analytics === null && ads === null) {
      devWarn('setConsent: neither `analytics` nor `ads` was given; nothing to change');
      return;
    }
    void callNative('setConsent', analytics, ads);
  } catch (error) {
    devWarn('setConsent failed:', error);
  }
}

/**
 * Hands a deep link to the native SDK (which records `$deeplink`) and returns what it parsed.
 * With `autoDeepLinks` on (the default) Linking URLs are already forwarded: use this only for
 * URLs that do not arrive through React Native's `Linking`.
 */
async function handleUrl(url: string): Promise<KerdlyDeepLink | null> {
  try {
    if (typeof url !== 'string' || url.length === 0) {
      devWarn(`handleUrl: expected a URL string, got ${shown(url)}`);
      return null;
    }
    return normalizeDeepLink(await callNative('handleUrl', url, null));
  } catch (error) {
    devWarn('handleUrl failed:', error);
    return null;
  }
}

/**
 * Sets (or, with `null`, clears) the account token the app's purchases carry. iOS: the StoreKit
 * `appAccountToken` UUID. Android: the Play `obfuscatedAccountId` (a UUID, or Superwall's
 * `$SuperwallAlias:<uuid>` before identify).
 */
function setAppAccountToken(token: string | null): void {
  try {
    if (token === null || token === undefined) {
      void callNative('setAppAccountToken', null);
    } else if (typeof token !== 'string' || token.trim().length === 0) {
      devWarn(`setAppAccountToken: expected a token string or null, got ${shown(token)}; ignored`);
    } else if (Platform.OS === 'ios' && !isUuid(token)) {
      devWarn(`setAppAccountToken: iOS takes the StoreKit appAccountToken UUID, got ${shown(token)}; ignored`);
    } else {
      void callNative('setAppAccountToken', token);
    }
  } catch (error) {
    devWarn('setAppAccountToken failed:', error);
  }
}

/** Ids of other SDKs (e.g. `meta_anon_id`, `superwall_alias`) for the collector to join on. */
function setPartnerIds(ids: Record<string, string>): void {
  try {
    const { ids: clean, problems } = sanitizePartnerIds(ids);
    warnProblems('setPartnerIds: ignored', problems);
    if (!clean) return;
    if (Object.keys(clean).length === 0 && problems.length > 0) return;
    void callNative('setPartnerIds', clean);
  } catch (error) {
    devWarn('setPartnerIds failed:', error);
  }
}

/**
 * Links a store purchase to this install (`$purchase_link`, once per transaction / token).
 * Accepts the iOS or the Android shape. On iOS, calling it without a purchase sweeps
 * `Transaction.currentEntitlements`; Android needs `purchaseToken`.
 */
function notifyPurchase(purchase?: KerdlyPurchase | null): void {
  try {
    const { purchase: clean, problems } = sanitizePurchase(purchase);
    warnProblems('notifyPurchase: ignored', problems);
    if (purchase !== undefined && purchase !== null && clean === null) return;
    if (Platform.OS === 'android' && !clean?.purchaseToken) {
      devWarn('notifyPurchase: Android needs the purchase `purchaseToken`; ignored');
      return;
    }
    void callNative('notifyPurchase', clean);
  } catch (error) {
    devWarn('notifyPurchase failed:', error);
  }
}

/** Records a conversion the app sent to an ad network itself (`$network_send`). */
function recordNetworkSend(send: KerdlyNetworkSend): void {
  try {
    const { send: clean, problems } = sanitizeNetworkSend(send);
    warnProblems('recordNetworkSend: ignored', problems);
    if (!clean) return;
    void callNative('recordNetworkSend', clean);
  } catch (error) {
    devWarn('recordNetworkSend failed:', error);
  }
}

/** The cached attribution, or `null` until the collector has decided one. */
async function getAttribution(): Promise<KerdlyAttribution | null> {
  try {
    return normalizeAttribution(await callNative('getAttribution'));
  } catch (error) {
    devWarn('getAttribution failed:', error);
    return null;
  }
}

/**
 * Calls `listener` with the current attribution at once (when already known) and whenever the
 * native SDK reports a new one, like the native `Kerdly.onAttribution`.
 */
function addAttributionListener(listener: KerdlyAttributionListener): KerdlySubscription {
  try {
    if (typeof listener !== 'function') {
      devWarn('addAttributionListener: listener must be a function');
      return NOOP_SUBSCRIPTION;
    }
    const native = getNativeModule();
    if (!native || typeof native.addListener !== 'function') return NOOP_SUBSCRIPTION;
    let removed = false;
    let delivered = false;
    const deliver = (attribution: KerdlyAttribution): void => {
      delivered = true;
      try {
        listener(attribution);
      } catch (error) {
        devError('An attribution listener threw:', error);
      }
    };
    const subscription = native.addListener(ATTRIBUTION_EVENT, (payload: unknown) => {
      const attribution = normalizeAttribution(payload);
      if (attribution) deliver(attribution);
      else devWarn('Ignored a malformed onAttribution event:', payload);
    });
    // The native handler is registered once per process, so its "at once" call happened before
    // this listener existed; replay the cached value unless an event got here first.
    void callNative('getAttribution').then((payload) => {
      if (removed || delivered) return;
      const attribution = normalizeAttribution(payload);
      if (attribution) deliver(attribution);
    });
    return {
      remove() {
        if (removed) return;
        removed = true;
        try {
          subscription?.remove();
        } catch (error) {
          devWarn('Removing the attribution listener failed:', error);
        }
      },
    };
  } catch (error) {
    devWarn('addAttributionListener failed:', error);
    return NOOP_SUBSCRIPTION;
  }
}

/**
 * iOS: shows the App Tracking Transparency prompt (needs `NSUserTrackingUsageDescription`, which
 * the config plugin's `userTrackingPermission` sets) and resolves the resulting status.
 * Android: resolves `not_applicable`.
 */
async function requestTrackingAuthorization(): Promise<KerdlyAttStatus> {
  try {
    if (Platform.OS !== 'ios') return 'not_applicable';
    const status = await callNative('requestTrackingAuthorization');
    return typeof status === 'string' && (ATT_STATUSES as readonly string[]).includes(status)
      ? (status as KerdlyAttStatus)
      : 'not_determined';
  } catch (error) {
    devWarn('requestTrackingAuthorization failed:', error);
    return 'not_determined';
  }
}

/** Asks the native SDK to send its queue now. Resolves once the request is handed over. */
async function flush(): Promise<void> {
  try {
    await callNative('flush');
  } catch (error) {
    devWarn('flush failed:', error);
  }
}

/** The install id (a lowercase UUID), or `null` before the first `configure`. */
async function getInstallId(): Promise<string | null> {
  try {
    const id = await callNative('getInstallId');
    return typeof id === 'string' && id.length > 0 ? id : null;
  } catch (error) {
    devWarn('getInstallId failed:', error);
    return null;
  }
}

/** One network's answer to a deferred-deep-link request (`debugFetchDeferredLinks`). */
export interface KerdlyDeferredLinkAnswer {
  network: string;
  /** `link` | `none` | `error` | `skipped_att` | `skipped_consent` | `not_configured`. */
  status: string;
  url?: string;
  clickTime?: string;
  httpStatus?: number;
  detail?: string;
}

/**
 * Debug only (iOS): asks Meta (ids from the app's Facebook config) and TikTok (`tiktokAppId`) for
 * this device's deferred deep link and resolves each network's raw answer. Sends nothing to Kerdly.
 * Asks only when the `ads` consent is on, and when tracking is authorized unless `ignoreAtt`: then
 * it asks whatever the ATT status, without the IDFA (Meta through `ep2.facebook.com`) unless
 * tracking is authorized. Android resolves `[]`.
 */
async function debugFetchDeferredLinks(
  options: { tiktokAppId?: string | null; storeAppId?: string | null; ignoreAtt?: boolean } = {},
): Promise<KerdlyDeferredLinkAnswer[]> {
  try {
    if (Platform.OS !== 'ios') return [];
    const answers = await callNative(
      'debugFetchDeferredLinks',
      options.tiktokAppId ?? null,
      options.storeAppId ?? null,
      options.ignoreAtt === true,
    );
    return Array.isArray(answers) ? (answers as KerdlyDeferredLinkAnswer[]) : [];
  } catch (error) {
    devWarn('debugFetchDeferredLinks failed:', error);
    return [];
  }
}

export const Kerdly = {
  configure,
  setUserId,
  track,
  trackRegistration,
  trackStartTrial,
  trackSubscribe,
  trackPurchase,
  setConsent,
  handleUrl,
  setAppAccountToken,
  setPartnerIds,
  notifyPurchase,
  recordNetworkSend,
  getAttribution,
  addAttributionListener,
  requestTrackingAuthorization,
  flush,
  getInstallId,
  debugFetchDeferredLinks,
};

export type KerdlyApi = typeof Kerdly;
