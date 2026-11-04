import { MAX_PROPS, truncate, validateEvent } from '../src/validation';
import { loadSdk, silenceConsole } from './helpers';

describe('validateEvent', () => {
  it.each(['registration', 'a', 'lesson_2_done', 'x'.repeat(40)])('accepts the name %p', (name) => {
    expect(validateEvent(name, {}).event).toEqual({ name, properties: {} });
  });

  it.each([
    ['Registration'],
    ['2fast'],
    ['_private'],
    ['with-dash'],
    ['with space'],
    ['x'.repeat(41)],
    [''],
    ['$install'],
    [42],
    [null],
  ])('drops the event named %p', (name) => {
    const result = validateEvent(name, { ok: 1 });
    expect(result.event).toBeNull();
    expect(result.problems).toHaveLength(1);
  });

  it('explains that $ names are reserved', () => {
    expect(validateEvent('$purchase_link', {}).problems[0]).toContain('reserved');
  });

  it('drops the event when properties is not a plain object', () => {
    expect(validateEvent('ok', ['a']).event).toBeNull();
    expect(validateEvent('ok', 'a').event).toBeNull();
    expect(validateEvent('ok', new Date()).event).toBeNull();
    expect(validateEvent('ok', null).event).toEqual({ name: 'ok', properties: {} });
  });

  it('keeps strings, finite numbers and booleans, and drops everything else', () => {
    const { event, problems } = validateEvent('ok', {
      method: 'anonymous',
      count: 3,
      ratio: 0.5,
      paid: false,
      nan: Number.NaN,
      inf: Number.POSITIVE_INFINITY,
      nothing: null,
      nested: { a: 1 },
      list: [1],
      when: new Date(0),
      big: BigInt(1),
      skipped: undefined,
      BadKey: 'x',
      'bad-key': 'x',
      ['k'.repeat(41)]: 'x',
    });
    expect(event!.properties).toEqual({ method: 'anonymous', count: 3, ratio: 0.5, paid: false });
    // undefined is skipped silently; every other dropped prop is reported
    expect(problems).toHaveLength(10);
  });

  it('truncates strings to 256 characters', () => {
    const { event, problems } = validateEvent('ok', { long: 'a'.repeat(300) });
    expect((event!.properties.long as string).length).toBe(256);
    expect(problems).toEqual([]);
  });

  it('does not split a surrogate pair when truncating', () => {
    const value = 'a'.repeat(255) + '😀';
    expect(truncate(value)).toBe('a'.repeat(255));
  });

  it('keeps the first 25 valid properties', () => {
    const props: Record<string, number> = {};
    for (let i = 0; i < 30; i++) props[`p${i}`] = i;
    const { event, problems } = validateEvent('ok', props);
    expect(Object.keys(event!.properties)).toEqual(Array.from({ length: MAX_PROPS }, (_, i) => `p${i}`));
    expect(problems).toHaveLength(1);
    expect(problems[0]).toContain('"p25"');
  });
});

describe('Kerdly.track validation', () => {
  it('drops an invalid event before native, with a dev warning', () => {
    const { warn } = silenceConsole();
    const { Kerdly, native } = loadSdk();
    Kerdly.track('Bad Name', {});
    Kerdly.track('$install');
    expect(native!.track).not.toHaveBeenCalled();
    expect(warn).toHaveBeenCalledTimes(2);
    expect(warn.mock.calls[0][0]).toContain('[Kerdly] track: event dropped');
  });

  it('sends the event without its invalid properties, with a dev warning', () => {
    const { warn } = silenceConsole();
    const { Kerdly, native } = loadSdk();
    Kerdly.track('paywall_view', { placement: 'onboarding', price: 7.99, extra: { nested: true } as never });
    expect(native!.track).toHaveBeenCalledWith('paywall_view', { placement: 'onboarding', price: 7.99 });
    expect(warn).toHaveBeenCalledWith(expect.stringContaining('property "extra"'));
  });

  it('warns only in development builds', () => {
    const { warn } = silenceConsole();
    const { Kerdly, native } = loadSdk();
    const globals = globalThis as { __DEV__?: boolean };
    globals.__DEV__ = false;
    try {
      Kerdly.track('Bad Name');
    } finally {
      globals.__DEV__ = true;
    }
    expect(native!.track).not.toHaveBeenCalled();
    expect(warn).not.toHaveBeenCalled();
  });

  it('respects logLevel "none" for its own warnings', async () => {
    const { warn } = silenceConsole();
    const { Kerdly } = loadSdk();
    await Kerdly.configure({ key: 'pk_test_x', endpoint: 'https://sdk.example.com', logLevel: 'none', autoDeepLinks: false });
    Kerdly.track('Bad Name');
    expect(warn).not.toHaveBeenCalled();
  });
});
