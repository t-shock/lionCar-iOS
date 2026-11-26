// swift-tools-version: 6.0
import PackageDescription

// The iPhone app. Built with xtool (https://xtool.sh); the car logic lives in Core/ and is tested on its own.
let package = Package(
    name: "LionCar",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // An xtool project contains exactly one library product: the app.
        .library(name: "LionCar", targets: ["LionCar"]),
    ],
    dependencies: [.package(path: "Core")],
    targets: [
        .target(
            name: "LionCar",
            dependencies: [.product(name: "LionCore", package: "Core")],
            // xtool records the minimum iOS (17) as the SDK the app was built with, so iOS 26+ treats LionCar as an old
            // app and keeps the old full-width tab bar and bars. Record the real SDK (27.2) — still runs on iOS 17.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "ios", "-Xlinker", "17.0", "-Xlinker", "27.2"])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
