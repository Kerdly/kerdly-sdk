import Foundation
import os
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Moves a value the compiler cannot prove `Sendable` (an app's completion handler) to the thread
/// that will use it. Only used where the value is touched on one thread at a time.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A value guarded by a lock, for the few things public getters read from any thread.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    @discardableResult
    func update<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// `[Kerdly]`-prefixed logging at the configured level. Callers never pass keys or a
/// full IDFA.
final class KerdlyLogger: @unchecked Sendable {
    private let level = Locked(KerdlyLogLevel.warn)
    private let osLog = os.Logger(subsystem: "com.kerdly.sdk", category: "Kerdly")

    var currentLevel: KerdlyLogLevel {
        get { level.get() }
        set { level.set(newValue) }
    }

    func error(_ message: @autoclosure () -> String) { write(.error, message()) }
    func warn(_ message: @autoclosure () -> String) { write(.warn, message()) }
    func info(_ message: @autoclosure () -> String) { write(.info, message()) }
    func debug(_ message: @autoclosure () -> String) { write(.debug, message()) }

    func enabled(_ messageLevel: KerdlyLogLevel) -> Bool {
        messageLevel != .none && messageLevel.rawValue <= level.get().rawValue
    }

    private func write(_ messageLevel: KerdlyLogLevel, _ message: @autoclosure () -> String) {
        guard enabled(messageLevel) else { return }
        let text = "[Kerdly] \(message())"
        switch messageLevel {
        case .error: osLog.error("\(text, privacy: .public)")
        case .warn: osLog.warning("\(text, privacy: .public)")
        case .info: osLog.info("\(text, privacy: .public)")
        case .debug, .none: osLog.debug("\(text, privacy: .public)")
        }
    }
}

enum Hashing {
    /// Lowercase hex SHA-256.
    static func sha256(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return String(data.hashValue)
        #endif
    }

    static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }
}

enum Redact {
    /// First 4 characters, for log lines about an IDFA or a token.
    static func short(_ value: String) -> String {
        value.count <= 4 ? "…" : "\(value.prefix(4))…"
    }
}
