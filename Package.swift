// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Zapper",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ATVKit", targets: ["ATVKit"]),
        .executable(name: "zapper", targets: ["zapper"]),
        .executable(name: "ZapperApp", targets: ["ZapperApp"]),
    ],
    targets: [
        .target(name: "ATVKit"),
        .executableTarget(name: "zapper", dependencies: ["ATVKit"]),
        .executableTarget(name: "ZapperApp", dependencies: ["ATVKit"]),
        .testTarget(name: "ATVKitTests", dependencies: ["ATVKit"]),
    ],
    // The app and protocol core were written against the Swift 5 concurrency
    // model (actors and @Sendable used deliberately, but the data-race checker
    // runs as warnings, not errors). Pin that mode so the build is
    // deterministic; the Swift 6 checker surfaces latent diagnostics in working
    // code non-deterministically via the emit-module batch step.
    swiftLanguageModes: [.v5]
)
