// Manual mock of the parts of react-native that src/ uses (mapped in jest.config.js).

type UrlListener = (event: { url: string }) => void;

const urlListeners = new Set<UrlListener>();
let initialUrl: Promise<string | null> = Promise.resolve(null);

export const Platform: { OS: 'ios' | 'android' | 'web' } = { OS: 'ios' };

export const Linking = {
  getInitialURL: jest.fn((): Promise<string | null> => initialUrl),
  addEventListener: jest.fn((type: string, listener: UrlListener) => {
    if (type !== 'url') throw new Error(`unexpected Linking event "${type}"`);
    urlListeners.add(listener);
    return { remove: jest.fn(() => void urlListeners.delete(listener)) };
  }),
};

/** Test hook: what `Linking.getInitialURL()` resolves (or rejects) with. */
export function __setInitialURL(url: string | null | Error): void {
  initialUrl = url instanceof Error ? Promise.reject(url) : Promise.resolve(url);
  // Avoid an unhandled-rejection report before the SDK subscribes.
  initialUrl.catch(() => undefined);
}

/** Test hook: delivers a `url` event, as React Native does for links opened while running. */
export function __emitUrl(url: string): void {
  for (const listener of [...urlListeners]) listener({ url });
}

export function __urlListenerCount(): number {
  return urlListeners.size;
}
