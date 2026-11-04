import type { NativeNetworkSend, NativePurchase } from './native';
import type { KerdlyEventValue } from './types';

// Custom and standard event rules: the same rules the native SDKs apply before enqueue.
export const EVENT_NAME_PATTERN = /^[a-z][a-z0-9_]{0,39}$/;
export const PROP_KEY_PATTERN = /^[a-z][a-z0-9_]{0,39}$/;
export const MAX_PROPS = 25;
export const MAX_STRING_LENGTH = 256;
export const MAX_ID_LENGTH = 128;
export const MAX_METHOD_LENGTH = 64;
/** The native `Int` (32-bit on Android). */
export const MAX_QUANTITY = 2_147_483_647;
const CURRENCY_PATTERN = /^[A-Z]{3}$/;

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
  const proto = Object.getPrototypeOf(value);
  return proto === Object.prototype || proto === null;
}

export function isUuid(value: unknown): value is string {
  return typeof value === 'string' && UUID_PATTERN.test(value);
}

/** Cuts to 256 UTF-16 units without leaving half of a surrogate pair at the end. */
export function truncate(value: string, max = MAX_STRING_LENGTH): string {
  if (value.length <= max) return value;
  let cut = value.slice(0, max);
  const last = cut.charCodeAt(cut.length - 1);
  if (last >= 0xd800 && last <= 0xdbff) cut = cut.slice(0, -1);
  return cut;
}

function describe(value: unknown): string {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  if (typeof value === 'number') return String(value);
  return typeof value;
}

function quoted(value: unknown): string {
  return typeof value === 'string' ? JSON.stringify(value) : describe(value);
}

export interface EventValidation {
  /** `null` when the event must be dropped (invalid name or props argument). */
  event: { name: string; properties: Record<string, KerdlyEventValue> } | null;
  /** Human-readable reasons for everything that was dropped. */
  problems: string[];
}

/**
 * Validates a custom event. An invalid name drops the event. Invalid props are
 * dropped one by one; props beyond the 25th valid one are dropped; strings are truncated to 256
 * characters. `undefined` values are skipped silently, like JSON does.
 */
export function validateEvent(name: unknown, properties: unknown): EventValidation {
  const problems: string[] = [];
  if (typeof name !== 'string' || !EVENT_NAME_PATTERN.test(name)) {
    const shown = typeof name === 'string' ? JSON.stringify(name) : describe(name);
    problems.push(
      typeof name === 'string' && name.startsWith('$')
        ? `event name ${shown} is reserved: "$" events are sent by the SDK itself`
        : `event name ${shown} must match ${EVENT_NAME_PATTERN} (lowercase letters, digits, "_"; at most 40 characters)`
    );
    return { event: null, problems };
  }
  if (properties !== undefined && properties !== null && !isPlainObject(properties)) {
    problems.push(`properties must be a plain object, got ${describe(properties)}`);
    return { event: null, problems };
  }
  return { event: { name, properties: cleanProperties(properties ?? {}, problems) }, problems };
}

/** The custom-event prop rules; what is dropped is appended to `problems`. */
function cleanProperties(properties: Record<string, unknown>, problems: string[]): Record<string, KerdlyEventValue> {
  const clean: Record<string, KerdlyEventValue> = {};
  let count = 0;
  const overflow: string[] = [];
  for (const [key, value] of Object.entries(properties)) {
    if (value === undefined) continue;
    if (!PROP_KEY_PATTERN.test(key)) {
      problems.push(`property key ${JSON.stringify(key)} must match ${PROP_KEY_PATTERN}`);
      continue;
    }
    let accepted: KerdlyEventValue;
    if (typeof value === 'string') {
      accepted = truncate(value);
    } else if (typeof value === 'number' && Number.isFinite(value)) {
      accepted = value;
    } else if (typeof value === 'boolean') {
      accepted = value;
    } else {
      problems.push(
        `property "${key}" has an unsupported value (${describe(value)}): use a string, a finite number or a boolean`
      );
      continue;
    }
    if (count >= MAX_PROPS) {
      overflow.push(key);
      continue;
    }
    clean[key] = accepted;
    count += 1;
  }
  if (overflow.length > 0) {
    problems.push(`more than ${MAX_PROPS} properties; dropped ${overflow.map((k) => `"${k}"`).join(', ')}`);
  }
  return clean;
}

/** A non-empty string, or a safe integer turned into one (store ids are sometimes numbers). */
function idString(value: unknown): string | undefined {
  if (typeof value === 'string') return value.length > 0 ? value : undefined;
  if (typeof value === 'number' && Number.isSafeInteger(value)) return String(value);
  return undefined;
}

function optionalString(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

export type StandardEventMethod = 'trackRegistration' | 'trackStartTrial' | 'trackSubscribe' | 'trackPurchase';

type StandardField = 'method' | 'productId' | 'value' | 'currency' | 'quantity' | 'transactionId';

/** The typed fields of each standard event. */
const STANDARD_FIELDS: Record<StandardEventMethod, readonly StandardField[]> = {
  trackRegistration: ['method'],
  trackStartTrial: ['productId', 'value', 'currency', 'transactionId'],
  trackSubscribe: ['productId', 'value', 'currency', 'transactionId'],
  trackPurchase: ['productId', 'value', 'currency', 'quantity', 'transactionId'],
};

/** The wire prop each typed field becomes. */
const PROP_NAMES: Record<StandardField, string> = {
  method: 'method',
  productId: 'product_id',
  value: 'value',
  currency: 'currency',
  quantity: 'quantity',
  transactionId: 'transaction_id',
};

/** The typed fields after validation; `null` = omitted (fields an event does not have stay `null`). */
export type StandardFields = Record<'method' | 'productId' | 'currency' | 'transactionId', string | null> &
  Record<'value' | 'quantity', number | null>;

export interface StandardEventValidation {
  /** `null` when the event must be dropped (the argument is not an object). */
  event: { fields: StandardFields; properties: Record<string, KerdlyEventValue> } | null;
  /** Human-readable reasons for everything that was dropped. */
  problems: string[];
}

/**
 * Validates a standard event's typed fields. A malformed field is dropped, not the
 * event: ids are non-empty strings (a safe integer is turned into one) cut to 128 characters,
 * `method` a non-empty string cut to 64, `value` a finite number ≥ 0, `currency` three letters
 * (upper-cased), `quantity` an integer ≥ 1. `value` is dropped without a valid `currency`.
 * `properties` follows the custom-event rules; a key that is one of the event's typed props is
 * dropped (the typed field sets it). The native SDK checks everything again.
 */
export function validateStandardEvent(method: StandardEventMethod, input: unknown): StandardEventValidation {
  const problems: string[] = [];
  if (input !== undefined && input !== null && !isPlainObject(input)) {
    problems.push(`expected an object of fields, got ${describe(input)}`);
    return { event: null, problems };
  }
  const given: Record<string, unknown> = isPlainObject(input) ? input : {};
  const allowed = STANDARD_FIELDS[method];
  const fields: StandardFields = {
    method: null,
    productId: null,
    value: null,
    currency: null,
    quantity: null,
    transactionId: null,
  };

  for (const [key, raw] of Object.entries(given)) {
    if (raw === undefined || raw === null || key === 'properties') continue;
    if (!(allowed as readonly string[]).includes(key)) {
      problems.push(`unknown field "${key}" (custom props go in \`properties\`)`);
      continue;
    }
    const field = key as StandardField;
    if (field === 'productId' || field === 'transactionId') {
      const id = idString(raw);
      if (id === undefined) problems.push(`${field} must be a non-empty string, got ${quoted(raw)}`);
      else fields[field] = truncate(id, MAX_ID_LENGTH);
    } else if (field === 'method') {
      const text = optionalString(raw);
      if (text === undefined) problems.push(`method must be a non-empty string, got ${quoted(raw)}`);
      else fields.method = truncate(text, MAX_METHOD_LENGTH);
    } else if (field === 'value') {
      if (typeof raw === 'number' && Number.isFinite(raw) && raw >= 0) fields.value = raw;
      else problems.push(`value must be a finite number ≥ 0, got ${quoted(raw)}`);
    } else if (field === 'currency') {
      const code = typeof raw === 'string' ? raw.toUpperCase() : undefined;
      if (code !== undefined && CURRENCY_PATTERN.test(code)) fields.currency = code;
      else problems.push(`currency must be a three-letter ISO 4217 code, got ${quoted(raw)}`);
    } else {
      if (typeof raw === 'number' && Number.isInteger(raw) && raw >= 1 && raw <= MAX_QUANTITY) fields.quantity = raw;
      else problems.push(`quantity must be an integer ≥ 1, got ${quoted(raw)}`);
    }
  }
  if (fields.value !== null && fields.currency === null) {
    problems.push('value needs a valid currency, so it was dropped');
    fields.value = null;
  }

  let properties: Record<string, KerdlyEventValue> = {};
  const extra = given.properties;
  if (extra !== undefined && extra !== null) {
    if (!isPlainObject(extra)) {
      problems.push(`properties must be a plain object, got ${describe(extra)}`);
    } else {
      const custom: Record<string, unknown> = {};
      for (const [key, value] of Object.entries(extra)) {
        const field = allowed.find((f) => PROP_NAMES[f] === key);
        if (field === undefined) custom[key] = value;
        else if (value !== undefined) problems.push(`property "${key}" is a typed prop: pass it as \`${field}\``);
      }
      properties = cleanProperties(custom, problems);
    }
  }
  return { event: { fields, properties }, problems };
}

const PURCHASE_ID_FIELDS = [
  'originalTransactionId',
  'transactionId',
  'productId',
  'purchaseToken',
  'orderId',
] as const;

const PURCHASE_STRING_FIELDS = ['obfuscatedAccountId', 'obfuscatedProfileId'] as const;

/**
 * Keeps the fields of either purchase shape that have the right type, so a malformed field can't
 * make the native argument conversion reject the whole purchase. Returns `null` for a missing
 * purchase (on iOS that means "sweep current entitlements").
 */
export function sanitizePurchase(purchase: unknown): { purchase: NativePurchase | null; problems: string[] } {
  const problems: string[] = [];
  if (purchase === undefined || purchase === null) return { purchase: null, problems };
  if (!isPlainObject(purchase)) {
    problems.push(`purchase must be an object, got ${describe(purchase)}`);
    return { purchase: null, problems };
  }
  const out: NativePurchase = {};
  for (const field of PURCHASE_ID_FIELDS) {
    const raw = purchase[field];
    if (raw === undefined || raw === null) continue;
    const value = idString(raw);
    if (value === undefined) problems.push(`purchase.${field} must be a non-empty string`);
    else out[field] = value;
  }
  for (const field of PURCHASE_STRING_FIELDS) {
    const raw = purchase[field];
    if (raw === undefined || raw === null) continue;
    const value = optionalString(raw);
    if (value === undefined) problems.push(`purchase.${field} must be a non-empty string`);
    else out[field] = value;
  }
  const token = purchase.appAccountToken;
  if (token !== undefined && token !== null) {
    if (isUuid(token)) out.appAccountToken = token;
    else problems.push('purchase.appAccountToken must be a UUID string');
  }
  const products = purchase.products;
  if (products !== undefined && products !== null) {
    const list = typeof products === 'string' ? [products] : products;
    if (Array.isArray(list)) {
      const valid = list.filter((p): p is string => typeof p === 'string' && p.length > 0);
      if (valid.length !== list.length) problems.push('purchase.products must contain only non-empty strings');
      if (valid.length > 0) out.products = valid;
    } else {
      problems.push('purchase.products must be an array of strings');
    }
  }
  const time = purchase.purchaseTime;
  if (time !== undefined && time !== null) {
    if (typeof time === 'number' && Number.isFinite(time) && time > 0) out.purchaseTime = Math.round(time);
    else problems.push('purchase.purchaseTime must be milliseconds since epoch');
  }
  return { purchase: out, problems };
}

/** `null` when `network` or `event` is missing; optional fields with the wrong type are dropped. */
export function sanitizeNetworkSend(send: unknown): { send: NativeNetworkSend | null; problems: string[] } {
  const problems: string[] = [];
  if (!isPlainObject(send)) {
    problems.push(`recordNetworkSend needs an object, got ${describe(send)}`);
    return { send: null, problems };
  }
  const network = optionalString(send.network);
  const event = optionalString(send.event);
  if (network === undefined || event === undefined) {
    problems.push('recordNetworkSend needs non-empty `network` and `event` strings');
    return { send: null, problems };
  }
  const out: NativeNetworkSend = { network, event };
  const eventId = send.eventId;
  if (eventId !== undefined && eventId !== null) {
    const value = idString(eventId);
    if (value === undefined) problems.push('eventId must be a non-empty string');
    else out.eventId = value;
  }
  const value = send.value;
  if (value !== undefined && value !== null) {
    if (typeof value === 'number' && Number.isFinite(value)) out.value = value;
    else problems.push('value must be a finite number');
  }
  for (const field of ['currency', 'flag'] as const) {
    const raw = send[field];
    if (raw === undefined || raw === null) continue;
    const str = optionalString(raw);
    if (str === undefined) problems.push(`${field} must be a non-empty string`);
    else out[field] = str;
  }
  return { send: out, problems };
}

/** Keeps the string -> string entries of a partner id map. */
export function sanitizePartnerIds(ids: unknown): { ids: Record<string, string> | null; problems: string[] } {
  const problems: string[] = [];
  if (!isPlainObject(ids)) {
    problems.push(`setPartnerIds needs an object of strings, got ${describe(ids)}`);
    return { ids: null, problems };
  }
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(ids)) {
    if (value === undefined) continue;
    if (typeof value === 'string' && key.length > 0) out[key] = value;
    else problems.push(`partner id "${key}" must be a string, got ${describe(value)}`);
  }
  return { ids: out, problems };
}
