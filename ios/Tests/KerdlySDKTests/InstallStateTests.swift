import XCTest
@testable import KerdlySDK

/// The install-state matrix, decided purely and then end to end through `configure`
/// with a fake Keychain and UserDefaults.
final class InstallStateTests: XCTestCase {
    let x = "11111111-1111-4111-8111-111111111111"
    let y = "22222222-2222-4222-8222-222222222222"
    let minted = "33333333-3333-4333-8333-333333333333"

    func decide(_ keychain: KeychainRead, _ defaults: String?, failedBefore: Bool = false) -> InstallDecision? {
        InstallIdentityResolver.decide(keychain: keychain, defaults: defaults,
                                       keychainWriteFailedBefore: failedBefore, newId: { self.minted })
    }

    // MARK: Pure decision, the five rows

    func testRow1PresentAndEqualIsAnOrdinaryLaunch() {
        XCTAssertEqual(decide(.found(x), x),
                       InstallDecision(installId: x, state: nil, restoredFrom: nil, writeKeychain: false, writeDefaults: false))
    }

    func testRow2BothAbsentIsAFreshInstall() {
        XCTAssertEqual(decide(.notFound, nil),
                       InstallDecision(installId: minted, state: .fresh, restoredFrom: nil, writeKeychain: true, writeDefaults: true))
    }

    func testRow3KeychainOnlyIsAReinstall() {
        XCTAssertEqual(decide(.found(x), nil),
                       InstallDecision(installId: x, state: .reinstall, restoredFrom: nil, writeKeychain: false, writeDefaults: true))
    }

    func testRow4DefaultsOnlyIsARestoreWithANewId() {
        XCTAssertEqual(decide(.notFound, y),
                       InstallDecision(installId: minted, state: .restore, restoredFrom: y, writeKeychain: true, writeDefaults: true))
    }

    func testRow5DifferentIdsIsARestoreKeepingTheKeychainId() {
        XCTAssertEqual(decide(.found(x), y),
                       InstallDecision(installId: x, state: .restore, restoredFrom: y, writeKeychain: false, writeDefaults: true))
    }

    // MARK: Guards

    func testLockedKeychainDefersTheDecision() {
        XCTAssertNil(decide(.locked, x))
        XCTAssertNil(decide(.locked, nil))
    }

    func testUnusableKeychainTrustsUserDefaultsAlone() {
        XCTAssertEqual(decide(.failed(-34018), x),
                       InstallDecision(installId: x, state: nil, restoredFrom: nil, writeKeychain: true, writeDefaults: false))
        XCTAssertEqual(decide(.failed(-34018), nil)?.state, .fresh)
    }

    func testAFailedKeychainWriteIsNotMistakenForARestore() {
        XCTAssertEqual(decide(.notFound, x, failedBefore: true),
                       InstallDecision(installId: x, state: nil, restoredFrom: nil, writeKeychain: true, writeDefaults: false))
    }

    func testIdsAreNormalisedAndCorruptCopiesCountAsAbsent() {
        XCTAssertEqual(decide(.found(x.uppercased()), x)?.state, nil)
        XCTAssertEqual(decide(.found("not-a-uuid"), nil)?.state, .fresh)
        XCTAssertEqual(decide(.found(x), "garbage")?.state, .reinstall)
    }

    func testNewIdsAreLowercaseUUIDv4() {
        let id = InstallIdentityResolver.makeId()
        XCTAssertEqual(id, id.lowercased())
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(Array(id)[14], "4")
    }

    // MARK: End to end through configure

    private func launch(keychain: String?, defaults: String?) -> Harness {
        let h = Harness(keychain: FakeKeychain(keychain),
                        defaults: FakeDefaults(defaults.map { [KerdlyCore.defaultsInstallIdKey: $0] } ?? [:]))
        h.configure()
        return h
    }

    private func installEvent(_ h: Harness) -> QueuedEvent? {
        h.queuedEvents.first { $0.name == "$install" }
    }

    func testASecretKeyLeavesTheSdkOff() {
        let log = KerdlyLogger()
        XCTAssertFalse(KerdlyCore.validate(Harness.options { $0.key = "sk_live_123" }, log: log))
        XCTAssertTrue(KerdlyCore.validate(Harness.options(), log: log))

        let h = Harness()
        h.configure { $0.key = "sk_live_123" }
        XCTAssertNil(h.core.installIdBox.get())
        XCTAssertTrue(h.queuedEvents.isEmpty)
        XCTAssertTrue(h.transport.sent.isEmpty)
    }

    func testConfigureRow1EnqueuesOnlyOpen() {
        let h = launch(keychain: x, defaults: x)
        XCTAssertNil(installEvent(h))
        XCTAssertEqual(h.queuedEvents.map(\.name), ["$open"])
        XCTAssertEqual(h.core.installIdBox.get(), x)
        XCTAssertTrue(h.keychain.writes.isEmpty)
    }

    func testConfigureRow2Fresh() throws {
        let h = launch(keychain: nil, defaults: nil)
        let install = try XCTUnwrap(installEvent(h))
        let id = try XCTUnwrap(h.core.installIdBox.get())
        XCTAssertEqual(install.props["install_state"], .string("fresh"))
        XCTAssertEqual(install.props["restored_from"], .null)
        XCTAssertEqual(install.props["installed_at"], .int(1_760_399_981_000))
        XCTAssertEqual(install.props["installed_at_source"], .string("documents_dir"))
        XCTAssertEqual(install.props["first_launch_at"], .int(Clocks.ms(Harness.start)))
        XCTAssertEqual(install.seq, 1)
        XCTAssertEqual(h.queuedEvents.map(\.name), ["$install", "$open"])
        XCTAssertEqual(h.keychain.value, id)
        XCTAssertEqual(h.defaults.string(forKey: KerdlyCore.defaultsInstallIdKey), id)
    }

    func testConfigureRow3Reinstall() throws {
        let h = launch(keychain: x, defaults: nil)
        XCTAssertEqual(try XCTUnwrap(installEvent(h)).props["install_state"], .string("reinstall"))
        XCTAssertEqual(h.core.installIdBox.get(), x)
        XCTAssertEqual(h.defaults.string(forKey: KerdlyCore.defaultsInstallIdKey), x)
        XCTAssertTrue(h.keychain.writes.isEmpty)
    }

    func testConfigureRow4RestoreOntoAnotherDevice() throws {
        let h = launch(keychain: nil, defaults: y)
        let install = try XCTUnwrap(installEvent(h))
        let id = try XCTUnwrap(h.core.installIdBox.get())
        XCTAssertNotEqual(id, y)
        XCTAssertEqual(install.props["install_state"], .string("restore"))
        XCTAssertEqual(install.props["restored_from"], .string(y))
        XCTAssertEqual(h.keychain.value, id)
        XCTAssertEqual(h.defaults.string(forKey: KerdlyCore.defaultsInstallIdKey), id)
    }

    func testConfigureRow5RestoreOntoADeviceThatHadTheApp() throws {
        let h = launch(keychain: x, defaults: y)
        let install = try XCTUnwrap(installEvent(h))
        XCTAssertEqual(h.core.installIdBox.get(), x)
        XCTAssertEqual(install.props["install_state"], .string("restore"))
        XCTAssertEqual(install.props["restored_from"], .string(y))
        XCTAssertEqual(h.defaults.string(forKey: KerdlyCore.defaultsInstallIdKey), x)
    }

    func testRestoreResetsInstallScopedStateButKeepsTheUser() throws {
        // A backup carries the old install's state file; the restore starts a new install.
        let files = InMemoryFiles()
        var old = PersistedState(installId: y)
        old.seq = 42
        old.userId = "user-1"
        old.consentAnalytics = false
        old.reportedPurchaseIds = ["2000001"]
        files.write(KerdlyJSON.encode(old)!, to: StateFiles.state)
        files.write(KerdlyJSON.encode(QueueFile(installId: y, events: [
            QueuedEvent(id: "e1", name: "old", ts: 1, seq: 41, userId: nil, props: [:]),
        ]))!, to: StateFiles.queue)
        let h = Harness(keychain: FakeKeychain(nil), defaults: FakeDefaults([KerdlyCore.defaultsInstallIdKey: y]), files: files)
        h.configure()
        let state = h.state
        XCTAssertNotEqual(state.installId, y)
        XCTAssertEqual(state.userId, "user-1")
        XCTAssertFalse(state.consentAnalytics)
        XCTAssertTrue(state.reportedPurchaseIds.isEmpty)
        XCTAssertEqual(h.queuedEvents.map(\.name), ["$install", "$open"], "the other install's queue is discarded")
        XCTAssertEqual(h.queuedEvents.first?.seq, 1)
        XCTAssertEqual(h.queuedEvents.first?.userId, "user-1")
    }

    func testAnInstallIdKeptUnderTheKeysOfBuildsBefore010IsKept() {
        let defaults = FakeDefaults([KerdlyCore.legacyDefaultsInstallIdKey: x])
        defaults.set(true, forKey: KerdlyCore.legacyDefaultsKeychainFailedKey)
        let h = Harness(keychain: FakeKeychain(nil), defaults: defaults)
        h.configure()
        XCTAssertEqual(h.core.installIdBox.get(), x)
        XCTAssertEqual(defaults.string(forKey: KerdlyCore.defaultsInstallIdKey), x)
        XCTAssertNil(defaults.string(forKey: KerdlyCore.legacyDefaultsInstallIdKey))
        XCTAssertFalse(defaults.bool(forKey: KerdlyCore.legacyDefaultsKeychainFailedKey))
    }

    func testTheCurrentDefaultsKeyWinsOverALegacyOne() {
        let defaults = FakeDefaults([KerdlyCore.defaultsInstallIdKey: x, KerdlyCore.legacyDefaultsInstallIdKey: y])
        let h = Harness(keychain: FakeKeychain(x), defaults: defaults)
        h.configure()
        XCTAssertEqual(h.core.installIdBox.get(), x)
        XCTAssertNil(defaults.string(forKey: KerdlyCore.legacyDefaultsInstallIdKey))
    }

    func testLockedKeychainWaitsForProtectedData() {
        let keychain = FakeKeychain(x)
        keychain.forcedRead = .locked
        let h = Harness(keychain: keychain, defaults: FakeDefaults([KerdlyCore.defaultsInstallIdKey: x]))
        h.configure()
        XCTAssertNil(h.core.installIdBox.get())
        XCTAssertTrue(h.queuedEvents.isEmpty)
        h.core.apiTrack("registration", properties: [:])
        h.settle()
        keychain.forcedRead = nil
        h.lifecycle.send(.protectedDataAvailable)
        h.settle()
        XCTAssertEqual(h.core.installIdBox.get(), x)
        XCTAssertEqual(h.queuedEvents.map(\.name), ["$open", "registration"], "calls made while waiting are replayed")
    }

    // MARK: $install device

    /// The batch context without `consent`.
    private func contextWithoutConsent(_ context: JSONValue?) -> JSONValue? {
        guard var object = context?.objectValue else { return nil }
        XCTAssertNotNil(object.removeValue(forKey: "consent"))
        return .object(object)
    }

    func testInstallDeviceIsTheBatchContextWithoutConsent() throws {
        let h = Harness()
        h.serveAcceptAll()
        h.tracking.current.set(.denied)
        h.configure()
        let install = try XCTUnwrap(h.transport.sentEvents.first { $0["name"] == .string("$install") })
        let device = try XCTUnwrap(install["props"]?["device"])
        let sentContext = try XCTUnwrap(h.transport.batches.first?["context"])
        XCTAssertEqual(device, contextWithoutConsent(sentContext))
        XCTAssertEqual(device["att"], .string("denied"))
        XCTAssertEqual(device.keys, ["platform", "os", "model", "manufacturer", "locale", "languages", "tz", "screen",
                                     "idfv", "att", "app_version", "app_build"])
    }

    func testEveryInstallStateCarriesTheDevice() throws {
        for (keychain, defaults) in [(nil, nil), (x, nil), (nil, y), (x, y)] as [(String?, String?)] {
            let h = launch(keychain: keychain, defaults: defaults)
            let device = try XCTUnwrap(installEvent(h)?.props["device"], "\(String(describing: keychain)) / \(String(describing: defaults))")
            XCTAssertEqual(device, contextWithoutConsent(h.onQueue { $0.currentContext() }))
        }
    }

    func testInstallDeviceIsTakenAtEnqueue() throws {
        let h = launch(keychain: nil, defaults: nil)
        let before = try XCTUnwrap(installEvent(h)?.props["device"])
        h.device.deviceFacts.update { $0.locale = "es_MX"; $0.timeZone = "America/Mexico_City" }
        h.tracking.current.set(.authorized)
        h.lifecycle.send(.willEnterForeground)
        h.lifecycle.send(.didBecomeActive)
        h.settle()
        let context = h.onQueue { $0.currentContext() }
        XCTAssertEqual(context["locale"], .string("es_MX"))
        XCTAssertEqual(context["att"], .string("authorized"))
        XCTAssertEqual(installEvent(h)?.props["device"], before, "the queued snapshot does not follow the device")
        XCTAssertEqual(before["locale"], .string("en_US"))
        XCTAssertEqual(before["att"], .string("not_determined"))
    }

    func testInstallDeviceOmitsWhatTheContextOmits() throws {
        // No IDFV from UIKit yet: absent from both, never null.
        let h = Harness()
        h.device.deviceSnapshot.update { $0.idfv = nil }
        h.configure()
        let device = try XCTUnwrap(installEvent(h)?.props["device"])
        XCTAssertNil(device["idfv"])
        XCTAssertNotNil(device["screen"])
        XCTAssertEqual(device, contextWithoutConsent(h.onQueue { $0.currentContext() }))

        // configure off the main thread: no UIKit snapshot at enqueue, so no screen or IDFV.
        let offMain = Harness()
        let core = offMain.core, options = Harness.options()
        let configured = expectation(description: "configured")
        Thread.detachNewThread {
            core.configure(options)
            configured.fulfill()
        }
        wait(for: [configured], timeout: 5)
        offMain.settle()
        let bare = try XCTUnwrap(installEvent(offMain)?.props["device"])
        XCTAssertNil(bare["screen"])
        XCTAssertNil(bare["idfv"])
        XCTAssertEqual(bare["app_version"], .string("5.12"), "the app facts are read before the snapshot")
        XCTAssertEqual(bare["os"], .string("26.0.1"))
    }
}
