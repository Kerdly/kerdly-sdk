import type { KerdlyLogLevel } from './types';

const RANK: Record<KerdlyLogLevel, number> = { none: 0, error: 1, warn: 2, info: 3, debug: 4 };

let threshold: KerdlyLogLevel = 'warn';

export function setLogLevel(level: KerdlyLogLevel): void {
  threshold = level;
}

export function isLogLevel(value: unknown): value is KerdlyLogLevel {
  return typeof value === 'string' && Object.prototype.hasOwnProperty.call(RANK, value);
}

function isDev(): boolean {
  return typeof __DEV__ !== 'undefined' && __DEV__ === true;
}

/**
 * Development-only warning (never in release builds), muted by `logLevel: 'none' | 'error'`.
 * This package never throws into the app, so this is how misuse is surfaced.
 */
export function devWarn(message: string, ...details: unknown[]): void {
  if (!isDev() || RANK[threshold] < RANK.warn) return;
  try {
    console.warn(`[Kerdly] ${message}`, ...details);
  } catch {
    // console itself must never break the app
  }
}

/** Development-only error, for exceptions thrown by the app's own callbacks. */
export function devError(message: string, ...details: unknown[]): void {
  if (!isDev() || RANK[threshold] < RANK.error) return;
  try {
    console.error(`[Kerdly] ${message}`, ...details);
  } catch {
    // console itself must never break the app
  }
}

const warnedKeys = new Set<string>();

/** `devWarn`, at most once per `key` for the lifetime of the JS runtime. */
export function devWarnOnce(key: string, message: string, ...details: unknown[]): void {
  if (warnedKeys.has(key)) return;
  warnedKeys.add(key);
  devWarn(message, ...details);
}
