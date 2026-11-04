import { MAX_ID_LENGTH, MAX_METHOD_LENGTH, MAX_PROPS, validateStandardEvent } from '../src/validation';
import { loadSdk, silenceConsole } from './helpers';

const NO_FIELDS = {
  method: null,
  productId: null,
  value: null,
  currency: null,
  quantity: null,
  transactionId: null,
};

describe('validateStandardEvent', () => {
  it('keeps valid typed fields as they are', () => {
    const { event, problems } = validateStandardEvent('trackPurchase', {
      productId: 'exam_pack',
      value: 4.99,
      currency: 'EUR',
      quantity: 2,
      transactionId: '2000001012345680',
    });
    expect(event).toEqual({
      fields: { ...NO_FIELDS, productId: 'exam_pack', value: 4.99, currency: 'EUR', quantity: 2, transactionId: '2000001012345680' },
      properties: {},
    });
    expect(problems).toEqual([]);
  });

  it('treats a missing argument as no fields', () => {
    expect(validateStandardEvent('trackRegistration', undefined)).toEqual({
      event: { fields: NO_FIELDS, properties: {} },
      problems: [],
    });
    expect(validateStandardEvent('trackStartTrial', null).event).toEqual({ fields: NO_FIELDS, properties: {} });
  });

  it.each([['a string'], [42], [['productId']], [new Date(0)]])('drops the event when the argument is %p', (input) => {
    const { event, problems } = validateStandardEvent('trackSubscribe', input);
    expect(event).toBeNull();
    expect(problems).toHaveLength(1);
  });

  it('keeps value 0 (a free trial)', () => {
    const { event } = validateStandardEvent('trackStartTrial', { value: 0, currency: 'USD' });
    expect(event!.fields).toMatchObject({ value: 0, currency: 'USD' });
  });

  it.each([[-1], [-0.01], [Number.NaN], [Number.POSITIVE_INFINITY], ['9.99']])('drops the value %p', (value) => {
    const { event, problems } = validateStandardEvent('trackSubscribe', { value, currency: 'USD' });
    expect(event!.fields).toMatchObject({ value: null, currency: 'USD' });
    expect(problems).toEqual([expect.stringContaining('value must be a finite number')]);
  });

  it('upper-cases the currency', () => {
    const { event, problems } = validateStandardEvent('trackSubscribe', { value: 9.99, currency: 'usd' });
    expect(event!.fields).toMatchObject({ value: 9.99, currency: 'USD' });
    expect(problems).toEqual([]);
  });

  it('drops the value when the currency is missing', () => {
    const { event, problems } = validateStandardEvent('trackSubscribe', { productId: 'car_weekly_pro', value: 9.99 });
    expect(event!.fields).toMatchObject({ productId: 'car_weekly_pro', value: null, currency: null });
    expect(problems).toEqual([expect.stringContaining('value needs a valid currency')]);
  });

  it.each([['US'], ['USDT'], ['U$D'], [''], [840]])('drops the invalid currency %p, and the value with it', (currency) => {
    const { event, problems } = validateStandardEvent('trackPurchase', { value: 4.99, currency });
    expect(event!.fields).toMatchObject({ value: null, currency: null });
    expect(problems).toEqual([
      expect.stringContaining('currency must be a three-letter ISO 4217 code'),
      expect.stringContaining('value needs a valid currency'),
    ]);
  });

  it('keeps a currency without a value', () => {
    const { event, problems } = validateStandardEvent('trackStartTrial', { currency: 'gbp' });
    expect(event!.fields).toMatchObject({ value: null, currency: 'GBP' });
    expect(problems).toEqual([]);
  });

  it.each([[0], [-1], [1.5], [Number.NaN], ['1'], [2 ** 31]])('drops the quantity %p', (quantity) => {
    const { event, problems } = validateStandardEvent('trackPurchase', { quantity });
    expect(event!.fields.quantity).toBeNull();
    expect(problems).toEqual([expect.stringContaining('quantity must be an integer')]);
  });

  it('keeps an integer quantity ≥ 1', () => {
    expect(validateStandardEvent('trackPurchase', { quantity: 1 }).event!.fields.quantity).toBe(1);
    expect(validateStandardEvent('trackPurchase', { quantity: 3 }).event!.fields.quantity).toBe(3);
  });

  it(`cuts ids to ${MAX_ID_LENGTH} and the method to ${MAX_METHOD_LENGTH} characters`, () => {
    const purchase = validateStandardEvent('trackPurchase', {
      productId: 'p'.repeat(200),
      transactionId: 't'.repeat(129),
    });
    expect(purchase.event!.fields.productId).toBe('p'.repeat(MAX_ID_LENGTH));
    expect(purchase.event!.fields.transactionId).toBe('t'.repeat(MAX_ID_LENGTH));
    expect(purchase.problems).toEqual([]);

    const registration = validateStandardEvent('trackRegistration', { method: 'm'.repeat(100) });
    expect(registration.event!.fields.method).toBe('m'.repeat(MAX_METHOD_LENGTH));
  });

  it('turns a numeric transaction id into a string and drops empty or malformed ids', () => {
    const { event, problems } = validateStandardEvent('trackStartTrial', {
      productId: '',
      transactionId: 2000001012345678,
    });
    expect(event!.fields).toMatchObject({ productId: null, transactionId: '2000001012345678' });
    expect(problems).toEqual([expect.stringContaining('productId must be a non-empty string')]);
    expect(validateStandardEvent('trackRegistration', { method: 7 }).event!.fields.method).toBeNull();
  });

  it("reports fields the event does not have, and ignores null and undefined", () => {
    const { event, problems } = validateStandardEvent('trackRegistration', {
      method: 'apple',
      quantity: 2,
      product_id: 'x',
      productId: undefined,
      currency: null,
    } as never);
    expect(event!.fields).toEqual({ ...NO_FIELDS, method: 'apple' });
    expect(problems).toEqual([
      expect.stringContaining('unknown field "quantity"'),
      expect.stringContaining('unknown field "product_id"'),
    ]);
  });

  it('passes extra properties through under the custom-event rules', () => {
    const { event, problems } = validateStandardEvent('trackSubscribe', {
      productId: 'car_weekly_pro',
      properties: { plan: 'weekly', intro: true, months: 1, note: 'n'.repeat(300), BadKey: 'x', nested: {} as never },
    });
    expect(event!.properties).toEqual({ plan: 'weekly', intro: true, months: 1, note: 'n'.repeat(256) });
    expect(problems).toHaveLength(2);
  });

  it('drops extra properties that are typed props of the event (the typed field sets them)', () => {
    const { event, problems } = validateStandardEvent('trackStartTrial', {
      value: 0,
      currency: 'USD',
      properties: { value: -5, product_id: 'x', quantity: 2, method: 'email', plan: 'weekly' },
    });
    expect(event!.fields).toMatchObject({ value: 0, currency: 'USD', productId: null });
    // quantity and method are not typed props of start_trial, so they are ordinary custom props
    expect(event!.properties).toEqual({ quantity: 2, method: 'email', plan: 'weekly' });
    expect(problems).toEqual([
      expect.stringContaining('property "value" is a typed prop: pass it as `value`'),
      expect.stringContaining('property "product_id" is a typed prop: pass it as `productId`'),
    ]);
  });

  it('keeps the event when properties is not a plain object', () => {
    const { event, problems } = validateStandardEvent('trackRegistration', { method: 'google', properties: ['a'] });
    expect(event).toEqual({ fields: { ...NO_FIELDS, method: 'google' }, properties: {} });
    expect(problems).toEqual([expect.stringContaining('properties must be a plain object')]);
  });

  it(`keeps the first ${MAX_PROPS} extra properties`, () => {
    const properties: Record<string, number> = {};
    for (let i = 0; i < 30; i++) properties[`p${i}`] = i;
    const { event, problems } = validateStandardEvent('trackPurchase', { properties });
    expect(Object.keys(event!.properties)).toHaveLength(MAX_PROPS);
    expect(problems).toEqual([expect.stringContaining('more than 25 properties')]);
  });
});

describe('standard event methods', () => {
  it('trackRegistration passes the method and the extra properties', () => {
    const { Kerdly, native } = loadSdk();
    Kerdly.trackRegistration({ method: 'anonymous' });
    Kerdly.trackRegistration({ method: 'apple', properties: { screen: 'onboarding' } });
    Kerdly.trackRegistration();
    expect(native!.trackRegistration.mock.calls).toEqual([
      ['anonymous', {}],
      ['apple', { screen: 'onboarding' }],
      [null, {}],
    ]);
  });

  it('trackStartTrial passes the typed fields in the native order', () => {
    const { Kerdly, native } = loadSdk();
    Kerdly.trackStartTrial({ productId: 'car_weekly_pro', value: 0, currency: 'usd', transactionId: '2000001012345678' });
    expect(native!.trackStartTrial).toHaveBeenCalledWith('car_weekly_pro', 0, 'USD', '2000001012345678', {});
  });

  it('trackSubscribe passes the typed fields and the extra properties', () => {
    const { Kerdly, native } = loadSdk({ platform: 'android' });
    Kerdly.trackSubscribe({
      productId: 'car_weekly_pro',
      value: 7.99,
      currency: 'USD',
      transactionId: 'GPA.3345-1234-5678-90123',
      properties: { plan: 'weekly' },
    });
    expect(native!.trackSubscribe).toHaveBeenCalledWith(
      'car_weekly_pro',
      7.99,
      'USD',
      'GPA.3345-1234-5678-90123',
      { plan: 'weekly' }
    );
  });

  it('trackPurchase passes the typed fields, quantity before transactionId', () => {
    const { Kerdly, native } = loadSdk();
    Kerdly.trackPurchase({ productId: 'exam_pack', value: 4.99, currency: 'EUR', quantity: 1, transactionId: '2000001012345680' });
    expect(native!.trackPurchase).toHaveBeenCalledWith('exam_pack', 4.99, 'EUR', 1, '2000001012345680', {});
  });

  it('sends null for omitted and dropped fields, with a dev warning', () => {
    const { warn } = silenceConsole();
    const { Kerdly, native } = loadSdk();
    Kerdly.trackSubscribe({ productId: 'car_weekly_pro', value: -9.99, currency: 'USD' });
    Kerdly.trackSubscribe({ value: 9.99 });
    Kerdly.trackPurchase({ productId: 'x'.repeat(130), quantity: 0, value: 4.99, currency: 'dollars' });
    expect(native!.trackSubscribe.mock.calls).toEqual([
      ['car_weekly_pro', null, 'USD', null, {}],
      [null, null, null, null, {}],
    ]);
    expect(native!.trackPurchase).toHaveBeenCalledWith('x'.repeat(128), null, null, null, null, {});
    expect(warn).toHaveBeenCalledTimes(3);
    expect(warn.mock.calls[0][0]).toContain('[Kerdly] trackSubscribe: dropped');
    expect(warn.mock.calls[2][0]).toContain('quantity must be an integer');
  });

  it('drops the event when the argument is not an object', () => {
    const { warn } = silenceConsole();
    const { Kerdly, native } = loadSdk();
    Kerdly.trackStartTrial('car_weekly_pro' as never);
    expect(native!.trackStartTrial).not.toHaveBeenCalled();
    expect(warn.mock.calls[0][0]).toContain('[Kerdly] trackStartTrial: event dropped');
  });

  it('runs in call order with the other calls', () => {
    const { Kerdly, native } = loadSdk();
    Kerdly.setUserId('m5KwQ2xYz');
    Kerdly.trackRegistration({ method: 'anonymous' });
    Kerdly.trackStartTrial({ productId: 'car_weekly_pro', value: 0, currency: 'USD' });
    const order = [native!.setUserId, native!.trackRegistration, native!.trackStartTrial].map(
      (fn) => fn.mock.invocationCallOrder[0]
    );
    expect(order).toEqual([...order].sort((a, b) => a - b));
  });
});
