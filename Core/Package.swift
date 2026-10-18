// swift-tools-version:5.9
import PackageDescription

// CelloCloud's encryption, byte-for-byte the same as the website (web/crypto.js) and the
// Android app (Crypto.kt). Kept apart from the app so it can be tested on its own.
let package = Package(
    name: "CelloCloudCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CelloCloudCore", targets: ["CelloCloudCore"])],
    targets: [
        .target(name: "CelloCloudCore"),
        .testTarget(name: "CelloCloudCoreTests", dependencies: ["CelloCloudCore"]),
    ]
)
