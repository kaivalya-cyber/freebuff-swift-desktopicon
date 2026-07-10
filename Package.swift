// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Freebuff",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Freebuff",
            path: "Sources/Freebuff"
        ),
        .testTarget(
            name: "FreebuffTests",
            dependencies: ["Freebuff"],
            path: "Tests/FreebuffTests"
        )
    ]
)
