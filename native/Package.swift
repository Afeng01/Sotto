// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SottoNative",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CZlib"),
        .executableTarget(
            name: "Sotto",
            dependencies: ["CZlib"],
            path: "Sources/Sotto"
        ),
    ]
)
