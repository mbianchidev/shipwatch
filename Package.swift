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
        .target(name: "ShipwatchUI", dependencies: ["ShipwatchCore"]),
        .executableTarget(name: "Shipwatch", dependencies: ["ShipwatchUI"]),
        .executableTarget(name: "ShipwatchSnapshots", dependencies: ["ShipwatchUI", "ShipwatchCore"]),
        .testTarget(name: "ShipwatchCoreTests", dependencies: ["ShipwatchCore"]),
    ]
)
