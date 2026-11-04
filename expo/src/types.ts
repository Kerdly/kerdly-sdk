// Public types of @kerdly/expo. The shapes mirror the Swift/Kotlin types of the native SDKs.

/** `auto` lets the native SDK decide */
export type KerdlyEnvironment = 'auto' | 'production' | 'sandbox' | 'development';

export type KerdlyLogLevel = 'none' | 'error' | 'warn' | 'info' | 'debug';

/** App Tracking Transparency status. Android always reports `not_applicable`. */
export type KerdlyAttStatus =
  | 'authorized'
  | 'denied'
  | 'restricted'
  | 'not_determined'
  | 'not_applicable';

/** Where a deep link came from: the URL that launched the app, or one received while running. */
export type KerdlyDeepLinkSource = 'initial' | 'runtime';

export interface KerdlyConfigureOptions {
  /** The app's public key, `pk_live_…` or `pk_test_…`. */
  key: string;
  /** Base URL of the collector; `/v1/sdk/batch` etc. are appended by the native SDK. Default `https://app.kerdly.com/api`. */
  endpoint?: string;
  /** Default `auto`. */
  environment?: KerdlyEnvironment;
  /** Read IDFA (only when ATT is authorized) / GAID. Default `true`. */
  collectAdvertisingId?: boolean;
  /** iOS only: let the SDK write SKAdNetwork / AdAttributionKit conversion values. Default `false`. */
  skanWriter?: boolean;
  /**
   * Android only: the Facebook app id, which enables the Meta Install Referrer read. When omitted,
   * the `com.kerdly.sdk.META_APP_ID` manifest meta-data (written by the config plugin's `metaAppId`)
   * is used.
   */
  metaAppId?: string;
  /** Native SDK log level, and the threshold for this package's development warnings. Default `warn`. */
  logLevel?: KerdlyLogLevel;
  /**
   * Forward React Native `Linking` URLs to `handleUrl` automatically: the initial URL once
   * (source `initial`) and every `url` event (source `runtime`). Default `true`.
   */
  autoDeepLinks?: boolean;
}

/** What `handleUrl` parsed from a deep link's query string. */
export interface KerdlyDeepLink {
  url: string;
  cpp: string | null;
  ppid: string | null;
  afrC: string | null;
  afrV: string | null;
  campaignIds: string | null;
}

export interface KerdlyConsent {
  analytics?: boolean;
  ads?: boolean;
}

/** Custom event property value. */
export type KerdlyEventValue = string | number | boolean;

/** Custom event properties. `undefined` values are skipped. */
export type KerdlyEventProperties = Record<string, KerdlyEventValue | undefined>;

/** `Kerdly.trackRegistration` (standard event `registration`). Every field is optional. */
export interface KerdlyRegistrationEvent {
  /** How the user signed up: `anonymous`, `apple`, `google`, `email`, … (cut to 64 characters). */
  method?: string | null;
  /** Extra custom props, under the custom-event rules. */
  properties?: KerdlyEventProperties;
}

/**
 * `Kerdly.trackStartTrial` and `Kerdly.trackSubscribe` (standard events `start_trial` and `subscribe`,
 *Every field is optional.
 */
export interface KerdlyRevenueEvent {
  /** The store product id (cut to 128 characters). */
  productId?: string | null;
  /** The price the user paid in `currency`: a finite number ≥ 0 (0 for a free trial). Dropped without a valid `currency`. */
  value?: number | null;
  /** ISO 4217 code, three letters; upper-cased. */
  currency?: string | null;
  /** The store transaction id (cut to 128 characters). */
  transactionId?: string | null;
  /** Extra custom props, under the custom-event rules. */
  properties?: KerdlyEventProperties;
}

/** `Kerdly.trackPurchase` (standard event `purchase`). Every field is optional. */
export interface KerdlyPurchaseEvent extends KerdlyRevenueEvent {
  /** An integer ≥ 1. */
  quantity?: number | null;
}

/** iOS (StoreKit) purchase, as reported by the paywall SDK. */
export interface KerdlyIosPurchase {
  originalTransactionId?: string | null;
  transactionId?: string | null;
  productId?: string | null;
  /** The StoreKit `appAccountToken` (a UUID string). */
  appAccountToken?: string | null;
}

/** Android (Play Billing) purchase. */
export interface KerdlyAndroidPurchase {
  purchaseToken: string;
  orderId?: string | null;
  products?: string[];
  /** Milliseconds since epoch. */
  purchaseTime?: number | null;
  obfuscatedAccountId?: string | null;
  obfuscatedProfileId?: string | null;
}

/** Either platform's purchase shape; each native SDK reads the fields of its own platform. */
export type KerdlyPurchase = KerdlyIosPurchase | KerdlyAndroidPurchase;

/** A conversion event the app sent to an ad network itself (Meta SDK, TikTok SDK, …). */
export interface KerdlyNetworkSend {
  network: string;
  event: string;
  eventId?: string | null;
  value?: number | null;
  currency?: string | null;
  flag?: string | null;
}

/** The attribution object ofUnknown future values are passed through as strings. */
export interface KerdlyAttribution {
  state: 'provisional' | 'final' | (string & {});
  network:
    | 'apple_ads'
    | 'meta'
    | 'tiktok'
    | 'google_ads'
    | 'reddit'
    | 'snap'
    | 'web'
    | 'organic'
    | 'unknown'
    | (string & {});
  status:
    | 'measured'
    | 'probabilistic'
    | 'view_through'
    | 'organic_measured'
    | 'organic_assumed'
    | (string & {});
  method:
    | 'asa_token'
    | 'play_referrer'
    | 'play_referrer_link'
    | 'meta_install_referrer'
    | 'cpp_deeplink'
    | 'visit_chain'
    | 'ip_match'
    | 'none'
    | (string & {});
  campaignId: string | null;
  campaign: string | null;
  adsetId: string | null;
  adset: string | null;
  adId: string | null;
  ad: string | null;
  keywordId: string | null;
  keyword: string | null;
  linkId: string | null;
  cppId: string | null;
  /** Milliseconds since epoch. */
  decidedAt: number | null;
  /** The whole attribution JSON object as the collector sent it. */
  raw: Record<string, unknown>;
}

export type KerdlyAttributionListener = (attribution: KerdlyAttribution) => void;

export interface KerdlySubscription {
  remove(): void;
}
