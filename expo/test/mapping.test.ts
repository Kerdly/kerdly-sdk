import { IOS_ATTRIBUTION, flushPromises, loadSdk, silenceConsole } from './helpers';

const KEY = 'pk_test_abc123';
const ENDPOINT = 'https://sdk.example.com';
const pkg = require('../package.json') as { version: string };

describe('configure', () => {
  it('passes defaults and the expo wrapper to native configure', async () => {
    const { Kerdly, native } = loadSdk();
    await Kerdly.configure({ key: KEY, endpoint: ENDPOINT, autoDeepLinks: false });
    expect(native!.configure).toHaveBeenCalledTimes(1);
    expect(native!.configure).toHaveBeenCalledWith({
      key: KEY,
      endpoint: ENDPOINT,
      environment: 'auto',
      collectAdvertisingId: true,
      skanWriter: false,
      logLevel: 'warn',
      wrapper: `expo/${pkg.version}`,
    });
  });

  it('maps every option', async () => {
    const { Kerdly, native } = loadSdk({ platform: 'android' });
    await Kerdly.configure({
      key: KEY,
      endpoint: ENDPOINT,
      environment: 'sandbox',
      collectAdvertisingId: false,
      skanWriter: true,
      metaAppId: '1234567890123456',
      logLevel: 'debug',
      autoDeepLinks: false,
    });
    expect(native!.configure).toHaveBeenCalledWith({
      key: KEY,
      endpoint: ENDPOINT,
      environment: 'sandbox',
      collectAdvertisingId: false,
      skanWriter: true,
      metaAppId: '1234567890123456',
      logLevel: 'debug',
      wrapper: `expo/${pkg.version}`,
    });
  });

  it('falls back to auto/warn for unknown environment and log level, with a warning', async () => {
    const { warn } = silenceConsole();
    const { Kerdly, native } = loadSdk();
    await Kerdly.configure({
      key: KEY,
      endpoint: ENDPOINT,
      environment: 'prod' as never,
      logLevel: 'verbose' as never,
      autoDeepLinks: false,
    });
    expect(native!.configure).toHaveBeenCalledWith(
      expect.objectContaining({ environment: 'auto', logLevel: 'warn' })
    );
    expect(warn).toHaveBeenCalledWith(expect.stringContaining('unknown environment'));
    expect(warn).toHaveBeenCalledWith(expect.stringContaining('unknown logLevel'));
  });

  it('does not call native without a key or with an empty endpoint', async () => {
    const { warn } = silenceConsole();
    const { Kerdly, native } = loadSdk();
    await Kerdly.configure({ key: '', endpoint: ENDPOINT });
    await Kerdly.configure({ key: KEY, endpoint: '' });
    await Kerdly.configure(undefined as never);
    expect(native!.configure).not.toHaveBeenCalled();
    expect(warn).toHaveBeenCalledTimes(3);
  });

  it('refuses a secret sk_ key', async () => {
    const { error } = silenceConsole();
    const { Kerdly, native } = loadSdk();
    await Kerdly.configure({ key: 'sk_live_abc123', endpoint: ENDPOINT });
    expect(native!.configure).not.toHaveBeenCalled();
    expect(error).toHaveBeenCalledWith(expect.stringContaining('server key (sk_'));
  });

  it('defaults the endpoint to the Kerdly collector', async () => {
    silenceConsole();
    const { Kerdly, native } = loadSdk();
    await Kerdly.configure({ key: KEY });
    expect(native!.configure).toHaveBeenCalledWith(expect.objectContaining({ endpoint: 'https://app.kerdly.com/api' }));
  });

  it('resolves even when native configure rejects', async () => {
    silenceConsole();
    const { Kerdly, native } = loadSdk();
    native!.configure.mockRejectedValueOnce(new Error('boom'));
    await expect(Kerdly.configure({ key: KEY, endpoint: ENDPOINT, autoDeepLinks: false })).resolves.toBeUndefined();
  });
});

describe('calls before configure', () => {
  it('go straight to native, in call order (the native SDK holds them until configure)', async () => {
    const { Kerdly, native } = loadSdk();
    Kerdly.setUserId('early-user');
    Kerdly.track('app_start');
    await Kerdly.configure({ key: KEY, endpoint: ENDPOINT, autoDeepLinks: false });
    const order = [native!.setUserId, native!.track, native!.configure].map(
      (fn) => fn.mock.invocationCallOrder[0]
    );
    expect(order).toEqual([...order].sort((a, b) => a - b));
  });
});

describe('fire-and-forget calls', () => {
  it('setUserId passes a string or null, ignores anything else', () => {
    const { warn } = silenceConsole();
    const { Kerdly, native } = loadSdk();
    Kerdly.setUserId('m5KwQ2xYz');
    Kerdly.setUserId(null);
    Kerdly.setUserId('');
    Kerdly.setUserId(42 as never);
    expect(native!.setUserId.mock.calls).toEqual([['m5KwQ2xYz'], [null]]);
    expect(warn).toHaveBeenCalledTimes(2);
  });

  it('track passes the name and properties', () => {
    const { Kerdly, native } = loadSdk();
    Kerdly.track('registration', { method: 'anonymous' });
    Kerdly.track('lesson_done');
    expect(native!.track.mock.calls).toEqual([
      ['registration', { method: 'anonymous' }],
      ['lesson_done', {}],
    ]);
  });

  it('setConsent passes both flags, null for an omitted one', () => {
    const { warn } = silenceConsole();
    const { Kerdly, native } = loadSdk();
    Kerdly.setConsent({ analytics: true, ads: false });
    Kerdly.setConsent({ ads: true });
    Kerdly.setConsent({});
    Kerdly.setConsent({ analytics: 'yes' as never });
    expect(native!.setConsent.mock.calls).toEqual([
      [true, false],
      [null, true],
    ]);
    expect(warn).toHaveBeenCalled();
  });

  it('setAppAccountToken on iOS passes a UUID or null and ignores anything else', () => {
    const { warn } = silenceConsole();
    const { Kerdly, native } = loadSdk({ platform: 'ios' });
    Kerdly.setAppAccountToken('3F2504E0-4F89-41D3-9A0C-0305E82C3301');
    Kerdly.setAppAccountToken(null);
    Kerdly.setAppAccountToken('$SuperwallAlias:3F2504E0-4F89-41D3-9A0C-0305E82C3301');
    Kerdly.setAppAccountToken('');
    expect(native!.setAppAccountToken.mock.calls).toEqual([['3F2504E0-4F89-41D3-9A0C-0305E82C3301'], [null]]);
    expect(warn).toHaveBeenCalledTimes(2);
  });

  it('setAppAccountToken on Android passes any token string (the Play obfuscatedAccountId)', () => {
    const { Kerdly, native } = loadSdk({ platform: 'android' });
    Kerdly.setAppAccountToken('$SuperwallAlias:3F2504E0-4F89-41D3-9A0C-0305E82C3301');
    Kerdly.setAppAccountToken('3f2504e0-4f89-41d3-9a0c-0305e82c3301');
    expect(native!.setAppAccountToken.mock.calls).toEqual([
      ['$SuperwallAlias:3F2504E0-4F89-41D3-9A0C-0305E82C3301'],
      ['3f2504e0-4f89-41d3-9a0c-0305e82c3301'],
    ]);
  });

  it('setPartnerIds keeps string values only', () => {
    silenceConsole();
    const { Kerdly, native } = loadSdk();
    Kerdly.setPartnerIds({ meta_anon_id: 'XZ1', superwall_alias: '$SuperwallAlias:3F2504E0', bad: 7 as never });
    Kerdly.setPartnerIds({ only_bad: null as never });
    expect(native!.setPartnerIds.mock.calls).toEqual([
      [{ meta_anon_id: 'XZ1', superwall_alias: '$SuperwallAlias:3F2504E0' }],
    ]);
  });

  it('recordNetworkSend passes the send, and needs network and event', () => {
    const { warn } = silenceConsole();
    const { Kerdly, native } = loadSdk();
    Kerdly.recordNetworkSend({
      network: 'meta',
      event: 'StartTrial',
      eventId: '2000001012345678:trial_start',
      value: 0,
      currency: 'USD',
      flag: 'meta_start_trial_enabled',
    });
    Kerdly.recordNetworkSend({ network: 'tiktok', event: 'Subscribe', value: Number.NaN });
    Kerdly.recordNetworkSend({ network: 'meta' } as never);
    expect(native!.recordNetworkSend.mock.calls).toEqual([
      [
        {
          network: 'meta',
          event: 'StartTrial',
          eventId: '2000001012345678:trial_start',
          value: 0,
          currency: 'USD',
          flag: 'meta_start_trial_enabled',
        },
      ],
      [{ network: 'tiktok', event: 'Subscribe' }],
    ]);
    expect(warn).toHaveBeenCalledTimes(2);
  });
});

describe('notifyPurchase', () => {
  it('passes the iOS shape through', () => {
    const { Kerdly, native } = loadSdk({ platform: 'ios' });
    Kerdly.notifyPurchase({
      originalTransactionId: '2000001012345678',
      transactionId: '2000001012345679',
      productId: 'car_weekly_pro',
      appAccountToken: '3f2504e0-4f89-41d3-9a0c-0305e82c3301',
    });
    expect(native!.notifyPurchase).toHaveBeenCalledWith({
      originalTransactionId: '2000001012345678',
      transactionId: '2000001012345679',
      productId: 'car_weekly_pro',
      appAccountToken: '3f2504e0-4f89-41d3-9a0c-0305e82c3301',
    });
  });

  it('sends null on iOS when called without a purchase (entitlement sweep)', () => {
    const { Kerdly, native } = loadSdk({ platform: 'ios' });
    Kerdly.notifyPurchase();
    Kerdly.notifyPurchase(null);
    expect(native!.notifyPurchase.mock.calls).toEqual([[null], [null]]);
  });

  it('passes the Android shape through', () => {
    const { Kerdly, native } = loadSdk({ platform: 'android' });
    Kerdly.notifyPurchase({
      purchaseToken: 'opaque-token',
      orderId: 'GPA.3345-1234-5678-90123',
      products: ['car_weekly_pro'],
      purchaseTime: 1760400119000,
      obfuscatedAccountId: 'acc',
      obfuscatedProfileId: 'prof',
    });
    expect(native!.notifyPurchase).toHaveBeenCalledWith({
      purchaseToken: 'opaque-token',
      orderId: 'GPA.3345-1234-5678-90123',
      products: ['car_weekly_pro'],
      purchaseTime: 1760400119000,
      obfuscatedAccountId: 'acc',
      obfuscatedProfileId: 'prof',
    });
  });

  it('drops malformed fields instead of the purchase', () => {
    silenceConsole();
    const { Kerdly, native } = loadSdk({ platform: 'ios' });
    Kerdly.notifyPurchase({
      originalTransactionId: 2000001012345678 as never,
      productId: 'car_weekly_pro',
      appAccountToken: 'not-a-uuid',
    });
    expect(native!.notifyPurchase).toHaveBeenCalledWith({
      originalTransactionId: '2000001012345678',
      productId: 'car_weekly_pro',
    });
  });

  it('ignores an Android call without purchaseToken', () => {
    const { warn } = silenceConsole();
    const { Kerdly, native } = loadSdk({ platform: 'android' });
    Kerdly.notifyPurchase({ productId: 'car_weekly_pro' });
    Kerdly.notifyPurchase();
    expect(native!.notifyPurchase).not.toHaveBeenCalled();
    expect(warn).toHaveBeenCalledWith(expect.stringContaining('purchaseToken'));
  });
});

describe('async calls', () => {
  it('handleUrl passes the URL with no source and returns the parsed link', async () => {
    const { Kerdly, native } = loadSdk();
    const url = 'com.acme.app://onboarding?cpp=web-meta';
    await expect(Kerdly.handleUrl(url)).resolves.toEqual({
      url,
      cpp: 'web-meta',
      ppid: null,
      clickId: null,
      visitId: null,
      campaignIds: null,
    });
    expect(native!.handleUrl).toHaveBeenCalledWith(url, null);
    native!.handleUrl.mockResolvedValueOnce(null);
    await expect(Kerdly.handleUrl(url)).resolves.toBeNull();
  });

  it('getAttribution normalises the iOS payload (raw object)', async () => {
    const { Kerdly, native } = loadSdk();
    native!.getAttribution.mockResolvedValueOnce(IOS_ATTRIBUTION);
    await expect(Kerdly.getAttribution()).resolves.toEqual(IOS_ATTRIBUTION);
  });

  it('getAttribution normalises the Android payload (raw JSON string)', async () => {
    const { Kerdly, native } = loadSdk({ platform: 'android' });
    native!.getAttribution.mockResolvedValueOnce({ ...IOS_ATTRIBUTION, raw: JSON.stringify(IOS_ATTRIBUTION.raw) });
    await expect(Kerdly.getAttribution()).resolves.toEqual(IOS_ATTRIBUTION);
  });

  it('getAttribution resolves null until attribution is known', async () => {
    const { Kerdly } = loadSdk();
    await expect(Kerdly.getAttribution()).resolves.toBeNull();
  });

  it('requestTrackingAuthorization asks native on iOS only', async () => {
    const ios = loadSdk({ platform: 'ios' });
    await expect(ios.Kerdly.requestTrackingAuthorization()).resolves.toBe('authorized');
    ios.native!.requestTrackingAuthorization.mockResolvedValueOnce('bogus');
    await expect(ios.Kerdly.requestTrackingAuthorization()).resolves.toBe('not_determined');

    const android = loadSdk({ platform: 'android' });
    await expect(android.Kerdly.requestTrackingAuthorization()).resolves.toBe('not_applicable');
    expect(android.native!.requestTrackingAuthorization).not.toHaveBeenCalled();
  });

  it('flush and getInstallId call native', async () => {
    const { Kerdly, native } = loadSdk();
    await expect(Kerdly.flush()).resolves.toBeUndefined();
    expect(native!.flush).toHaveBeenCalledTimes(1);
    await expect(Kerdly.getInstallId()).resolves.toBe('8c1f5d0e-2f3a-4c55-9d7e-1b2c3d4e5f60');
    native!.getInstallId.mockResolvedValueOnce(null);
    await expect(Kerdly.getInstallId()).resolves.toBeNull();
  });

  it('debugFetchDeferredLinks asks native on iOS only', async () => {
    const ios = loadSdk({ platform: 'ios' });
    await expect(ios.Kerdly.debugFetchDeferredLinks({ tiktokAppId: '76' })).resolves.toEqual([
      { network: 'meta', status: 'none', httpStatus: 200 },
    ]);
    expect(ios.native!.debugFetchDeferredLinks).toHaveBeenLastCalledWith('76', null);
    await ios.Kerdly.debugFetchDeferredLinks();
    expect(ios.native!.debugFetchDeferredLinks).toHaveBeenLastCalledWith(null, null);

    const android = loadSdk({ platform: 'android' });
    await expect(android.Kerdly.debugFetchDeferredLinks({ tiktokAppId: '76' })).resolves.toEqual([]);
    expect(android.native!.debugFetchDeferredLinks).not.toHaveBeenCalled();
  });
});

describe('never throws into the app', () => {
  it('turns native rejections and throws into resolved defaults', async () => {
    silenceConsole();
    const { Kerdly, native } = loadSdk();
    const boom = new Error('native failure');
    for (const fn of Object.values(native!)) {
      if (typeof fn === 'function' && 'mockImplementation' in fn) {
        (fn as jest.Mock).mockImplementation(() => {
          throw boom;
        });
      }
    }
    native!.getAttribution.mockRejectedValue(boom);

    expect(() => Kerdly.setUserId('u')).not.toThrow();
    expect(() => Kerdly.track('ok')).not.toThrow();
    expect(() => Kerdly.trackRegistration({ method: 'apple' })).not.toThrow();
    expect(() => Kerdly.trackStartTrial({ productId: 'p', value: 0, currency: 'USD' })).not.toThrow();
    expect(() => Kerdly.trackSubscribe({ productId: 'p', value: 9.99, currency: 'USD' })).not.toThrow();
    expect(() => Kerdly.trackPurchase({ productId: 'p', value: 4.99, currency: 'USD', quantity: 1 })).not.toThrow();
    expect(() => Kerdly.setConsent({ ads: true })).not.toThrow();
    expect(() => Kerdly.setAppAccountToken(null)).not.toThrow();
    expect(() => Kerdly.setPartnerIds({ a: 'b' })).not.toThrow();
    expect(() => Kerdly.notifyPurchase()).not.toThrow();
    expect(() => Kerdly.recordNetworkSend({ network: 'meta', event: 'Purchase' })).not.toThrow();
    await expect(Kerdly.configure({ key: KEY, endpoint: ENDPOINT, autoDeepLinks: false })).resolves.toBeUndefined();
    await expect(Kerdly.handleUrl('acmeapp://x')).resolves.toBeNull();
    await expect(Kerdly.getAttribution()).resolves.toBeNull();
    await expect(Kerdly.requestTrackingAuthorization()).resolves.toBe('not_determined');
    await expect(Kerdly.flush()).resolves.toBeUndefined();
    await expect(Kerdly.getInstallId()).resolves.toBeNull();
    expect(Kerdly.addAttributionListener(() => undefined)).toEqual({ remove: expect.any(Function) });
    await flushPromises();
  });

  it('is a no-op with a single warning when the native module is missing', async () => {
    const { warn } = silenceConsole();
    const { Kerdly, rn } = loadSdk({ native: false, platform: 'android' });
    await Kerdly.configure({ key: KEY, endpoint: ENDPOINT });
    Kerdly.setUserId('u');
    Kerdly.track('ok');
    Kerdly.trackSubscribe({ productId: 'p', value: 9.99, currency: 'USD' });
    await expect(Kerdly.handleUrl('acmeapp://x')).resolves.toBeNull();
    await expect(Kerdly.getAttribution()).resolves.toBeNull();
    await expect(Kerdly.getInstallId()).resolves.toBeNull();
    await expect(Kerdly.requestTrackingAuthorization()).resolves.toBe('not_applicable');
    const sub = Kerdly.addAttributionListener(() => undefined);
    expect(() => sub.remove()).not.toThrow();
    expect(rn.Linking.addEventListener).not.toHaveBeenCalled();
    expect(rn.Linking.getInitialURL).not.toHaveBeenCalled();
    const missing = warn.mock.calls.filter(([message]) => String(message).includes('is not available'));
    expect(missing).toHaveLength(1);
  });
});
