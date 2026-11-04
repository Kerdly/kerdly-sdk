import Foundation

/// The result of reading the Keychain copy of the install id.
enum KeychainRead: Equatable, Sendable {
    case found(String)
    case notFound
    /// The item exists but the device has not been unlocked since boot
    /// (`errSecInteractionNotAllowed`): nothing can be decided until it is.
    case locked
    /// Any other Keychain failure (e.g. a missing entitlement): the Keychain is unusable this launch.
    case failed(Int32)
}

/// `install_state` of a `$install`.
enum InstallState: String, Sendable {
    case fresh, reinstall, restore
}

struct InstallDecision: Equatable, Sendable {
    let installId: String
    /// nil for an ordinary launch; otherwise a `$install` is due.
    let state: InstallState?
    /// `restore` only: the id found in UserDefaults.
    let restoredFrom: String?
    let writeKeychain: Bool
    let writeDefaults: Bool
}

/// The install-state matrix:
///
/// | Keychain | UserDefaults      | Meaning           | Action                                           |
/// |----------|-------------------|-------------------|--------------------------------------------------|
/// | present  | present, equal    | ordinary launch   | none                                             |
/// | absent   | absent            | fresh install     | new id in both; `fresh`                          |
/// | present  | absent            | reinstall         | keep the Keychain id; write UserDefaults; `reinstall` |
/// | absent   | present           | restore elsewhere | NEW id in both; `restore`, `restored_from` = UserDefaults id |
/// | present  | present, different| restore here      | keep the Keychain id; rewrite UserDefaults; `restore` |
///
/// Two guards keep a broken Keychain from minting fake restores: a Keychain that cannot be read
/// (other than "not found"), or one whose last write failed, is not trusted, and UserDefaults alone
/// decides.
enum InstallIdentityResolver {
    /// - Returns: nil when the Keychain is locked (before the first unlock): retry later.
    static func decide(keychain: KeychainRead,
                       defaults rawDefaults: String?,
                       keychainWriteFailedBefore: Bool,
                       newId: () -> String) -> InstallDecision? {
        let defaults = normalize(rawDefaults)
        let kc: String?
        let keychainUsable: Bool
        switch keychain {
        case .locked:
            return nil
        case .failed:
            kc = nil
            keychainUsable = false
        case .found(let raw):
            kc = normalize(raw)
            keychainUsable = true
        case .notFound:
            kc = nil
            keychainUsable = true
        }

        if !keychainUsable || (kc == nil && keychainWriteFailedBefore && defaults != nil) {
            if let d = defaults {
                return InstallDecision(installId: d, state: nil, restoredFrom: nil,
                                       writeKeychain: true, writeDefaults: false)
            }
            return InstallDecision(installId: newId(), state: .fresh, restoredFrom: nil,
                                   writeKeychain: true, writeDefaults: true)
        }

        switch (kc, defaults) {
        case let (k?, d?) where k == d:
            return InstallDecision(installId: k, state: nil, restoredFrom: nil,
                                   writeKeychain: false, writeDefaults: false)
        case (nil, nil):
            return InstallDecision(installId: newId(), state: .fresh, restoredFrom: nil,
                                   writeKeychain: true, writeDefaults: true)
        case let (k?, nil):
            return InstallDecision(installId: k, state: .reinstall, restoredFrom: nil,
                                   writeKeychain: false, writeDefaults: true)
        case let (nil, d?):
            return InstallDecision(installId: newId(), state: .restore, restoredFrom: d,
                                   writeKeychain: true, writeDefaults: true)
        case let (k?, d?):
            return InstallDecision(installId: k, state: .restore, restoredFrom: d,
                                   writeKeychain: false, writeDefaults: true)
        }
    }

    /// A lowercase UUID string, or nil for anything that is not a UUID (a corrupted copy is
    /// treated as absent).
    static func normalize(_ value: String?) -> String? {
        guard let value, let uuid = UUID(uuidString: value.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return uuid.uuidString.lowercased()
    }

    /// A new lowercase UUIDv4.
    static func makeId() -> String {
        UUID().uuidString.lowercased()
    }
}
