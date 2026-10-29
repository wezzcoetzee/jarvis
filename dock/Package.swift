// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JarvisDock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "JarvisDock", linkerSettings: [.linkedFramework("Carbon")]),
    ]
)
