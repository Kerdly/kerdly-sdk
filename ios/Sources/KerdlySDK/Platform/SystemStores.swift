import Foundation
import Security

/// The Keychain copy of the install id: a generic password, service `com.kerdly.sdk`, account
/// `install_id`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable. It survives
/// an uninstall and never moves to another device.
final class SystemKeychain: KeychainStoring {
    static let service = "com.kerdly.sdk"
    /// The service builds before 0.1.0 used. Its item is read when the current one is missing, and
    /// copied to the current service; it is never changed or deleted.
    static let legacyService = "com.afr.sdk"
    static let account = "install_id"

    private func itemQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    private var baseQuery: [String: Any] { itemQuery(service: Self.service) }

    func readInstallId() -> KeychainRead {
        let current = read(service: Self.service)
        guard current == .notFound else { return current }
        let legacy = read(service: Self.legacyService)
        if case .found(let id) = legacy {
            _ = writeInstallId(id)
        }
        return legacy
    }

    private func read(service: String) -> KeychainRead {
        var query = itemQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return .notFound }
            return .found(value)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .locked
        default:
            return .failed(status)
        }
    }

    func writeInstallId(_ id: String) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(id.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery.merging(attributes) { _, new in new }
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }
}

/// The standard UserDefaults suite (thread-safe).
final class SystemDefaults: DefaultsStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }

    func set(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

/// `Application Support/kerdly/`; every write is atomic (write to a temporary file, then rename).
final class SystemFileStore: FileStoring {
    private let directory: URL?
    private let created = Locked(false)

    /// `legacyFolder`: where builds before 0.1.0 kept the same files. When only it exists, it is
    /// renamed to `folder`, or used where it is if it cannot be, so an updated app keeps its state
    /// and queued events.
    init(folder: String = "kerdly", legacyFolder: String? = "afr") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let target = base?.appendingPathComponent(folder, isDirectory: true)
        directory = Self.adoptLegacy(base: base, target: target, legacyFolder: legacyFolder)
    }

    private static func adoptLegacy(base: URL?, target: URL?, legacyFolder: String?) -> URL? {
        guard let base, let target, let legacyFolder else { return target }
        let legacy = base.appendingPathComponent(legacyFolder, isDirectory: true)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: target.path), fileManager.fileExists(atPath: legacy.path) else {
            return target
        }
        do {
            try fileManager.moveItem(at: legacy, to: target)
            return target
        } catch {
            return legacy
        }
    }

    func read(_ name: String) -> Data? {
        guard let url = directory?.appendingPathComponent(name) else { return nil }
        return try? Data(contentsOf: url)
    }

    func write(_ data: Data, to name: String) -> Bool {
        guard let directory else { return false }
        do {
            if !created.get() {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                created.set(true)
            }
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            return true
        } catch {
            created.set(false)
            return false
        }
    }

    func remove(_ name: String) {
        guard let url = directory?.appendingPathComponent(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// `URLSession` without cookies or a URL cache (the config's ETag is handled by the SDK).
final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func send(_ request: HTTPRequest, completion: @escaping @Sendable (HTTPResult) -> Void) {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        session.dataTask(with: urlRequest) { data, response, error in
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(error.map { String(describing: $0) } ?? "no HTTP response"))
                return
            }
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                if let name = name as? String {
                    headers[name.lowercased()] = "\(value)"
                }
            }
            completion(.response(status: http.statusCode, headers: headers, body: data ?? Data()))
        }.resume()
    }
}

struct SystemClock: Clock {
    func now() -> Date { Date() }
}

/// Runs delayed work on the SDK's queue.
struct DispatchScheduler: Scheduling {
    let queue: DispatchQueue

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Cancellable {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return WorkItemCancellable(item: item)
    }
}

private struct WorkItemCancellable: Cancellable, @unchecked Sendable {
    let item: DispatchWorkItem
    func cancel() { item.cancel() }
}
