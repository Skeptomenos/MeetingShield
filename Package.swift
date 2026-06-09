// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingShield",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MeetingShield", targets: ["MeetingShield"])
    ],
    targets: [
        .executableTarget(
            name: "MeetingShield",
            path: "Sources"
        ),
        .testTarget(
            name: "MeetingShieldTests",
            dependencies: ["MeetingShield"],
            path: "Tests",
            resources: [.copy("Fixtures")]
        )
    ]
)
