import { IOS_ATTRIBUTION, flushPromises, loadSdk, silenceConsole } from './helpers';

describe('addAttributionListener', () => {
  it('delivers the already-known attribution at once, like the native onAttribution', async () => {
    const { Kerdly, native } = loadSdk();
    native!.getAttribution.mockResolvedValue(IOS_ATTRIBUTION);
    const listener = jest.fn();
    Kerdly.addAttributionListener(listener);
    await flushPromises();
    expect(listener).toHaveBeenCalledTimes(1);
    expect(listener).toHaveBeenCalledWith(IOS_ATTRIBUTION);
  });

  it('does not replay a stale value after an event, or after remove()', async () => {
    const { Kerdly, native } = loadSdk();
    native!.getAttribution.mockResolvedValue(IOS_ATTRIBUTION);
    const first = jest.fn();
    Kerdly.addAttributionListener(first);
    const final = { ...IOS_ATTRIBUTION, state: 'final' };
    native!.emit('onAttribution', final);
    const second = jest.fn();
    Kerdly.addAttributionListener(second).remove();
    await flushPromises();
    expect(first.mock.calls).toEqual([[final]]);
    expect(second).not.toHaveBeenCalled();
  });

  it('subscribes to the native onAttribution event and normalises payloads', () => {
    const { Kerdly, native } = loadSdk();
    const listener = jest.fn();
    const sub = Kerdly.addAttributionListener(listener);
    expect(native!.listenerCount('onAttribution')).toBe(1);

    native!.emit('onAttribution', IOS_ATTRIBUTION);
    native!.emit('onAttribution', { ...IOS_ATTRIBUTION, state: 'final', raw: JSON.stringify({ state: 'final' }) });
    expect(listener).toHaveBeenCalledTimes(2);
    expect(listener.mock.calls[0][0]).toEqual(IOS_ATTRIBUTION);
    expect(listener.mock.calls[1][0]).toMatchObject({ state: 'final', raw: { state: 'final' } });

    sub.remove();
    expect(native!.listenerCount('onAttribution')).toBe(0);
    native!.emit('onAttribution', IOS_ATTRIBUTION);
    expect(listener).toHaveBeenCalledTimes(2);
    expect(() => sub.remove()).not.toThrow();
  });

  it('accepts snake_case payloads (the collector JSON as-is)', () => {
    const { Kerdly, native } = loadSdk();
    const listener = jest.fn();
    Kerdly.addAttributionListener(listener);
    native!.emit('onAttribution', {
      state: 'final',
      network: 'apple_ads',
      status: 'measured',
      method: 'asa_token',
      campaign_id: '1',
      campaign: 'Generic_States',
      adset_id: '2',
      adset: 'PA',
      ad_id: null,
      ad: null,
      keyword_id: '3',
      keyword: 'pa permit test',
      link_id: null,
      cpp_id: null,
      decided_at: 1759708800000,
    });
    expect(listener).toHaveBeenCalledWith(
      expect.objectContaining({
        network: 'apple_ads',
        campaignId: '1',
        adsetId: '2',
        keywordId: '3',
        keyword: 'pa permit test',
        decidedAt: 1759708800000,
        raw: expect.objectContaining({ campaign_id: '1' }),
      })
    );
  });

  it('supports several listeners independently', () => {
    const { Kerdly, native } = loadSdk();
    const a = jest.fn();
    const b = jest.fn();
    const subA = Kerdly.addAttributionListener(a);
    Kerdly.addAttributionListener(b);
    subA.remove();
    native!.emit('onAttribution', IOS_ATTRIBUTION);
    expect(a).not.toHaveBeenCalled();
    expect(b).toHaveBeenCalledTimes(1);
  });

  it('ignores malformed events and contains a throwing listener', () => {
    const { warn, error } = silenceConsole();
    const { Kerdly, native } = loadSdk();
    const throwing = jest.fn(() => {
      throw new Error('app bug');
    });
    const after = jest.fn();
    Kerdly.addAttributionListener(throwing);
    Kerdly.addAttributionListener(after);
    native!.emit('onAttribution', { state: 'final' });
    expect(throwing).not.toHaveBeenCalled();
    expect(warn).toHaveBeenCalledWith(expect.stringContaining('malformed'), { state: 'final' });
    expect(() => native!.emit('onAttribution', IOS_ATTRIBUTION)).not.toThrow();
    expect(after).toHaveBeenCalledTimes(1);
    expect(error).toHaveBeenCalledWith(expect.stringContaining('listener threw'), expect.any(Error));
  });

  it('returns a no-op subscription for a non-function listener', () => {
    silenceConsole();
    const { Kerdly, native } = loadSdk();
    const sub = Kerdly.addAttributionListener('nope' as never);
    expect(native!.listenerCount('onAttribution')).toBe(0);
    expect(() => sub.remove()).not.toThrow();
  });
});
