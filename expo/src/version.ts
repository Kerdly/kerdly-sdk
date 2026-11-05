// Must equal "version" in package.json (test/version.test.ts enforces it).
export const SDK_VERSION = '0.1.0';

/** Passed to the native SDKs as `KerdlyOptions.wrapper`; they send it in `X-Kerdly-Sdk` and `sdk.wrapper`. */
export const WRAPPER = `expo/${SDK_VERSION}`;
