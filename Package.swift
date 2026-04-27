// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VenvDeck",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "VenvDeckCore",
            targets: ["VenvDeckCore"]
        ),
        .executable(
            name: "VenvDeck",
            targets: ["VenvDeck"]
        )
    ],
    targets: [
        .target(
            name: "VenvDeckCore"
        ),
        .executableTarget(
            name: "VenvDeck",
            dependencies: ["VenvDeckCore"],
            resources: [
                .copy("AppIcon.icns")
            ]
        ),
        .testTarget(
            name: "VenvDeckCoreTests",
            dependencies: ["VenvDeckCore"]
        )
    ]
)
