// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "latency-harness",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../../phoros"),
        .package(path: "../../../phoros/Core"),
    ],
    targets: [
        .executableTarget(
            name: "harness-client",
            dependencies: [
                .product(name: "Phoros", package: "phoros"),
                .product(name: "PhorosSession", package: "phoros"),
                .product(name: "PhorosNetwork", package: "phoros"),
                .product(name: "PhorosMedia", package: "phoros"),
                .product(name: "PhorosInput", package: "phoros"),
                .product(name: "PhorosCore", package: "Core"),
            ]
        ),
    ]
)
