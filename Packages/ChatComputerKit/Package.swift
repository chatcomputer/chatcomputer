// swift-tools-version: 6.2
import PackageDescription

// Platform-neutral modules (BridgeProtocol, ChatCore, ModelProxy, Orchestrator)
// build and test on Linux too, so CI can cover them without a Mac.
// VMKit, GuestBridge and AgentCore wrap Apple-only frameworks; their sources
// are guarded with `#if os(macOS)` and compile to empty modules elsewhere.
let package = Package(
    name: "ChatComputerKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "BridgeProtocol", targets: ["BridgeProtocol"]),
        .library(name: "ChatCore", targets: ["ChatCore"]),
        .library(name: "ModelProxy", targets: ["ModelProxy"]),
        .library(name: "Orchestrator", targets: ["Orchestrator"]),
        .library(name: "VMKit", targets: ["VMKit"]),
        .library(name: "GuestBridge", targets: ["GuestBridge"]),
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "HostControl", targets: ["HostControl"]),
        .library(name: "ComputerControl", targets: ["ComputerControl"]),
    ],
    targets: [
        // Shared by host and guest: wire format between the app and the guest agent.
        .target(name: "BridgeProtocol"),

        // Host: task state machine, control lease, policy, task store, Keychain.
        .target(name: "ChatCore"),

        // Host: Claude Messages API client and computer-use toolset mapping.
        .target(name: "ModelProxy", dependencies: ["BridgeProtocol", "ChatCore"]),

        // Host: the agent loop tying model, policy and guest together.
        .target(name: "Orchestrator", dependencies: ["BridgeProtocol", "ChatCore", "ModelProxy"]),

        // Host, macOS only: VM bundle, install, provisioning, DiskImageKit, vmnet.
        .target(name: "VMKit", dependencies: ["ChatCore"]),

        // Host, macOS only: vsock server speaking BridgeProtocol to the guest agent.
        .target(name: "GuestBridge", dependencies: ["BridgeProtocol"]),

        // Guest, macOS only: vsock client and desktop drivers.
        .target(name: "AgentCore", dependencies: ["BridgeProtocol"]),

        // Host, macOS only: operates the guest through the VM view (framebuffer, keyboard, mouse)
        // for steps that happen before the guest agent can act, such as granting its permissions.
        .target(name: "HostControl", dependencies: ["BridgeProtocol", "AgentCore"]),

        // Host: the `chatcomputer` command line tool and MCP server that let coding agents outside the
        // app (Claude Code, Codex, …) operate the virtual Mac, and the control socket they reach the app on.
        .target(name: "ComputerControl", dependencies: ["BridgeProtocol", "ModelProxy"]),

        // Developer harness: live model loop against a simulated desktop, and VM probes (macOS only).
        .executableTarget(
            name: "cc-harness",
            dependencies: ["BridgeProtocol", "ChatCore", "ModelProxy", "Orchestrator", "VMKit", "GuestBridge", "AgentCore", "HostControl"],
            path: "Sources/Harness"),

        .testTarget(name: "BridgeProtocolTests", dependencies: ["BridgeProtocol"]),
        .testTarget(name: "ChatCoreTests", dependencies: ["ChatCore"]),
        .testTarget(name: "ModelProxyTests", dependencies: ["ModelProxy"]),
        .testTarget(name: "OrchestratorTests", dependencies: ["Orchestrator"]),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
        .testTarget(name: "VMKitTests", dependencies: ["VMKit"]),
        .testTarget(name: "ComputerControlTests", dependencies: ["ComputerControl"]),
        .testTarget(name: "HostControlTests", dependencies: ["HostControl"], resources: [.copy("SetupAssistantScreens")]),
    ]
)
