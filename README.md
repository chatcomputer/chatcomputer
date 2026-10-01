# Chat Computer

A native macOS app: a macOS virtual machine on the left, a chat with an agent on the right. The agent
operates the VM to finish tasks and hands back verified files. See [docs/ROADMAP.md](docs/ROADMAP.md)
for the plan and [docs/proposal-v0.1.md](docs/proposal-v0.1.md) for the product proposal.

Host and guest are both **macOS 27 on Apple silicon only**, so the app can use the WWDC26
Virtualization features directly: guest provisioning, DiskImageKit layered disks and vmnet networks.

## Layout

```
project.yml                  XcodeGen spec for the two app targets
Apps/ChatComputer/           host app (SwiftUI): VM view, chat, onboarding
Apps/ChatComputerAgent/      guest agent (menu bar app, runs inside the VM)
Packages/ChatComputerKit/    all logic, as a local Swift package
  BridgeProtocol             host⇄guest messages and framing (vsock)
  ChatCore                   task state machine, control lease, budget, export checks, Keychain
  ModelProxy                 Claude Messages API client, computer toolset mapping
  Orchestrator               the agent loop (AgentRunner)
  VMKit           (macOS)    VM bundle, install, provisioning, DiskImageKit, vmnet
  GuestBridge     (macOS)    vsock server on the host
  AgentCore       (macOS)    vsock client and NativeDriver in the guest
scripts/test-linux.sh        builds and tests the portable modules in Docker
```

## Build

Requires macOS 27 and Xcode 27.

```sh
brew install xcodegen
xcodegen generate
open ChatComputer.xcodeproj
```

Set your development team in `project.yml` (or in Xcode). Then run the `ChatComputer` scheme; the
first launch walks through onboarding (download macOS, create the guest account, install the agent,
grant permissions, add an Anthropic API key).

Tests for the portable modules run anywhere with Swift 6.2:

```sh
cd Packages/ChatComputerKit && swift test     # on a Mac
scripts/test-linux.sh                         # in Docker, without a Mac
```

## Status

This is a skeleton for milestone M1 (ROADMAP §4). The portable modules (BridgeProtocol, ChatCore,
ModelProxy, Orchestrator) build and pass their tests. The macOS-only modules and the apps have
**not been compiled yet**: they were written against the macOS 27 APIs shown in WWDC26 session 224,
and lines marked `TODO(P#)` depend on the technical probes in ROADMAP §4.
