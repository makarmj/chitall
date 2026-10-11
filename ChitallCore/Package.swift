// swift-tools-version: 6.0
import PackageDescription

// Platform-independent core of Chitall: FB2 parsing, the format-agnostic reading model,
// locators and export. It must not import UIKit, SwiftUI or SwiftData so that it builds
// and tests on macOS, Linux and Windows alike.
let package = Package(
    name: "ChitallCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ChitallCore", targets: ["ChitallCore"]),
    ],
    targets: [
        .target(name: "ChitallCore"),
        .testTarget(
            name: "ChitallCoreTests",
            dependencies: ["ChitallCore"],
            exclude: ["Fixtures"]
        ),
    ]
)
