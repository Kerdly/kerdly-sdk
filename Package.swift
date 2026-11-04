// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KerdlySDK",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "KerdlySDK", targets: ["KerdlySDK"]),
    ],
    targets: [
        .target(
            name: "KerdlySDK",
            path: "ios/Sources/KerdlySDK",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "KerdlySDKTests",
            dependencies: ["KerdlySDK"],
            path: "ios/Tests/KerdlySDKTests",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
