import AppKit
import ChatCore
import SwiftUI
import UniformTypeIdentifiers
import VMKit

// MARK: Actions

extension AppModel {
    var sharedFolders: SharedFolders? { vm.map { SharedFolders(root: $0.bundle.sharedRoot) } }

    /// Shares folders from this Mac, read-only. Returns a message about anything that wasn't shared.
    @discardableResult
    func addSharedFolders(_ urls: [URL]) -> String? {
        guard let vm else { return "Finish setting up first." }
        var problems: [String] = []
        var added: [String] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                problems.append("\(url.lastPathComponent) is a file; attach files to a task in the chat instead.")
                continue
            }
            do {
                added.append(try vm.addShare(url).name)
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !added.isEmpty {
            transcript.append(ChatItem(role: .system, text: "Shared \(added.map { "“\($0)”" }.joined(separator: ", ")) with the virtual Mac (read-only)."))
        }
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    func removeSharedFolder(_ share: UserShare) {
        do { try vm?.removeShare(share.id) } catch { errorMessage = error.localizedDescription }
    }

    func setSharedFolderWritable(_ share: UserShare, _ writable: Bool) {
        do { try vm?.setShareReadOnly(share.id, !writable) } catch { errorMessage = error.localizedDescription }
    }

    /// Removes inbox or outbox items older than `date` (everything if nil), keeping the running task's folder.
    func cleanUp(_ folder: URL, olderThan date: Date?) async -> Int {
        var keeping: Set<String> = []
        if isRunningTask, let runner { keeping.insert(SharedFolders.folderName(for: await runner.task)) }
        do {
            return try SharedFolders.removeItems(in: folder, olderThan: date ?? .distantFuture, keeping: keeping)
        } catch {
            errorMessage = error.localizedDescription
            return 0
        }
    }

    /// Asks for files to attach to the next task.
    func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        attach(panel.urls)
    }

    /// Adds files to the next task's attachments; folders are shared instead.
    func attach(_ urls: [URL]) {
        var folders: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { folders.append(url) } else if !pendingAttachments.contains(url) { pendingAttachments.append(url) }
        }
        if !folders.isEmpty, let problem = addSharedFolders(folders) { errorMessage = problem }
    }
}

// MARK: Sheet

struct SharedFoldersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var confirmingWritable: UserShare?
    @State private var confirmingCleanup: CleanupRequest?
    @State private var isDropTargeted = false
    /// Bumped after a cleanup so sizes are measured again.
    @State private var refresh = 0

    struct CleanupRequest: Identifiable {
        let id = UUID()
        let title: String
        let folder: URL
        let olderThan: Date?
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                Section("Built in") {
                    if let folders = model.sharedFolders {
                        BuiltInFolderRow(title: "Inbox", symbol: "tray.and.arrow.down",
                                         detail: "Files you attach to tasks. Read-only in the virtual Mac.",
                                         folder: folders.inbox, guestPath: "\(SharedFolders.guestMountPoint)/inbox", refresh: refresh) { request in
                            confirmingCleanup = request
                        }
                        BuiltInFolderRow(title: "Outbox", symbol: "tray.and.arrow.up",
                                         detail: "Results the virtual Mac saves for you. The app checks them before handing them over.",
                                         folder: folders.outbox, guestPath: "\(SharedFolders.guestMountPoint)/outbox", refresh: refresh) { request in
                            confirmingCleanup = request
                        }
                    }
                }
                Section("Your folders") {
                    let shares = model.vm?.shares ?? []
                    if shares.isEmpty {
                        Text("Drag a folder here, or click Add Folder. Shared folders are read-only in the virtual Mac unless you allow changes.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                    ForEach(shares) { share in
                        ShareRow(share: share, onWritable: { writable in
                            if writable { confirmingWritable = share } else { model.setSharedFolderWritable(share, false) }
                        }, onRemove: { model.removeSharedFolder(share) })
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3).padding(6)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                message = model.addSharedFolders(urls)
                return true
            } isTargeted: { isDropTargeted = $0 }
            Divider()
            footer
        }
        .frame(width: 600, height: 620)
        .alert("Allow changes to “\(confirmingWritable?.name ?? "")”?", isPresented: present($confirmingWritable), presenting: confirmingWritable) { share in
            Button("Allow Changes", role: .destructive) { model.setSharedFolderWritable(share, true) }
            Button("Cancel", role: .cancel) {}
        } message: { share in
            Text("The AI working in the virtual Mac could then change or delete the files in \(share.path). Snapshots of the virtual Mac don't include this folder, so they can't undo that.")
        }
        .alert(confirmingCleanup?.title ?? "", isPresented: present($confirmingCleanup), presenting: confirmingCleanup) { request in
            Button("Remove", role: .destructive) {
                Task {
                    let removed = await model.cleanUp(request.folder, olderThan: request.olderThan)
                    message = removed == 1 ? "Removed 1 item." : "Removed \(removed) items."
                    refresh += 1
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Removed files are deleted from this Mac. The running task's folder is kept.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shared Folders").font(.title2.bold())
                    Text("Folders on this Mac that the virtual Mac can open, under \(SharedFolders.guestMountPoint). Changes apply right away, also while it runs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button {
                    chooseFolders()
                } label: {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.vm == nil)
            }
            if let message {
                Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Text("Only you and coding agents you connect can change shared folders; the AI in the virtual Mac can't.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Share"
        guard panel.runModal() == .OK else { return }
        message = model.addSharedFolders(panel.urls)
    }

    private func present<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

private struct BuiltInFolderRow: View {
    let title: String
    let symbol: String
    let detail: String
    let folder: URL
    let guestPath: String
    let refresh: Int
    let onCleanup: (SharedFoldersSheet.CleanupRequest) -> Void
    @State private var usage: (bytes: Int64, files: Int)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                GuestPathLabel(path: guestPath)
                if let usage {
                    Text("\(usage.files) \(usage.files == 1 ? "file" : "files") · \(ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                .controlSize(.small)
            Menu("Clean Up") {
                Button("Remove Items Older Than 7 Days…") {
                    onCleanup(.init(title: "Remove \(title.lowercased()) items older than 7 days?", folder: folder,
                                    olderThan: Date().addingTimeInterval(-7 * 86400)))
                }
                Button("Remove Everything…") {
                    onCleanup(.init(title: "Remove everything in the \(title.lowercased())?", folder: folder, olderThan: nil))
                }
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .task(id: refresh) {
            let folder = folder
            usage = await Task.detached { SharedFolders.usage(of: folder) }.value
        }
    }
}

private struct ShareRow: View {
    let share: UserShare
    let onWritable: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: share.exists ? "folder.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(share.exists ? Color.accentColor : .orange)
                .frame(width: 30)
                .help(share.exists ? "" : "This folder was moved or deleted, so the virtual Mac can't see it.")
            VStack(alignment: .leading, spacing: 3) {
                Text(share.name).font(.headline)
                Text((share.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                GuestPathLabel(path: share.guestPath)
            }
            Spacer()
            Toggle("Allow changes", isOn: Binding(get: { !share.readOnly }, set: onWritable))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(share.readOnly ? "Read-only in the virtual Mac" : "The virtual Mac can change and delete files here")
            Button("Stop Sharing", systemImage: "minus.circle", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Stop sharing. The folder and its files stay on your Mac.")
        }
        .padding(.vertical, 4)
    }
}

/// The folder's path inside the virtual Mac, with a copy button.
private struct GuestPathLabel: View {
    let path: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(2)); copied = false }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .help("Copy the path in the virtual Mac")
        }
    }
}
