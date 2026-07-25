// swift-tools-version: 5.9
//
// SwiftPM manifest for the testable core only. The iOS app (SwellApp) is
// built from the XcodeGen-generated Swell.xcodeproj; this package exists so
// `swift test` can run the RadioKit unit tests headlessly (CI, no simulator).
import PackageDescription

let package = Package(
    name: "RadioKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    targets: [
        .target(
            name: "RadioKit",
            path: "Sources/RadioKit",
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "RadioKitTests",
            dependencies: ["RadioKit"],
            path: "Tests/RadioKitTests"
        ),
    ]
)
