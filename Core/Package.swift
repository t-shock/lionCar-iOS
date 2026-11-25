// swift-tools-version: 6.0
import PackageDescription

// The car logic, ported from LionFlow's Android code. Foundation only, so it builds and is tested on Linux too.
let package = Package(
    name: "LionCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LionCore", targets: ["LionCore"])],
    dependencies: [
        // Pure Swift, so they build on Linux and iOS alike: AES/SHA-256 and big numbers for the one-time-code generator.
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", exact: "1.10.0"),
        .package(url: "https://github.com/attaswift/BigInt.git", .upToNextMajor(from: "5.4.0")),
    ],
    targets: [
        .target(name: "LionCore", dependencies: ["CryptoSwift", "BigInt"]),
        .testTarget(name: "LionCoreTests", dependencies: ["LionCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
