import Foundation

/// A row of the transcript as shown: a message, or the agent's work between your message and its answer, folded
/// into one row like a model's thinking.
enum ChatEntry: Identifiable, Hashable {
    case message(ChatItem)
    case process(ChatProcess)

    var id: UUID {
        switch self {
        case .message(let item): item.id
        case .process(let process): process.id
        }
    }
}

/// The agent's notes and actions between your message and its result or question.
struct ChatProcess: Hashable {
    enum State: Hashable {
        /// The task is working on it now: show the latest note.
        case live
        /// A result or question follows: fold it away.
        case answered
        /// The task stopped without an answer (paused, cancelled, failed): show where.
        case stopped
    }

    /// The first note's: stays the same as the process grows.
    let id: UUID
    let notes: [ChatItem]
    let state: State
    let isExpanded: Bool
    let showsActions: Bool

    /// Steps are the actions taken; a process with notes only counts its notes.
    var steps: Int {
        let actions = notes.count(where: { $0.role == .action })
        return actions > 0 ? actions : notes.count
    }

    /// From your message to the last note, when the items carry dates.
    let seconds: Int?
    /// The model's text arriving right now, for a live process.
    var liveText: String? = nil

    /// What the expanded row shows, as Markdown: the notes, and the actions when steps are shown, each run of
    /// actions on one line.
    var markdown: String {
        var paragraphs: [String] = []
        var actions: [String] = []
        func flushActions() {
            if !actions.isEmpty { paragraphs.append(actions.joined(separator: " · ")) }
            actions = []
        }
        for note in notes {
            if note.role == .action {
                if showsActions { actions.append("`\(note.text.replacingOccurrences(of: "`", with: "'"))`") }
            } else {
                flushActions()
                paragraphs.append(note.text)
            }
        }
        flushActions()
        return paragraphs.joined(separator: "\n\n")
    }

    /// The newest note, for a live process: what is streaming in, else the last note that arrived.
    var latestNote: String? { liveText ?? notes.last { $0.role == .agent }?.text }

    /// Stands in for the process of a turn that has no notes yet, while its first text streams in.
    static let pendingID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!

    var summary: String {
        let steps = steps == 1 ? "1 step" : "\(steps) steps"
        guard let seconds else { return steps }
        let time = seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
        return "\(steps) · \(time)"
    }
}

enum ChatEntries {
    /// Groups the transcript's runs of agent notes and actions. `toggled` holds the processes the user opened or
    /// closed against their default (answered ones start closed, stopped ones open).
    static func make(from transcript: [ChatItem], isWorking: Bool, toggled: Set<UUID>, showsActions: Bool,
                     liveText: String? = nil) -> [ChatEntry] {
        var entries: [ChatEntry] = []
        var run: [ChatItem] = []
        var startedAt: Date?

        func flush(before next: ChatItem?) {
            defer { run = [] }
            guard let first = run.first else { return }
            let state: ChatProcess.State = if let next { next.emphasis != nil ? .answered : .stopped }
                else { isWorking ? .live : .stopped }
            // The agent only talked, and nothing answers it: there is nothing to fold.
            if state == .stopped, !run.contains(where: { $0.role == .action }) {
                entries += run.map { .message($0) }
                return
            }
            let defaultOpen = state == .stopped
            let end = run.last?.date ?? next?.date
            let seconds = startedAt.flatMap { start in end.map { max(0, Int($0.timeIntervalSince(start).rounded())) } }
            entries.append(.process(ChatProcess(id: first.id, notes: run, state: state,
                                                isExpanded: defaultOpen != toggled.contains(first.id),
                                                showsActions: showsActions, seconds: seconds,
                                                liveText: state == .live ? liveText : nil)))
        }

        for item in transcript {
            if item.role == .action || (item.role == .agent && item.emphasis == nil) {
                if run.isEmpty, startedAt == nil { startedAt = item.date }
                run.append(item)
                continue
            }
            flush(before: item)
            if item.role == .user { startedAt = item.date } else if item.emphasis != nil { startedAt = nil }
            entries.append(.message(item))
        }
        flush(before: nil)
        // The first turn after your message: nothing has arrived yet but the text being written.
        if isWorking, let liveText, !liveText.isEmpty, case .message? = entries.last {
            entries.append(.process(ChatProcess(id: ChatProcess.pendingID, notes: [], state: .live, isExpanded: false,
                                                showsActions: showsActions, seconds: nil, liveText: liveText)))
        }
        return entries
    }
}
