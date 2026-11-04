// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VMCallbackProbe",
    platforms: [.macOS("27.0")],
    dependencies: [.package(path: "../../../Packages/ChatComputerKit")],
    targets: [.executableTarget(name: "VMCallbackProbe", dependencies: [
        .product(name: "VMKit", package: "ChatComputerKit")
    ])]
)
