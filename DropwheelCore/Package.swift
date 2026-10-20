// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DropwheelCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DropwheelCore", targets: ["DropwheelCore"])],
    targets: [
        .target(name: "DropwheelCore", swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")]),
        .testTarget(name: "DropwheelCoreTests", dependencies: ["DropwheelCore"], swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")]),
    ]
)
