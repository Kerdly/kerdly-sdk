import Foundation
import UIKit

/// UIApplication notifications, plus background time to finish a flush.
final class SystemLifecycle: LifecycleObserving, @unchecked Sendable {
    private let observers = Locked<[NSObjectProtocol]>([])
    private let tasks = Locked<[Int: UIBackgroundTaskIdentifier]>([:])
    private let counter = Locked(0)

    func observe(_ handler: @escaping @Sendable (LifecycleEvent) -> Void) {
        let center = NotificationCenter.default
        let pairs: [(Notification.Name, LifecycleEvent)] = [
            (UIApplication.willEnterForegroundNotification, .willEnterForeground),
            (UIApplication.didBecomeActiveNotification, .didBecomeActive),
            (UIApplication.didEnterBackgroundNotification, .didEnterBackground),
            (UIApplication.protectedDataDidBecomeAvailableNotification, .protectedDataAvailable),
        ]
        let added = pairs.map { name, event in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in handler(event) }
        }
        observers.update { $0.append(contentsOf: added) }
    }

    func beginBackgroundTask() -> Int? {
        guard Thread.isMainThread else { return nil }
        let token = counter.update { value -> Int in
            value += 1
            return value
        }
        let identifier = MainActor.assumeIsolated {
            UIApplication.shared.beginBackgroundTask(withName: "com.kerdly.sdk.flush") { [weak self] in
                self?.endBackgroundTask(token)
            }
        }
        guard identifier != .invalid else { return nil }
        tasks.update { $0[token] = identifier }
        return token
    }

    func endBackgroundTask(_ token: Int) {
        guard let identifier = tasks.update({ $0.removeValue(forKey: token) }) else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { UIApplication.shared.endBackgroundTask(identifier) }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { UIApplication.shared.endBackgroundTask(identifier) }
            }
        }
    }
}

extension KerdlyDependencies {
    /// The real system.
    static func system() -> KerdlyDependencies {
        KerdlyDependencies(
            keychain: SystemKeychain(),
            defaults: SystemDefaults(),
            files: SystemFileStore(),
            transport: URLSessionTransport(),
            clock: SystemClock(),
            device: SystemDeviceInfo(),
            tracking: SystemTracking(),
            adServices: SystemAdServices(),
            advertisingId: SystemAdvertisingId(),
            publicIp: SystemPublicIp(),
            storeKit: SystemStoreKit(),
            skanWriter: SystemSkanWriter(),
            lifecycle: SystemLifecycle(),
            makeScheduler: { DispatchScheduler(queue: $0) },
            workQueue: DispatchQueue(label: "com.kerdly.sdk.work", qos: .utility, attributes: .concurrent),
            newId: { InstallIdentityResolver.makeId() },
            unitRandom: { Double.random(in: 0...1) })
    }
}
