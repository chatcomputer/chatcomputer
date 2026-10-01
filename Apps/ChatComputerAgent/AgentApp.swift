import AgentCore
import ApplicationServices
import CoreGraphics
import SwiftUI

/// Runs inside the guest as a LaunchAgent. It is the one app the user grants Accessibility and
/// Screen Recording to, so its signing identity must stay stable across updates (proposal §03).
@main
struct AgentApp: App {
    @State private var state = AgentState()

    var body: some Scene {
        MenuBarExtra("Chat Computer Agent", systemImage: state.symbol) {
            Text(state.statusText)
            Divider()
            Button(state.accessibility ? "Accessibility: allowed" : "Allow Accessibility…") {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            .disabled(state.accessibility)
            Button(state.screenRecording ? "Screen Recording: allowed" : "Allow Screen Recording…") {
                _ = CGRequestScreenCaptureAccess()
            }
            .disabled(state.screenRecording)
        }
    }
}

@MainActor
@Observable
final class AgentState {
    var status: AgentService.Status = .connecting
    var accessibility = AXIsProcessTrusted()
    var screenRecording = CGPreflightScreenCaptureAccess()

    private let service: AgentService

    init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        service = AgentService(driver: NativeDriver(agentVersion: version), agentVersion: version)
        Task { [service] in
            await service.setStatusHandler { status in
                Task { @MainActor in self.status = status }
            }
            await service.run()
        }
        // Permission state is shown in the host's onboarding too; refresh it here for the menu.
        Task {
            while true {
                accessibility = AXIsProcessTrusted()
                screenRecording = CGPreflightScreenCaptureAccess()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    var symbol: String {
        switch status {
        case .connected: accessibility && screenRecording ? "checkmark.circle" : "exclamationmark.circle"
        case .connecting: "circle.dotted"
        case .unpaired, .rejected: "xmark.circle"
        }
    }

    var statusText: String {
        switch status {
        case .connected: "Connected to Chat Computer"
        case .connecting: "Connecting…"
        case .unpaired: "Not paired"
        case .rejected(let reason): "Rejected: \(reason)"
        }
    }
}
