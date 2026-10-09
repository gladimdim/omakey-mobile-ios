// swift-tools-version: 6.0
import PackageDescription

// The protocol and the keyboard logic, free of UIKit: the app links these,
// and `swift test` runs their tests on a Mac without a simulator.
let package = Package(
    name: "OmakeyKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OmakeyProtocol", targets: ["OmakeyProtocol"]),
        .library(name: "OmakeyCore", targets: ["OmakeyCore"]),
        .library(name: "OmakeyNet", targets: ["OmakeyNet"]),
        .library(name: "OmakeydStandIn", targets: ["OmakeydStandIn"]),
        .executable(name: "omakey-dev-server", targets: ["omakey-dev-server"]),
    ],
    targets: [
        .target(name: "OmakeyProtocol"),
        .target(
            name: "OmakeyCore",
            dependencies: ["OmakeyProtocol"],
            resources: [.copy("Spec")]
        ),
        .target(name: "OmakeyNet", dependencies: ["OmakeyProtocol"]),
        // A stand-in for omakeyd that types nothing: tests, the dev server, demo mode.
        .target(name: "OmakeydStandIn", dependencies: ["OmakeyNet", "OmakeyProtocol"]),
        // A computer for the simulator to pair with (macOS): `swift run omakey-dev-server`.
        .executableTarget(name: "omakey-dev-server", dependencies: ["OmakeydStandIn", "OmakeyCore", "OmakeyNet", "OmakeyProtocol"]),
        .testTarget(
            name: "OmakeyProtocolTests",
            dependencies: ["OmakeyProtocol"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "OmakeyCoreTests", dependencies: ["OmakeyCore", "OmakeyProtocol"]),
        .testTarget(name: "OmakeyNetTests", dependencies: ["OmakeyNet", "OmakeydStandIn", "OmakeyProtocol"]),
    ]
)
