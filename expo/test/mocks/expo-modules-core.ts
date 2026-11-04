// Manual mock of the parts of expo-modules-core that src/ uses (mapped in jest.config.js).
// Since Expo SDK 52 a native module object is itself an EventEmitter, so the mock module extends
// this EventEmitter and tests emit native events with `module.emit(...)`.

type Listener = (...args: any[]) => void;

export class EventEmitter {
  private readonly listeners = new Map<string, Set<Listener>>();

  addListener(eventName: string, listener: Listener): { remove(): void } {
    let set = this.listeners.get(eventName);
    if (!set) {
      set = new Set();
      this.listeners.set(eventName, set);
    }
    set.add(listener);
    return { remove: () => this.removeListener(eventName, listener) };
  }

  removeListener(eventName: string, listener: Listener): void {
    this.listeners.get(eventName)?.delete(listener);
  }

  removeAllListeners(eventName: string): void {
    this.listeners.delete(eventName);
  }

  emit(eventName: string, ...args: unknown[]): void {
    for (const listener of [...(this.listeners.get(eventName) ?? [])]) listener(...args);
  }

  listenerCount(eventName: string): number {
    return this.listeners.get(eventName)?.size ?? 0;
  }
}

export class NativeModule extends EventEmitter {}

const registry = new Map<string, unknown>();

/** Test hook: makes `requireOptionalNativeModule(name)` return `module`. */
export function __setNativeModule(name: string, module: unknown): void {
  registry.set(name, module);
}

export const requireOptionalNativeModule = jest.fn((name: string): unknown => registry.get(name) ?? null);

export function requireNativeModule(name: string): unknown {
  const module = registry.get(name);
  if (!module) throw new Error(`Cannot find native module '${name}'`);
  return module;
}
