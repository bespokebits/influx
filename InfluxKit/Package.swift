// swift-tools-version: 6.2
import PackageDescription

// InfluxKit holds everything that isn't UI: connectors, normalization, the
// merge/filter/dedupe functions, storage, sync and row layout. It must stay
// free of UIKit and AppKit so `swift test` covers it on Linux.
let package = Package(
    name: "InfluxKit",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
    ],
    products: [
        .library(name: "InfluxKit", targets: ["InfluxKit"]),
    ],
    dependencies: [
        // The store. The only third-party package.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "InfluxKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "InfluxKitTests",
            dependencies: ["InfluxKit"],
            // Recorded service responses the connector tests replay.
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
