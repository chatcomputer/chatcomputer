# Chat Computer

A native macOS app: a macOS virtual machine on the left, a chat with an agent on the right. You describe a
task in the chat; the agent operates the VM (screen, mouse, keyboard) and hands back files that the host
has verified. You can pause, take over by clicking the VM screen, or cancel at any time.

Host and guest are both **macOS 27 on Apple silicon only**, so the app uses the WWDC26 Virtualization
features directly: guest provisioning, DiskImageKit layered disks and vmnet networks.

**Status:** 0.1.1 preview. Setup, model connection and real tasks work end to end on a macOS 27 VM.
See [docs/STATUS.md](docs/STATUS.md) for what works, measured results, known issues and the plan.

## Install

Download `ChatComputer.zip` from [Releases](https://github.com/chatcomputer/chatcomputer/releases),
unzip it and move **Chat Computer.app** to Applications. It is signed with a Developer ID and notarized.

You need macOS 27 on Apple silicon, 16 GB of memory or more, about 70 GB of free disk space, and an API key
for a model provider. The first launch walks through six steps:

1. Install macOS, using a downloaded `.ipsw` or downloading about 26 GB.
2. Create the guest account.
3. Install the guest agent.
4. Grant the agent its permissions. This is automatic.
5. Save a clean starting point.
6. Connect a model.

## Models

The agent works from screenshots, so the model must take images and call tools. Two protocols are supported:

- **Anthropic-compatible** (Messages API). With Anthropic itself it uses Claude's computer use toolset.
- **OpenAI-compatible** (Chat Completions with function calling).

Built-in providers are Anthropic, OpenAI, Google Gemini, DeepSeek, xAI, Mistral, Alibaba Qwen,
Moonshot Kimi, Zhipu GLM and ByteDance Doubao, plus any custom compatible endpoint. See
`Packages/ChatComputerKit/Sources/ModelProxy/ModelCatalog.swift`.

## Coding agents

Claude Code, Codex and other agents on your Mac can operate the virtual Mac too. The app's executable doubles
as the `chatcomputer` command line tool (Settings › Coding agents installs it on your PATH):

```sh
chatcomputer help                      # usage and guidance for agents
chatcomputer screenshot                # saves a PNG and prints its path
chatcomputer click 640 400
chatcomputer type "hello"; chatcomputer key cmd+s
chatcomputer snapshot take "Before update"
chatcomputer mcp                       # the same commands as an MCP server on stdio
```

For Claude Code: `claude mcp add chatcomputer -- chatcomputer mcp`, or just tell it to use the command.
Agents follow the built-in agent's rules: the first input command takes the input lease, clicking the screen takes
it back, and an idle agent loses it after 2 minutes. The app listens on a 0600 Unix socket in
`~/Library/Application Support/ChatComputer/`. The chat panel collapses to a rail of controls (⌃⌘S) while an agent works.

## Layout

```
project.yml                  XcodeGen spec (targets, entitlements, Info.plist, version)
Apps/ChatComputer/           host app (SwiftUI): guest screen, chat, onboarding, model settings
Apps/ChatComputerAgent/      guest agent (menu bar app inside the VM)
Packages/ChatComputerKit/    all logic, as a local Swift package
  BridgeProtocol             host⇄guest messages and framing (vsock)
  ChatCore                   task state machine, control lease, budget, export checks, secret files
  ModelProxy                 Anthropic and OpenAI-compatible clients, provider catalog, computer toolset
  Orchestrator               the agent loop (AgentRunner)
  VMKit           (macOS)    VM bundle, install, provisioning, DiskImageKit, vmnet
  GuestBridge     (macOS)    vsock server on the host
  HostControl     (macOS)    host-level control of the guest (framebuffer, keyboard, mouse)
  ComputerControl            `chatcomputer` CLI and MCP server for outside coding agents, control socket
  AgentCore       (macOS)    vsock client and NativeDriver in the guest
  Harness         (macOS)    cc-harness: live model scenarios and VM probes
scripts/                     test-mac.sh, harness.sh, release.sh, test-linux.sh
docs/                        STATUS, ROADMAP, DESIGN, proposal
```

## Build

Requires macOS 27 and Xcode 27.

```sh
brew install xcodegen
xcodegen generate
open ChatComputer.xcodeproj
```

The development team is set in `project.yml`. A stable signature matters: the guest's permission grants
belong to the agent's signing identity.

## Test

```sh
scripts/test-mac.sh                                  # unit tests, build, host API checks, live scenarios if CC_API_KEY is set
cd Packages/ChatComputerKit && swift test            # unit tests only
scripts/harness.sh live-loop --scenario notes        # real model against a simulated desktop
scripts/harness.sh vm up --input-test 3              # typing and save-dialog check through the guest agent
scripts/test-linux.sh                                # portable modules in Docker, without a Mac
```

`docs/STATUS.md` §3 lists the test layers and the development environment variables.

## Release

```sh
APPLE_ID=… APPLE_SPECIFIC_PASSWORD=… APPLE_TEAM_ID=… scripts/release.sh
```

This signs the app with a Developer ID, notarizes and staples it, checks it with Gatekeeper, and writes
`build/release/ChatComputer.zip`. Bump `MARKETING_VERSION` in `project.yml` first.
