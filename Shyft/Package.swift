// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Shyft",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Shyft",
            path: "Sources"
        )
    ]
)
