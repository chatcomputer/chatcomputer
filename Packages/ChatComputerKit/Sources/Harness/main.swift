#if os(macOS)
import AppKit

/// Developer harness for automated end-to-end checks that unit tests cannot cover.
///
///     cc-harness live-loop     real model (Anthropic-compatible endpoint) + AgentRunner + FakeDesktop
///     cc-harness vm <command>  VM probes (install, boot, …); needs the virtualization entitlement
///
/// Model settings come from the environment: CC_API_KEY, CC_ENDPOINT, CC_MODEL, CC_DIALECT (claude|compatible).
///
/// Runs inside an AppKit run loop so `vm up --window` can show the VM screen.
let arguments = Array(CommandLine.arguments.dropFirst())
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    let code: Int32
    switch arguments.first {
    case "live-loop":
        code = await LiveLoop.run(arguments: Array(arguments.dropFirst()))
    case "vm":
        code = await VMProbe.run(arguments: Array(arguments.dropFirst()))
    case "find-switch":
        code = SwitchProbe.run(arguments: Array(arguments.dropFirst()))
    default:
        print("usage: cc-harness live-loop [--scenario notes|approval|injection] | vm <command>")
        code = 2
    }
    exit(code)
}
app.run()
#else
print("cc-harness runs on macOS only")
#endif
