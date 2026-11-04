// @ts-check
// Expo config plugin for @kerdly/expo. Plain CommonJS on purpose: it needs no build step, so it
// works straight from a git checkout or a `file:` install. Type-checked by tsc (checkJs).

const pkg = require('../package.json');

/** @returns {typeof import('@expo/config-plugins')} */
function loadConfigPlugins() {
  try {
    // The app's own copy, as Expo recommends for plugins. `expo` is not a dev dependency here.
    // @ts-ignore
    return require('expo/config-plugins');
  } catch {
    return require('@expo/config-plugins');
  }
}

const { AndroidConfig, WarningAggregator, createRunOncePlugin, withAndroidManifest, withInfoPlist, withStringsXml } =
  loadConfigPlugins();

/** Manifest meta-data the native Android SDK (and this module's bridge) reads when `configure` gets no `metaAppId`. */
const META_APP_ID_KEY = 'com.kerdly.sdk.META_APP_ID';

/**
 * The id goes through a string resource: a literal `android:value="1234567890123456"` is compiled
 * as a number, not a string, and `Bundle.getString` would not return it.
 */
const META_APP_ID_STRING = 'afr_meta_app_id';

/**
 * @typedef {object} KerdlyPluginProps
 * @property {string} [metaAppId] Android: the Facebook app id, written to the
 *   `com.kerdly.sdk.META_APP_ID` manifest meta-data (enables the Meta Install Referrer read).
 * @property {string} [userTrackingPermission] iOS: `NSUserTrackingUsageDescription`, the text of the
 *   App Tracking Transparency prompt.
 * @property {string} [skanEndpoint] iOS: `NSAdvertisingAttributionReportEndpoint`, the https origin
 *   that receives copies of SKAdNetwork postbacks (e.g. `https://sdk.example.com`).
 */

/**
 * @typedef {object} NormalizedProps
 * @property {string | null} metaAppId
 * @property {string | null} userTrackingPermission
 * @property {string | null} skanEndpoint
 */

/**
 * @param {unknown} value
 * @param {string} name
 * @returns {string | null}
 */
function optionalString(value, name) {
  if (value === undefined || value === null) return null;
  if (typeof value === 'string') return value.trim().length > 0 ? value.trim() : null;
  throw new Error(`[@kerdly/expo] plugin option \`${name}\` must be a string, got ${typeof value}`);
}

/**
 * @param {unknown} props
 * @returns {NormalizedProps}
 */
function normalizeProps(props) {
  if (props === undefined || props === null) {
    return { metaAppId: null, userTrackingPermission: null, skanEndpoint: null };
  }
  if (typeof props !== 'object' || Array.isArray(props)) {
    throw new Error('[@kerdly/expo] plugin options must be an object');
  }
  const raw = /** @type {Record<string, unknown>} */ (props);
  // An app id written as a JSON number is accepted (ids are below 2^53).
  const metaAppIdRaw = typeof raw.metaAppId === 'number' && Number.isSafeInteger(raw.metaAppId) ? String(raw.metaAppId) : raw.metaAppId;
  const metaAppId = optionalString(metaAppIdRaw, 'metaAppId');
  if (metaAppId !== null && !/^\d+$/.test(metaAppId)) {
    WarningAggregator.addWarningAndroid('@kerdly/expo', `metaAppId "${metaAppId}" is not numeric; Facebook app ids are digits only.`);
  }
  const skanEndpoint = optionalString(raw.skanEndpoint, 'skanEndpoint');
  if (skanEndpoint !== null && !/^https:\/\/[^/?#\s]+\/?$/.test(skanEndpoint)) {
    WarningAggregator.addWarningIOS(
      '@kerdly/expo',
      `skanEndpoint "${skanEndpoint}" should be a bare https origin such as https://sdk.example.com; Apple appends /.well-known/skadnetwork/report-attribution/ itself.`
    );
  }
  return {
    metaAppId,
    userTrackingPermission: optionalString(raw.userTrackingPermission, 'userTrackingPermission'),
    skanEndpoint,
  };
}

/**
 * Sets the given keys; never removes a key, so values the app sets in `ios.infoPlist` survive.
 * @param {import('@expo/config-plugins').InfoPlist} infoPlist
 * @param {NormalizedProps} props
 */
function applyInfoPlist(infoPlist, props) {
  if (props.userTrackingPermission !== null) {
    infoPlist.NSUserTrackingUsageDescription = props.userTrackingPermission;
  }
  if (props.skanEndpoint !== null) {
    infoPlist.NSAdvertisingAttributionReportEndpoint = props.skanEndpoint;
  }
  return infoPlist;
}

/**
 * Adds (or replaces) the meta-data item, or removes it when there is no id.
 * @param {import('@expo/config-plugins').AndroidConfig.Manifest.AndroidManifest} manifest
 * @param {string | null} metaAppId
 */
function applyMetaAppIdToManifest(manifest, metaAppId) {
  const application = AndroidConfig.Manifest.getMainApplicationOrThrow(manifest);
  if (metaAppId !== null) {
    AndroidConfig.Manifest.addMetaDataItemToMainApplication(application, META_APP_ID_KEY, `@string/${META_APP_ID_STRING}`, 'value');
  } else {
    AndroidConfig.Manifest.removeMetaDataItemFromMainApplication(application, META_APP_ID_KEY);
  }
  return manifest;
}

/**
 * @param {import('@expo/config-plugins').AndroidConfig.Resources.ResourceXML} strings
 * @param {string | null} metaAppId
 */
function applyMetaAppIdToStrings(strings, metaAppId) {
  if (metaAppId !== null) {
    const item = AndroidConfig.Resources.buildResourceItem({ name: META_APP_ID_STRING, value: metaAppId, translatable: false });
    return AndroidConfig.Strings.setStringItem([item], strings);
  }
  return AndroidConfig.Strings.removeStringItem(META_APP_ID_STRING, strings);
}

/** @type {import('@expo/config-plugins').ConfigPlugin<KerdlyPluginProps | void>} */
const withKerdlySdk = (config, props) => {
  const options = normalizeProps(props);
  config = withInfoPlist(config, (cfg) => {
    cfg.modResults = applyInfoPlist(cfg.modResults, options);
    return cfg;
  });
  config = withStringsXml(config, (cfg) => {
    cfg.modResults = applyMetaAppIdToStrings(cfg.modResults, options.metaAppId);
    return cfg;
  });
  config = withAndroidManifest(config, (cfg) => {
    cfg.modResults = applyMetaAppIdToManifest(cfg.modResults, options.metaAppId);
    return cfg;
  });
  return config;
};

const withKerdly = createRunOncePlugin(withKerdlySdk, pkg.name, pkg.version);

module.exports = {
  withKerdly,
  normalizeProps,
  applyInfoPlist,
  applyMetaAppIdToManifest,
  applyMetaAppIdToStrings,
  META_APP_ID_KEY,
  META_APP_ID_STRING,
};
