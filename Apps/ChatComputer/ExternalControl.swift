import BridgeProtocol
import ChatCore
import ComputerControl
import GuestBridge
import Foundation
import ModelProxy
import VMKit

/// Runs commands from coding agents outside the app (the `chatcomputer` tool and its MCP server).
///
/// They follow the same rules as the built-in agent: input needs the lease, the user takes it back by
/// clicking the screen (and must hand it back before the agent can continue), and only one of the user,
/// the built-in agent and an external agent controls the virtual Mac at a time. Commands run one after
/// another, in the order they arrive.
@MainActor
final class ExternalControl {
    private unowned let model: AppModel
    private var server: ControlServer?
    private var token: UUID?
    private var lastActivity = Date()
    private var tail: Task<Void, Never>?
    private var idleWatch: Task<Void, Never>?

    /// An external agent that stops sending commands gives control back after this long.
    static let idleLimit: TimeInterval = 120

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        let server = ControlServer { [weak self] request in
            guard let self else { return .error("Chat Computer is quitting.") }
            return await self.enqueue(request)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            model.transcript.append(ChatItem(role: .system, text: "Coding agents can't connect: \(error)"))
        }
    }

    /// Stops accepting commands (the app is quitting) and removes the socket.
    func stop() {
        server?.stop()
        server = nil
    }

    private func enqueue(_ request: ControlRequest) async -> ControlResponse {
        let previous = tail
        let task = Task { @MainActor in
            _ = await previous?.value
            return await self.execute(request)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    // MARK: Commands

    private func execute(_ request: ControlRequest) async -> ControlResponse {
        let client = request.client
        do {
            let command = try ControlCommand(name: request.command, arguments: request.arguments)
            lastActivity = Date()
            if let action = command.action { return try await perform(action, command: command, client: client) }
            switch command {
            case .status:
                return ControlResponse(text: await status(for: client))
            case .screenshot(let region):
                let bridge = try await readyGuest()
                guard case .screenshot(let shot) = try await bridge.send(envelope(.screenshot(region: region), deadline: 20)) else {
                    throw Failure("The virtual Mac did not return a screenshot.")
                }
                let what = region == nil
                    ? "Screenshot \(shot.width)×\(shot.height). Click coordinates are pixels of this image."
                    : "Zoomed screenshot (\(shot.width)×\(shot.height)). Use coordinates from a full screenshot to click."
                return ControlResponse(text: what, image: shot.imageData, imageType: shot.mediaType)
            case .wait(let seconds):
                try await Task.sleep(for: .seconds(seconds))
                return ControlResponse(text: "Waited \(seconds.formatted()) s.")
            case .release:
                guard token != nil else { return ControlResponse(text: "You did not have control.") }
                await release(note: "\(client) released control of the virtual Mac.")
                return ControlResponse(text: "Released control of the virtual Mac.")
            case .snapshotList:
                return ControlResponse(text: snapshotList())
            case .snapshotTake(let name):
                await release(note: nil)
                let snapshot = try await model.saveSnapshot(name: name, by: client)
                _ = try await readyGuest()
                return ControlResponse(text: "Saved snapshot “\(snapshot.name)” (\(snapshot.id.uuidString.prefix(8)))\(snapshot.includesMemory ? " with open apps and windows" : "").")
            case .snapshotRestore(let wanted, let saveCurrent):
                let snapshot = try findSnapshot(wanted)
                await release(note: nil)
                try await model.returnTo(snapshot, savingCurrent: saveCurrent, by: client)
                _ = try await readyGuest()
                let saved = saveCurrent ? " The previous state was saved as “Before restoring “\(snapshot.name)””." : ""
                return ControlResponse(text: "Restored “\(snapshot.name)”. Take a screenshot before acting.\(saved)")
            case .putFile(let path):
                return ControlResponse(text: try putFile(path))
            case .outbox:
                return ControlResponse(text: try outboxList())
            case .shareList:
                return ControlResponse(text: shareList())
            case .shareAdd(let path, let writable):
                guard let vm = model.vm else { throw Failure("Chat Computer is not set up yet.") }
                let share = try vm.addShare(URL(fileURLWithPath: path), readOnly: !writable)
                let mode = writable ? "read & write" : "read-only"
                model.transcript.append(ChatItem(role: .system, text: "\(client) shared “\(share.name)” with the virtual Mac (\(mode))."))
                return ControlResponse(text: "Shared \(share.path) as \(share.guestPath) (\(mode)).")
            case .shareRemove(let name):
                guard let vm = model.vm else { throw Failure("Chat Computer is not set up yet.") }
                guard let share = vm.shares.first(where: { $0.name.lowercased() == name.lowercased() }) else {
                    throw Failure("No shared folder named “\(name)”. Run `share list`.")
                }
                try vm.removeShare(share.id)
                model.transcript.append(ChatItem(role: .system, text: "\(client) stopped sharing “\(share.name)”."))
                return ControlResponse(text: "Stopped sharing “\(share.name)”; the folder stays on this Mac.")
            default:
                throw Failure("Unsupported command.")
            }
        } catch let failure as Failure {
            return .error(failure.message)
        } catch let error as ControlError {
            return .error(error.description)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func perform(_ action: ComputerAction, command: ControlCommand, client: String) async throws -> ControlResponse {
        let bridge = try await readyGuest()
        let token = try await acquire(for: client, bridge: bridge)
        var result = try await bridge.send(envelope(.perform(action), lease: token, deadline: 30))
        if case .failure(let error) = result, error.category == .leaseRejected {
            // The guest agent restarted (or the Mac was restored) and forgot the lease: announce it again once.
            _ = try await bridge.send(envelope(.setLease(token)))
            result = try await bridge.send(envelope(.perform(action), lease: token, deadline: 30))
        }
        lastActivity = Date()
        model.transcript.append(ChatItem(role: .action, text: "\(client): \(Self.describe(command))"))
        switch result {
        case .ok: return ControlResponse(text: "Done: \(Self.describe(command)).")
        case .cursor(let point): return ControlResponse(text: "Pointer at \(point.x), \(point.y).")
        case .failure(let error): throw Failure("The virtual Mac refused: \(error.message)")
        default: return ControlResponse(text: "Done.")
        }
    }

    // MARK: Control

    /// Takes the input lease for `client`, unless someone else is using the virtual Mac.
    private func acquire(for client: String, bridge: any GuestChannel) async throws -> UUID {
        if model.isRunningTask {
            throw Failure("Chat Computer's own agent is working on a task. Wait for it to finish, or ask the user to cancel it.")
        }
        if let blocked = model.externalBlockedBy {
            throw Failure("The user took control of the virtual Mac from \(blocked). Wait until they hand it back (check with `status`), then take a fresh screenshot.")
        }
        if let token, await model.lease.isValid(token) {
            if model.externalHolder == client { return token }
            throw Failure("\(model.externalHolder ?? "Another agent") is controlling the virtual Mac. Wait until it releases control.")
        }
        // A user hold left over from a finished task or the Take Over menu: nobody is waiting on it.
        if case .user = await model.lease.holder { await model.lease.releaseFromUser() }
        let token = try await model.lease.acquireForAgent()
        _ = try await bridge.send(envelope(.setLease(token)))
        self.token = token
        model.externalHolder = client
        model.transcript.append(ChatItem(role: .system, text: "\(client) is controlling the virtual Mac. Click the screen to take over."))
        watchIdle()
        return token
    }

    /// Gives up the lease, if an external agent holds it. `note` goes to the chat.
    func release(note: String?) async {
        guard token != nil else { return }
        token = nil
        idleWatch?.cancel()
        if case .agent = await model.lease.holder { await model.lease.release() }
        model.externalHolder = nil
        if let bridge = model.bridge { _ = try? await bridge.send(envelope(.setLease(nil))) }
        if let note { model.transcript.append(ChatItem(role: .system, text: note)) }
    }

    /// The user clicked the screen (or chose Take Over) while an external agent had control.
    func userTookOver(reason: String) async {
        guard let holder = model.externalHolder else { return }
        token = nil
        idleWatch?.cancel()
        await model.lease.grantToUser()
        model.externalHolder = nil
        model.externalBlockedBy = holder
        if let bridge = model.bridge { _ = try? await bridge.send(envelope(.setLease(nil))) }
        model.transcript.append(ChatItem(role: .system, text: "You took over from \(holder): \(reason). Hand back control to let it continue."))
    }

    func handBack() async {
        guard let blocked = model.externalBlockedBy else { return }
        await model.lease.releaseFromUser()
        model.externalBlockedBy = nil
        model.transcript.append(ChatItem(role: .system, text: "You handed control back. \(blocked) can continue."))
    }

    private func watchIdle() {
        idleWatch?.cancel()
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.token != nil else { return }
                if Date().timeIntervalSince(self.lastActivity) > Self.idleLimit {
                    let holder = self.model.externalHolder ?? "The coding agent"
                    await self.release(note: "\(holder) was idle for 2 minutes, so its control of the virtual Mac ended.")
                    return
                }
            }
        }
    }

    // MARK: Guest

    /// Waits until the virtual Mac is running with its agent connected and the desktop ready, starting it if needed.
    private func readyGuest() async throws -> any GuestChannel {
        guard model.isReady, let vm = model.vm, let bridge = model.bridge else {
            throw Failure("Chat Computer is not set up yet. Finish the setup in its window first.")
        }
        // A starting Mac gets time to boot; a running one that isn't ready gets a short wait, so one stuck
        // command doesn't hold up every command queued behind it.
        var deadline = Date().addingTimeInterval(vm.state == .running ? 20 : 150)
        var started = false
        var reason = "it is \(vm.state)"
        while Date() < deadline {
            if model.snapshotActivity != nil || vm.isWorkingOnSnapshots {
                reason = "a snapshot is in progress"
            } else {
                switch vm.state {
                case .stopped, .error:
                    if !started {
                        started = true
                        deadline = Date().addingTimeInterval(150)
                        await model.bootVM()
                    }
                case .running:
                    let readiness = await guestReadiness(bridge)
                    if readiness == nil { return bridge }
                    reason = readiness ?? reason
                default:
                    reason = "it is \(vm.state)"
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw Failure("The virtual Mac is not ready: \(reason). Check the Chat Computer window.")
    }

    /// nil when the guest agent answers and the desktop is usable; otherwise what's missing.
    private func guestReadiness(_ bridge: BridgeServer) async -> String? {
        guard await bridge.isConnected else { return "the agent in the virtual Mac is not connected (it may be restarting)" }
        guard case .health(let report)? = try? await bridge.send(envelope(.health, deadline: 5)) else {
            return "the agent in the virtual Mac is connected but not answering"
        }
        if report.isDesktopReady { return nil }
        if !report.hasAquaSession { return "nobody is logged in to the virtual Mac's desktop" }
        if report.screenLocked { return "the virtual Mac's screen is locked" }
        return "the agent in the virtual Mac lacks Accessibility or Screen Recording permission"
    }

    private func envelope(_ command: GuestCommand, lease: UUID? = nil, deadline: TimeInterval = 10) -> CommandEnvelope {
        CommandEnvelope(vmID: model.vm?.spec.id ?? UUID(), jobID: nil, leaseToken: lease, observationVersion: nil,
                        deadline: Date().addingTimeInterval(deadline), command: command)
    }

    // MARK: Reports

    private func status(for client: String) async -> String {
        guard model.isReady, let vm = model.vm else { return "Chat Computer is not set up yet. Finish the setup in its window first." }
        var desktop = ""
        if vm.state == .running, let bridge = model.bridge {
            desktop = await guestReadiness(bridge).map { ", not ready: \($0)" } ?? ", desktop ready"
        }
        let state = switch vm.state {
        case .running: "running"
        case .starting: "starting"
        case .stopped: "stopped (any command starts it)"
        case .paused: "paused"
        case .saving: "saving"
        case .error(let message): "error: \(message)"
        }
        let control: String = if model.isRunningTask {
            "Chat Computer's own agent (working on a task)"
        } else if let blocked = model.externalBlockedBy {
            "the user, who took over from \(blocked); wait until they hand it back"
        } else if let holder = model.externalHolder {
            holder == client ? "you (\(holder))" : holder
        } else {
            "free; your first input command takes it"
        }
        let current = vm.snapshots.first { $0.id == vm.currentSnapshotID }.map { ", current “\($0.name)”" } ?? ""
        return """
            Virtual Mac: \(state)\(desktop)
            Screen: \(vm.spec.displayWidth / 2)×\(vm.spec.displayHeight / 2) (full screenshots use these coordinates)
            Control: \(control)
            Snapshots: \(vm.snapshots.count)\(current)
            Shared folder in the virtual Mac: \(SharedFolders.guestMountPoint) (inbox read-only, outbox writable)
            """
    }

    private func snapshotList() -> String {
        guard let vm = model.vm, !vm.snapshots.isEmpty else { return "No snapshots yet." }
        return vm.snapshots.reversed().map { snapshot in
            var flags: [String] = []
            if snapshot.id == vm.currentSnapshotID { flags.append("current") }
            if snapshot.isProtected { flags.append("protected") }
            flags.append(snapshot.includesMemory ? "open apps and windows" : "disk only")
            return "\(snapshot.id.uuidString.prefix(8))  “\(snapshot.name)”  \(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))  (\(flags.joined(separator: ", ")))"
        }.joined(separator: "\n")
    }

    private func shareList() -> String {
        guard let vm = model.vm else { return "Chat Computer is not set up yet." }
        let builtIn = """
            inbox   \(SharedFolders.guestMountPoint)/inbox   (read-only; files from `put` are in inbox/external)
            outbox  \(SharedFolders.guestMountPoint)/outbox  (writable; results for this Mac)
            """
        guard !vm.shares.isEmpty else { return builtIn + "\nNo folders from this Mac are shared. Add one with `share add`." }
        let lines = vm.shares.map { share in
            "\(share.name)  \(share.guestPath)  ← \(share.path)  (\(share.readOnly ? "read-only" : "read & write")\(share.exists ? "" : ", missing on this Mac"))"
        }
        return builtIn + "\n" + lines.joined(separator: "\n")
    }

    private func findSnapshot(_ wanted: String) throws -> VMSnapshot {
        let snapshots = model.vm?.snapshots ?? []
        let key = wanted.lowercased()
        if let match = snapshots.first(where: { $0.id.uuidString.lowercased() == key || $0.name.lowercased() == key }) { return match }
        let prefixed = snapshots.filter { $0.id.uuidString.lowercased().hasPrefix(key) }
        if prefixed.count == 1 { return prefixed[0] }
        throw Failure("No snapshot named or numbered “\(wanted)”. Run `snapshot list`.")
    }

    private func putFile(_ path: String) throws -> String {
        guard let vm = model.vm else { throw Failure("Chat Computer is not set up yet.") }
        let source = URL(fileURLWithPath: path)
        let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw Failure("\(path) is not a file.") }
        guard (values?.fileSize ?? 0) <= 2 << 30 else { throw Failure("\(path) is larger than 2 GB.") }
        let folder = SharedFolders(root: vm.bundle.sharedRoot).inbox.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return "Copied. In the virtual Mac it is \(SharedFolders.guestMountPoint)/inbox/external/\(source.lastPathComponent) (read-only)."
    }

    private func outboxList() throws -> String {
        guard let vm = model.vm else { throw Failure("Chat Computer is not set up yet.") }
        let outbox = SharedFolders(root: vm.bundle.sharedRoot).outbox
        let validator = ExportValidator()
        var files: [(url: URL, relative: String, bytes: Int, modified: Date)] = []
        let base = outbox.standardizedFileURL.resolvingSymlinksInPath().path
        for case let url as URL in FileManager.default.enumerator(at: outbox, includingPropertiesForKeys: [.contentModificationDateKey]) ?? .init() {
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(base + "/") else { continue }
            let relative = String(full.dropFirst(base.count + 1))
            // Skips folders, symlinks and anything else the validator rejects: the guest controls this folder.
            guard let checked = try? validator.validate(relativePath: relative, in: outbox) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((checked.url, relative, checked.bytes, modified))
        }
        guard !files.isEmpty else { return "The outbox is empty. Save files to \(SharedFolders.guestMountPoint)/outbox in the virtual Mac." }
        let shown = files.sorted { $0.modified > $1.modified }.prefix(30)
        let lines = shown.map { file in
            "\(file.url.path)  (\(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file)), \(file.modified.formatted(date: .omitted, time: .shortened)))"
        }
        let more = files.count > shown.count ? "\n… and \(files.count - shown.count) older files" : ""
        return "Newest first, paths on this Mac:\n" + lines.joined(separator: "\n") + more
    }

    static func describe(_ command: ControlCommand) -> String {
        switch command {
        case .click(let point, let button, let count, let modifiers):
            let kind = count == 2 ? "double-click" : count == 3 ? "triple-click" : button == .left ? "click" : "\(button.rawValue)-click"
            return "\(kind) \(point.x), \(point.y)" + (modifiers.isEmpty ? "" : " with \(modifiers.joined(separator: "+"))")
        case .move(let point): return "move to \(point.x), \(point.y)"
        case .drag(let from, let to): return "drag \(from.x), \(from.y) → \(to.x), \(to.y)"
        case .scroll(let point, let direction, let amount): return "scroll \(direction.rawValue) \(amount) at \(point.x), \(point.y)"
        case .type(let text): return "type “\(text.count > 40 ? text.prefix(40) + "…" : text)”"
        case .key(let combo, let count): return "press \(combo)" + (count > 1 ? " ×\(count)" : "")
        default: return "\(command)"
        }
    }

    private struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
