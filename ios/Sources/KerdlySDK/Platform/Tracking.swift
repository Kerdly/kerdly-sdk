import Foundation
import UIKit
import AppTrackingTransparency

final class SystemTracking: TrackingAuthorizing {
    func status() -> KerdlyAttStatus {
        Self.map(ATTrackingManager.trackingAuthorizationStatus)
    }

    func canPrompt() -> Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSUserTrackingUsageDescription") != nil
    }

    func request(_ completion: @escaping @Sendable (KerdlyAttStatus) -> Void) {
        ATTrackingManager.requestTrackingAuthorization { status in
            completion(Self.map(status))
        }
    }

    static func map(_ status: ATTrackingManager.AuthorizationStatus) -> KerdlyAttStatus {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}

/// `Kerdly.requestTrackingAuthorization`. iOS shows the ATT dialog only while the app is active; asked
/// earlier (a cold launch's first moments, a background launch) it returns `notDetermined` at once
/// and never asks again. So when the app is not active the request waits for
/// `didBecomeActiveNotification`. A caller still waiting after 5 s is released with the current
/// status, while the request stays armed: the dialog appears when the user opens the app, and the
/// SDK records the answer as `$consent`. Concurrent callers share one system request. The SDK never
/// calls this on its own.
@MainActor
final class TrackingPrompter {
    private let releaseAfter: TimeInterval
    private let tracking: TrackingAuthorizing
    private let center: NotificationCenter
    private let isActive: @MainActor () -> Bool
    private let onDecision: @Sendable (KerdlyAttStatus) -> Void
    private let log: KerdlyLogger
    private var waiters: [Int: (KerdlyAttStatus) -> Void] = [:]
    private var nextWaiter = 0
    private var requesting = false
    private var observer: NSObjectProtocol?

    init(tracking: TrackingAuthorizing, center: NotificationCenter = .default,
         isActive: @escaping @MainActor () -> Bool, log: KerdlyLogger, releaseAfter: TimeInterval = 5,
         onDecision: @escaping @Sendable (KerdlyAttStatus) -> Void) {
        self.releaseAfter = releaseAfter
        self.tracking = tracking
        self.center = center
        self.isActive = isActive
        self.log = log
        self.onDecision = onDecision
    }

    var isArmed: Bool { observer != nil }

    func request(_ completion: @escaping (KerdlyAttStatus) -> Void) {
        let current = tracking.status()
        guard current == .notDetermined else {
            completion(current)
            return
        }
        guard tracking.canPrompt() else {
            log.error("requestTrackingAuthorization: NSUserTrackingUsageDescription is missing from Info.plist")
            completion(current)
            return
        }
        nextWaiter += 1
        let id = nextWaiter
        waiters[id] = completion
        if requesting { return }
        if isActive() {
            fire()
            return
        }
        arm()
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseAfter) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.requesting, let waiter = self.waiters.removeValue(forKey: id) else { return }
                self.log.info("ATT request still waiting for the app to become active; released the caller")
                waiter(self.tracking.status())
            }
        }
    }

    private func arm() {
        guard observer == nil else { return }
        log.info("ATT request deferred until the app is active")
        observer = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
    }

    private func fire() {
        if let observer {
            center.removeObserver(observer)
            self.observer = nil
        }
        guard !requesting else { return }
        requesting = true
        tracking.request { [weak self] status in
            guard let prompter = self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { prompter.settle(status) }
            }
        }
    }

    private func settle(_ status: KerdlyAttStatus) {
        requesting = false
        let pending = waiters
        waiters = [:]
        pending.keys.sorted().forEach { pending[$0]?(status) }
        onDecision(status)
    }
}
