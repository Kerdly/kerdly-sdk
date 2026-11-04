import { flushPromises, loadSdk, silenceConsole } from './helpers';

const OPTIONS = { key: 'pk_test_abc123', endpoint: 'https://sdk.example.com' };
const INITIAL = 'com.acme.app://onboarding?cpp=web-meta&ppid=ce3a1b2c-0000-4000-8000-000000000001';
const RUNTIME = 'https://go.acme-app.com/l/abc?afr_c=click123';

describe('automatic deep-link capture (autoDeepLinks, default on)', () => {
  it('forwards the initial URL once with source "initial", after native configure', async () => {
    const { Kerdly, native, rn } = loadSdk({ initialUrl: INITIAL });
    await Kerdly.configure(OPTIONS);
    await flushPromises();
    expect(rn.Linking.getInitialURL).toHaveBeenCalledTimes(1);
    expect(native!.handleUrl.mock.calls).toEqual([[INITIAL, 'initial']]);
    expect(native!.configure.mock.invocationCallOrder[0]).toBeLessThan(
      native!.handleUrl.mock.invocationCallOrder[0]
    );
  });

  it('forwards every url event with source "runtime"', async () => {
    const { Kerdly, native, rn } = loadSdk();
    await Kerdly.configure(OPTIONS);
    await flushPromises();
    expect(rn.Linking.addEventListener).toHaveBeenCalledWith('url', expect.any(Function));
    rn.__emitUrl(RUNTIME);
    rn.__emitUrl(INITIAL);
    expect(native!.handleUrl.mock.calls).toEqual([
      [RUNTIME, 'runtime'],
      [INITIAL, 'runtime'],
    ]);
  });

  it('does not forward a null initial URL', async () => {
    const { Kerdly, native } = loadSdk({ initialUrl: null });
    await Kerdly.configure(OPTIONS);
    await flushPromises();
    expect(native!.handleUrl).not.toHaveBeenCalled();
  });

  it('captures once even when configure is called again', async () => {
    const { Kerdly, native, rn } = loadSdk({ initialUrl: INITIAL });
    await Kerdly.configure(OPTIONS);
    await Kerdly.configure(OPTIONS);
    await flushPromises();
    expect(native!.configure).toHaveBeenCalledTimes(2);
    expect(rn.Linking.getInitialURL).toHaveBeenCalledTimes(1);
    expect(rn.Linking.addEventListener).toHaveBeenCalledTimes(1);
    rn.__emitUrl(RUNTIME);
    expect(native!.handleUrl.mock.calls).toEqual([
      [INITIAL, 'initial'],
      [RUNTIME, 'runtime'],
    ]);
  });

  it('ignores expo-dev-client launcher URLs', async () => {
    const devUrl = 'exp+acmeapp://expo-development-client/?url=http%3A%2F%2F192.168.1.5%3A8081';
    const { Kerdly, native, rn } = loadSdk({ initialUrl: devUrl });
    await Kerdly.configure(OPTIONS);
    await flushPromises();
    rn.__emitUrl(devUrl);
    expect(native!.handleUrl).not.toHaveBeenCalled();
  });

  it('survives a failing getInitialURL', async () => {
    const { warn } = silenceConsole();
    const { Kerdly, native, rn } = loadSdk({ initialUrl: new Error('no activity') });
    await expect(Kerdly.configure(OPTIONS)).resolves.toBeUndefined();
    await flushPromises();
    expect(native!.handleUrl).not.toHaveBeenCalled();
    expect(warn).toHaveBeenCalledWith(expect.stringContaining('getInitialURL failed'), expect.any(Error));
    rn.__emitUrl(RUNTIME);
    expect(native!.handleUrl).toHaveBeenCalledWith(RUNTIME, 'runtime');
  });
});

describe('autoDeepLinks: false', () => {
  it('neither reads the initial URL nor subscribes', async () => {
    const { Kerdly, native, rn } = loadSdk({ initialUrl: INITIAL });
    await Kerdly.configure({ ...OPTIONS, autoDeepLinks: false });
    await flushPromises();
    rn.__emitUrl(RUNTIME);
    expect(rn.Linking.getInitialURL).not.toHaveBeenCalled();
    expect(rn.Linking.addEventListener).not.toHaveBeenCalled();
    expect(native!.handleUrl).not.toHaveBeenCalled();
  });

  it('removes an earlier subscription when a later configure turns it off', async () => {
    const { Kerdly, native, rn } = loadSdk();
    await Kerdly.configure(OPTIONS);
    expect(rn.__urlListenerCount()).toBe(1);
    await Kerdly.configure({ ...OPTIONS, autoDeepLinks: false });
    expect(rn.__urlListenerCount()).toBe(0);
    rn.__emitUrl(RUNTIME);
    expect(native!.handleUrl).not.toHaveBeenCalled();
  });
});
