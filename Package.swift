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
        .target(name: "LionCar", dependencies: [.product(name: "LionCore", package: "Core")]),
    ],
    swiftLanguageModes: [.v5]
)
