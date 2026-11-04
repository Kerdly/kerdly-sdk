import XCTest
@testable import KerdlySDK

/// `environment: .auto`.
final class EnvironmentTests: XCTestCase {
    func inputs(simulator: Bool = false, debug: Bool = false, devSigned: Bool = false,
                receipt: String? = "receipt") -> EnvironmentInputs {
        EnvironmentInputs(isSimulator: simulator, isDebugBuild: debug, isDevelopmentSigned: devSigned, receiptName: receipt)
    }

    func testAutoDetection() {
        XCTAssertEqual(EnvironmentResolver.resolve(option: .auto, inputs: inputs()), "production")
        XCTAssertEqual(EnvironmentResolver.resolve(option: .auto, inputs: inputs(receipt: nil)), "production")
        XCTAssertEqual(EnvironmentResolver.resolve(option: .auto, inputs: inputs(receipt: "sandboxReceipt")), "sandbox",
                       "TestFlight")
        XCTAssertEqual(EnvironmentResolver.resolve(option: .auto, inputs: inputs(simulator: true)), "development")
        XCTAssertEqual(EnvironmentResolver.resolve(option: .auto, inputs: inputs(debug: true, receipt: "sandboxReceipt")),
                       "development", "a debug build wins over its sandbox receipt")
        XCTAssertEqual(EnvironmentResolver.resolve(option: .auto, inputs: inputs(devSigned: true, receipt: "sandboxReceipt")),
                       "development", "a release build run from Xcode")
    }

    func testAnExplicitOptionWins() {
        XCTAssertEqual(EnvironmentResolver.resolve(option: .production, inputs: inputs(simulator: true)), "production")
        XCTAssertEqual(EnvironmentResolver.resolve(option: .sandbox, inputs: inputs()), "sandbox")
        XCTAssertEqual(EnvironmentResolver.resolve(option: .development, inputs: inputs()), "development")
    }

    func testProvisioningProfileGetTaskAllow() {
        func profile(_ entitlement: String) -> Data {
            Data("""
            \u{30}\u{80}garbage<?xml version="1.0" encoding="UTF-8"?><plist><dict><key>Entitlements</key><dict>
            <key>application-identifier</key><string>ABC.com.example</string>
            <key>get-task-allow</key>
                \(entitlement)
            </dict></dict></plist>\u{00}\u{ff}
            """.utf8)
        }
        XCTAssertTrue(EnvironmentResolver.profileAllowsDebugging(profile("<true/>")))
        XCTAssertFalse(EnvironmentResolver.profileAllowsDebugging(profile("<false/>")))
        XCTAssertFalse(EnvironmentResolver.profileAllowsDebugging(Data("no plist here".utf8)))
    }

    func testTheBatchCarriesTheResolvedEnvironment() throws {
        let h = Harness()
        h.device.environment.set(EnvironmentInputs(isSimulator: true, isDebugBuild: false,
                                                   isDevelopmentSigned: false, receiptName: nil))
        h.configure()
        XCTAssertEqual(h.transport.batches.first?["app"]?["environment"], .string("development"))

        let pinned = Harness()
        pinned.device.environment.set(EnvironmentInputs(isSimulator: true, isDebugBuild: true,
                                                        isDevelopmentSigned: true, receiptName: nil))
        pinned.configure { $0.environment = .production }
        XCTAssertEqual(pinned.transport.batches.first?["app"]?["environment"], .string("production"))
    }
}
