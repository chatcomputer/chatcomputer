import ChatCore
import SwiftUI

struct ChatPanel: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var showActions = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleItems) { item in
                            ChatRow(item: item) { model.export($0) }.id(item.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.transcript.count) {
                    if let last = model.transcript.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            footer
            if !model.pendingAttachments.isEmpty { attachments }
            HStack(alignment: .bottom) {
                Button("Attach Files", systemImage: "paperclip") { model.chooseAttachments() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Attach files to the next task; they go into its inbox, read-only in the virtual Mac")
                // Chat input always stays on the host; it never reaches the guest.
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .onSubmit(send)
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        // Files dropped on the chat are attached to the next task; folders are shared.
        .dropDestination(for: URL.self) { urls, _ in
            model.attach(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3).padding(4)
                    .overlay(Text("Drop files to attach them, or folders to share them").font(.callout.weight(.medium))
                        .padding(8).background(.regularMaterial, in: .capsule))
            }
        }
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.pendingAttachments, id: \.self) { url in
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                        Text(url.lastPathComponent).lineLimit(1)
                        Button("Remove", systemImage: "xmark.circle.fill") { model.pendingAttachments.removeAll { $0 == url } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.07), in: .capsule)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 8)
    }

    private var visibleItems: [ChatItem] {
        showActions ? model.transcript : model.transcript.filter { $0.role != .action }
    }

    private var placeholder: String {
        if case .waitingForUser = model.phase { return "Reply to the agent…" }
        return "What should your computer do?"
    }

    private var footer: some View {
        HStack {
            Text(phaseText).font(.caption)
            Spacer()
            Button("Shared Folders", systemImage: "folder") { model.showingSharedFolders = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Shared folders: folders from this Mac, the inbox and the outbox (⌥⌘F)")
            Button("Snapshots", systemImage: "clock.arrow.circlepath") { model.showingSnapshots = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Snapshots: save the virtual Mac and return to it later (⇧⌘S)")
            Toggle("Steps", isOn: $showActions).toggleStyle(.switch).controlSize(.mini).font(.caption)
            Text("\(model.tokens.input + model.tokens.output) tokens").font(.caption).monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private var phaseText: String {
        switch model.phase {
        case .ready: "Ready"
        case .running: "Working"
        case .waitingForUser(let reason): "Waiting for you: \(reason)"
        case .waitingExternal(let reason, _): "Waiting: \(reason)"
        case .paused: "Paused"
        case .takenOver: "You have control"
        case .failed: "Stopped"
        case .completed: "Done"
        case .cancelled: "Cancelled"
        }
    }

    private func send() {
        model.submit(draft)
        draft = ""
    }
}

private struct ChatRow: View {
    let item: ChatItem
    let onExport: (URL) -> Void

    var body: some View {
        VStack(alignment: item.role == .user ? .trailing : .leading, spacing: 6) {
            Text(item.text)
                .textSelection(.enabled)
                .font(item.role == .action ? .caption.monospaced() : .body)
                .foregroundStyle(item.role == .action || item.role == .system ? .secondary : .primary)
                .padding(item.role == .user ? 10 : 0)
                .background(item.role == .user ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 10))
            ForEach(item.files, id: \.self) { file in
                Button(file.lastPathComponent, systemImage: "square.and.arrow.down") { onExport(file) }
            }
        }
        .frame(maxWidth: .infinity, alignment: item.role == .user ? .trailing : .leading)
    }
}
