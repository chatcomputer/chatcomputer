import AppKit
import ChatCore
import ComputerControl
import Foundation
import SwiftUI

/// One executable, two faces: `chatcomputer <command>` (or the app binary with a command) is the
/// command line tool coding agents use; anything else opens the app.
@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if ControlCommandLine.isCommandLine(arguments) {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            Task { exit(await ControlCommandLine.run(arguments, version: version)) }
            dispatchMain()
        }
        // One copy at a time: a second one (another build, or a second launch from a different path)
        // brings the running copy forward and quits, so it never competes for the virtual Mac or the socket.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let running = others.first {
            running.activate()
            exit(0)
        }
        ChatComputerApp.main()
    }
}

struct ChatComputerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }

    // The main window is AppKit (`MainWindowController`, made by the app delegate); SwiftUI keeps Settings and the
    // menu commands, which act on the whole app.
    var body: some Scene {
        Settings {
            SettingsView().environment(model)
        }
        .commands {
            CommandGroup(before: .toolbar) {
                Button(model.isPanelCollapsed ? "Show Chat" : "Hide Chat") { model.setPanelCollapsed(!model.isPanelCollapsed) }
                    .keyboardShortcut("s", modifiers: [.control, .command])
                    .disabled(!model.isReady)
                Divider()
            }
            CommandMenu("Machine") {
                Button("Take Snapshot") { Task { await model.takeSnapshot() } }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(!model.canManageSnapshots)
                Button("Snapshots…") { model.showingSnapshots = true }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.isReady)
                Button("Shared Folders…") { model.showingSharedFolders = true }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(!model.isReady)
            }
            CommandMenu("Agent") {
                // Emergency stop is handled by the host, independent of guest or model (proposal §04).
                // The input shield holds focus while the agent runs, so the VM view can't swallow it.
                Button("Pause Agent") { model.pause() }
                    .keyboardShortcut(".", modifiers: .command)
                Button("Take Over") { model.takeOver() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Cancel Task") { model.cancel() }
                Divider()
                Button("Copy Conversation") { model.copyConversation() }
                Button("Clear Chat") { model.clearChat() }
                    .keyboardShortcut("k", modifiers: [.command])
                    .disabled(model.isRunningTask)
            }
            CommandGroup(after: .help) {
                Button("Export Diagnostics…") { Task { await Diagnostics.export(model) } }
            }
        }
    }
}

/// Quitting saves the virtual Mac instead of cutting its power: the next launch resumes it as it was.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var isQuitting = false
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill` (and launchd at shutdown) sends SIGTERM; quit the normal way so the VM is saved too.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // Not `NSApp.terminate` right here: this handler is a block on the main queue, and quitting waits for
        // main-actor work (saving the VM) that can't run until the block returns. Start it from the run loop.
        source.setEventHandler { RunLoop.main.perform { NSApp.terminate(nil) } }
        source.resume()
        terminationSignal = source
        showMainWindow()
    }

    private var mainWindow: MainWindowController?

    func showMainWindow() {
        if mainWindow == nil { mainWindow = MainWindowController(model: model) }
        mainWindow?.showWindow(nil)
        mainWindow?.window?.makeKeyAndOrderFront(nil)
    }

    /// Clicking the Dock icon brings the window back (it is never closed without quitting, but may be minimised).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// One window, one virtual Mac: closing the window quits (and so saves the VM).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateLater }
        isQuitting = true
        Task {
            await model.prepareToQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

