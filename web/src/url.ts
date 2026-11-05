/**
 * URL helpers: reading a page parameter and decorating link URLs with `kerdly_v`.
 */

/** The visit-chain parameter: a link decorated with it continues this visitor's chain. */
export const VISIT_PARAM = "kerdly_v";
/** The same parameter as links made before 0.1.0 spell it: read, never written. */
export const LEGACY_VISIT_PARAM = "afr_v";

const ANY_SCHEME = /^[a-z][a-z\d+.-]*:/i;
const HTTP_SCHEME = /^https?:/i;

/** One parameter of a `location.search` string, trimmed; `null` when absent or empty. */
export function queryParam(search: string, name: string): string | null {
  try {
    const value = new URLSearchParams(search).get(name);
    return (value && value.trim()) || null;
  } catch {
    return null;
  }
}

/**
 * `url` with its `name` parameters removed and, unless `value` is null, `name=value` appended.
 * Everything else (the other parameters, their order and encoding, the fragment) stays exactly as
 * written. A URL that already carries `name=value` once is returned as it is. URLs with a scheme
 * other than http(s) (`mailto:`, `tel:`, `javascript:`) are never changed.
 */
export function withQueryParam(url: string, name: string, value: string | null): string {
  if (!url || (ANY_SCHEME.test(url) && !HTTP_SCHEME.test(url))) return url;
  const hashAt = url.indexOf("#");
  const beforeHash = hashAt === -1 ? url : url.slice(0, hashAt);
  const hash = hashAt === -1 ? "" : url.slice(hashAt);
  const queryAt = beforeHash.indexOf("?");
  const base = queryAt === -1 ? beforeHash : beforeHash.slice(0, queryAt);
  const params = queryAt === -1 ? [] : beforeHash.slice(queryAt + 1).split("&");
  const ours = params.filter((p) => p.split("=")[0] === name);
  const wanted = value === null ? null : `${name}=${encodeURIComponent(value)}`;
  if (wanted !== null && ours.length === 1 && ours[0] === wanted) return url;
  if (wanted === null && ours.length === 0) return url;
  const kept = params.filter((p) => p !== "" && p.split("=")[0] !== name);
  if (wanted !== null) kept.push(wanted);
  return base + (kept.length ? `?${kept.join("&")}` : "") + hash;
}

/** The visit a page URL continues: its `kerdly_v` parameter, else its `afr_v`. */
export function visitParam(search: string): string | null {
  return queryParam(search, VISIT_PARAM) || queryParam(search, LEGACY_VISIT_PARAM);
}

/** `url` without any visit parameter, in either spelling. */
export function withoutVisitParam(url: string): string {
  return withQueryParam(withQueryParam(url, LEGACY_VISIT_PARAM, null), VISIT_PARAM, null);
}

/** `url` with `kerdly_v=<visitor id>`; idempotent, and never two visit parameters. */
export function decorateUrl(url: string, visitorId: string): string {
  return visitorId ? withQueryParam(withQueryParam(url, LEGACY_VISIT_PARAM, null), VISIT_PARAM, visitorId) : url;
}
