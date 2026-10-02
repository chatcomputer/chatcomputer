import AppKit
import HostControl
import SwiftUI
import VMKit

/// What the guest screen shows while a snapshot is taken or restored: the VM stops and starts again
/// underneath, so the last frame stays on screen, dimmed, instead of the "off" placeholder.
struct SnapshotActivity {
    let title: String
    let frozenScreen: CGImage?
}

// MARK: Actions

extension AppModel {
    /// Why snapshots can't be taken or restored right now, or nil if they can.
    var snapshotsUnavailableReason: String? {
        guard isReady, let vm else { return "Finish setting up first." }
        if snapshotActivity != nil || vm.isWorkingOnSnapshots { return "A snapshot is in progress." }
        guard phase == .ready || phase.isTerminal else { return "Finish or cancel the current task first." }
        switch vm.state {
        case .running, .stopped, .error: return nil
        case .starting: return "Wait until the virtual Mac has started."
        case .paused, .saving: return "Wait until the virtual Mac is running."
        }
    }

    var canManageSnapshots: Bool { snapshotsUnavailableReason == nil }

    /// Saves the virtual Mac as it is now. Taken while it runs, the snapshot includes memory, so restoring it
    /// brings back the open apps and windows.
    func takeSnapshot() async {
        guard canManageSnapshots, let vm else { return }
        let name = "Snapshot " + Date().formatted(.dateTime.month(.abbreviated).day().hour().minute())
        let screen = vm.state == .running ? captureGuestScreen() : nil
        snapshotActivity = SnapshotActivity(title: "Saving a snapshot…", frozenScreen: screen)
        defer { snapshotActivity = nil }
        let started = Date()
        do {
            let snapshot = try await vm.takeSnapshot(name: name, thumbnail: screen.flatMap(Self.thumbnail))
            let seconds = Int(Date().timeIntervalSince(started).rounded())
            transcript.append(ChatItem(role: .system, text: "Saved snapshot “\(snapshot.name)” in \(seconds) s."))
        } catch {
            errorMessage = "The snapshot could not be saved. \(error.localizedDescription)"
        }
    }

    /// Returns the virtual Mac to `snapshot`, first saving the current state as a snapshot if asked.
    func restoreSnapshot(_ snapshot: VMSnapshot, savingCurrent: Bool) async {
        guard canManageSnapshots, let vm else { return }
        let screen = vm.state == .running ? captureGuestScreen() : nil
        snapshotActivity = SnapshotActivity(title: "Restoring “\(snapshot.name)”…", frozenScreen: screen)
        defer { snapshotActivity = nil }
        do {
            try await vm.restoreSnapshot(snapshot.id, savingCurrentAs: savingCurrent ? "Before restoring “\(snapshot.name)”" : nil,
                                         thumbnail: screen.flatMap(Self.thumbnail))
            if vm.state == .stopped { await vm.start() }
            let detail = snapshot.includesMemory ? "" : " The virtual Mac is starting up from that disk."
            transcript.append(ChatItem(role: .system, text: "Restored “\(snapshot.name)”.\(detail)"))
        } catch {
            errorMessage = "The snapshot could not be restored. \(error.localizedDescription)"
        }
    }

    func renameSnapshot(_ snapshot: VMSnapshot, to name: String) {
        do { try vm?.renameSnapshot(snapshot.id, to: name) } catch { errorMessage = error.localizedDescription }
    }

    func setSnapshotProtected(_ snapshot: VMSnapshot, _ isProtected: Bool) {
        do { try vm?.setSnapshotProtected(snapshot.id, isProtected) } catch { errorMessage = error.localizedDescription }
    }

    func deleteSnapshot(_ snapshot: VMSnapshot) {
        do { try vm?.deleteSnapshot(snapshot.id) } catch { errorMessage = error.localizedDescription }
    }

    private func captureGuestScreen() -> CGImage? {
        guard let guestView, let spec = vm?.spec else { return nil }
        return HostDisplay(view: guestView, guestSize: CGSize(width: spec.displayWidth / 2, height: spec.displayHeight / 2)).capture()
    }

    /// A small JPEG of the guest screen for the snapshot list.
    private static func thumbnail(_ image: CGImage) -> Data? {
        let width = 480
        let height = max(1, image.height * width / max(image.width, 1))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

// MARK: Guest screen overlay

struct SnapshotActivityOverlay: View {
    let activity: SnapshotActivity

    var body: some View {
        ZStack {
            Color.black
            if let screen = activity.frozenScreen {
                Image(decorative: screen, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .saturation(0.3)
                    .opacity(0.45)
            }
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(activity.title).font(.callout.weight(.medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .capsule)
        }
        .transition(.opacity)
    }
}

// MARK: Snapshot list

struct SnapshotsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var restoring: VMSnapshot?
    @State private var deleting: VMSnapshot?
    @State private var renaming: VMSnapshot?
    @State private var newName = ""

    private var snapshots: [VMSnapshot] { (model.vm?.snapshots ?? []).reversed() }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if snapshots.isEmpty {
                ContentUnavailableView("No Snapshots Yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Take a snapshot before trying something risky. You can come back to it at any time."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                        SnapshotRow(snapshot: snapshot, isCurrent: snapshot.id == model.vm?.currentSnapshotID,
                                    branchesFrom: branchParent(of: snapshot, olderNeighbor: snapshots[safe: index + 1]),
                                    thumbnail: model.vm?.snapshotStore.thumbnailURL(snapshot.id),
                                    canRestore: model.canManageSnapshots) { restoring = snapshot }
                            .contextMenu { menu(for: snapshot) }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
        .frame(width: 580, height: 620)
        .alert(restoreTitle, isPresented: present($restoring), presenting: restoring) { snapshot in
            Button("Save Current State and Restore") { restore(snapshot, savingCurrent: true) }
                .keyboardShortcut(.defaultAction)
            Button("Restore Without Saving", role: .destructive) { restore(snapshot, savingCurrent: false) }
            Button("Cancel", role: .cancel) {}
        } message: { snapshot in
            Text(restoreMessage(snapshot))
        }
        .alert("Delete “\(deleting?.name ?? "")”?", isPresented: present($deleting), presenting: deleting) { snapshot in
            Button("Delete", role: .destructive) { model.deleteSnapshot(snapshot) }
            Button("Cancel", role: .cancel) {}
        } message: { snapshot in
            let freed = snapshot.memoryBytes.map { " It frees about \(Self.bytes($0)) of saved memory." } ?? ""
            Text("This can't be undone.\(freed)")
        }
        .alert("Rename Snapshot", isPresented: present($renaming), presenting: renaming) { snapshot in
            TextField("Name", text: $newName)
            Button("Rename") { model.renameSnapshot(snapshot, to: newName) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Snapshots").font(.title2.bold())
                    Text("A snapshot saves the whole virtual Mac. Taken while it runs, it keeps the open apps and windows too, and restoring it picks up exactly there.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button {
                    Task { await model.takeSnapshot() }
                } label: {
                    Label("Take Snapshot", systemImage: "camera")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canManageSnapshots)
                .help(model.snapshotsUnavailableReason ?? "Save the virtual Mac as it is now (⌥⌘S)")
            }
            if let activity = model.snapshotActivity {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activity.title)
                }
                .font(.callout)
            } else if let reason = model.snapshotsUnavailableReason {
                Label(reason, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                Text("Snapshots share unchanged data with the virtual disk, so they only use space as the Mac changes.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func menu(for snapshot: VMSnapshot) -> some View {
        Button("Restore…") { restoring = snapshot }
            .disabled(!model.canManageSnapshots)
        Button("Rename…") {
            newName = snapshot.name
            renaming = snapshot
        }
        Button(snapshot.isProtected ? "Unprotect" : "Protect") { model.setSnapshotProtected(snapshot, !snapshot.isProtected) }
        Divider()
        Button("Delete…", role: .destructive) { deleting = snapshot }
            .disabled(snapshot.isProtected || model.snapshotActivity != nil)
    }

    private var summary: String {
        let memory = snapshots.compactMap(\.memoryBytes).reduce(0, +)
        let free = model.vm.map { SnapshotStore.availableCapacity(for: $0.bundle.url) } ?? 0
        let count = snapshots.count == 1 ? "1 snapshot" : "\(snapshots.count) snapshots"
        return "\(count) · \(Self.bytes(memory)) of saved memory · \(Self.bytes(free)) free on this Mac"
    }

    private var restoreTitle: String {
        guard let restoring else { return "" }
        return restoring.kind == .initial ? "Reset the virtual Mac?" : "Restore “\(restoring.name)”?"
    }

    private func restoreMessage(_ snapshot: VMSnapshot) -> String {
        let when = snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)
        let what = snapshot.kind == .initial
            ? "The virtual Mac goes back to how it was right after setup. It starts up from that disk, which takes about a minute."
            : snapshot.includesMemory
                ? "The virtual Mac goes back to how it was on \(when), with the apps and windows that were open."
                : "The virtual Mac goes back to its disk from \(when) and starts up, which takes about a minute."
        return what + "\n\nSave the current state first if you may want to come back to it."
    }

    private func restore(_ snapshot: VMSnapshot, savingCurrent: Bool) {
        dismiss()
        Task { await model.restoreSnapshot(snapshot, savingCurrent: savingCurrent) }
    }

    /// The parent, when the snapshot doesn't simply follow the one listed below it (a new branch after a restore).
    private func branchParent(of snapshot: VMSnapshot, olderNeighbor: VMSnapshot?) -> String? {
        guard let parentID = snapshot.parentID, parentID != olderNeighbor?.id else { return nil }
        return snapshots.first { $0.id == parentID }?.name
    }

    private func present<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

private struct SnapshotRow: View {
    let snapshot: VMSnapshot
    let isCurrent: Bool
    let branchesFrom: String?
    let thumbnail: URL?
    let canRestore: Bool
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            preview
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(snapshot.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    if snapshot.isProtected {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Protected from deletion")
                    }
                    if isCurrent {
                        Text("Current")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18), in: .capsule)
                            .foregroundStyle(Color.accentColor)
                            .help("Your virtual Mac continues from this snapshot")
                    }
                }
                Text(snapshot.createdAt.formatted(.relative(presentation: .named)) + " · "
                     + snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Group {
                    if snapshot.kind == .initial {
                        Label("Right after setup · restore it to reset the computer", systemImage: "sparkles")
                    } else if let memory = snapshot.memoryBytes {
                        Label("Open apps and windows · \(SnapshotsSheet.bytes(memory))", systemImage: "memorychip")
                    } else {
                        Label("Disk only · starts up when restored", systemImage: "internaldrive")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let branchesFrom {
                    Label("Branches from “\(branchesFrom)”", systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Button("Restore…", action: onRestore)
                .controlSize(.small)
                .disabled(!canRestore)
        }
        .padding(.vertical, 6)
    }

    private var preview: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.42), Color(red: 0.08, green: 0.09, blue: 0.24)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if snapshot.hasThumbnail, let thumbnail, let image = NSImage(contentsOf: thumbnail) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: snapshot.kind == .initial ? "sparkles" : "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(width: 112, height: 70)
        .clipShape(.rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
