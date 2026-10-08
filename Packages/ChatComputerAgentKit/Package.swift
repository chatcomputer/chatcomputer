// swift-tools-version: 6.2
import PackageDescription

// What the guest agent is built from: the wire format it shares with the host, and its desktop drivers.
// Separate from ChatComputerKit so that it can run in macOS 26 guests while the host side needs macOS 27:
// Launch Services (and so Privacy settings) refuses an app whose binary was built for a newer macOS.
// BridgeProtocol also builds on Linux; AgentCore's sources are guarded with `#if os(macOS)`.
let package = Package(
    name: "ChatComputerAgentKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BridgeProtocol", targets: ["BridgeProtocol"]),
        .library(name: "AgentCore", targets: ["AgentCore"]),
    ],
    targets: [
        // Shared by host and guest: wire format between the app and the guest agent.
        .target(name: "BridgeProtocol"),

        // Guest, macOS only: vsock client and desktop drivers.
        .target(name: "AgentCore", dependencies: ["BridgeProtocol"]),
    ]
)
