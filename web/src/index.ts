/**
 * `@kerdly/web`: first-party visit and click touches for web-to-app attribution
 * (`POST <endpoint>/v1/web/touch`), and the visitor's link to the site's own user id
 * (`POST <endpoint>/v1/web/identify`). Importing this module has no side effects.
 */

export { DEFAULT_ENDPOINT, createKerdly } from "./client.js";
export type { Kerdly, KerdlyIdentify, KerdlyOptions, KerdlyTouch, KerdlyTouchCookies, KerdlyTouchKind, KerdlyVisitOptions } from "./types.js";
