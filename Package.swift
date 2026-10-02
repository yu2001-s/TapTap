// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TapTap",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TapCore", targets: ["TapCore"]),
        .executable(name: "taptap", targets: ["taptap"]),
        .executable(name: "TapTapApp", targets: ["TapTapApp"]),
    ],
    targets: [
        .target(name: "TapCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "taptap", dependencies: ["TapCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "TapTapApp", dependencies: ["TapCore"], resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TapTapAppTests", dependencies: ["TapTapApp"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
