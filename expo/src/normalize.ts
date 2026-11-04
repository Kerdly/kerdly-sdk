import { isPlainObject } from './validation';
import type { KerdlyAttribution, KerdlyDeepLink } from './types';

// The bridges send camelCase keys. snake_case (the protocol's JSON names) is accepted too, so a
// payload that is the collector's raw attribution object still normalises.

function str(source: Record<string, unknown>, camel: string, snake?: string): string | null {
  const value = source[camel] ?? (snake === undefined ? undefined : source[snake]);
  if (typeof value === 'string') return value;
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  return null;
}

function millis(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string' && value.length > 0) {
    const asNumber = Number(value);
    if (Number.isFinite(asNumber)) return asNumber;
    const parsed = Date.parse(value);
    return Number.isNaN(parsed) ? null : parsed;
  }
  return null;
}

function rawObject(value: unknown): Record<string, unknown> | null {
  if (isPlainObject(value)) return value;
  if (typeof value === 'string' && value.length > 0) {
    try {
      const parsed: unknown = JSON.parse(value);
      return isPlainObject(parsed) ? parsed : null;
    } catch {
      return null;
    }
  }
  return null;
}

export function normalizeDeepLink(payload: unknown): KerdlyDeepLink | null {
  if (!isPlainObject(payload)) return null;
  const url = str(payload, 'url');
  if (url === null) return null;
  return {
    url,
    cpp: str(payload, 'cpp'),
    ppid: str(payload, 'ppid'),
    afrC: str(payload, 'afrC', 'afr_c'),
    afrV: str(payload, 'afrV', 'afr_v'),
    campaignIds: str(payload, 'campaignIds', 'campaign_ids'),
  };
}

/**
 * iOS sends `raw` as an object, Android as the JSON string (Kotlin `KerdlyAttribution.raw: String`);
 * both become an object here.
 */
export function normalizeAttribution(payload: unknown): KerdlyAttribution | null {
  if (!isPlainObject(payload)) return null;
  const state = str(payload, 'state');
  const network = str(payload, 'network');
  const status = str(payload, 'status');
  const method = str(payload, 'method');
  if (state === null || network === null || status === null || method === null) return null;
  const { raw: rawField, ...fields } = payload;
  return {
    state,
    network,
    status,
    method,
    campaignId: str(payload, 'campaignId', 'campaign_id'),
    campaign: str(payload, 'campaign'),
    adsetId: str(payload, 'adsetId', 'adset_id'),
    adset: str(payload, 'adset'),
    adId: str(payload, 'adId', 'ad_id'),
    ad: str(payload, 'ad'),
    keywordId: str(payload, 'keywordId', 'keyword_id'),
    keyword: str(payload, 'keyword'),
    linkId: str(payload, 'linkId', 'link_id'),
    cppId: str(payload, 'cppId', 'cpp_id'),
    decidedAt: millis(payload.decidedAt ?? payload.decided_at),
    raw: rawObject(rawField) ?? fields,
  };
}
