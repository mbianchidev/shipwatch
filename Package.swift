// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Shipwatch",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Shipwatch", targets: ["Shipwatch"]),
    ],
    targets: [
        .target(name: "ShipwatchCore"),
        .target(name: "ShipwatchUpdate"),
        .target(name: "ShipwatchUI", dependencies: ["ShipwatchCore"]),
        .executableTarget(name: "Shipwatch", dependencies: ["ShipwatchUI"]),
        .executableTarget(name: "ShipwatchUpdateHelper", dependencies: ["ShipwatchUpdate"]),
        .executableTarget(name: "ShipwatchReleaseTool", dependencies: ["ShipwatchUpdate"]),
        .executableTarget(name: "ShipwatchSnapshots", dependencies: ["ShipwatchUI", "ShipwatchCore"]),
        .testTarget(name: "ShipwatchCoreTests", dependencies: ["ShipwatchCore"]),
        .testTarget(name: "ShipwatchUpdateTests", dependencies: ["ShipwatchUpdate"]),
    ]
)
