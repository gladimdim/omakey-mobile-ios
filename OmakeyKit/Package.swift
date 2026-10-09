// swift-tools-version: 6.0
import PackageDescription

// The protocol and the keyboard logic, free of UIKit: the app links these,
// and `swift test` runs their tests on a Mac without a simulator.
let package = Package(
    name: "OmakeyKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OmakeyProtocol", targets: ["OmakeyProtocol"]),
    ],
    targets: [
        .target(name: "OmakeyProtocol"),
        .testTarget(
            name: "OmakeyProtocolTests",
            dependencies: ["OmakeyProtocol"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
