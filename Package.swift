// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RetronCommander",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RetronCommander", targets: ["RetronCommander"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")
    ],
    targets: [
        .target(name: "RetronCopyFile", publicHeadersPath: "include"),
        .executableTarget(
            name: "RetronCommander",
            dependencies: [
                "RetronCopyFile",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/RetronCommander",
            exclude: ["Resources/Toolbars"],
            resources: [.process("Resources")]
        )
    ]
)
