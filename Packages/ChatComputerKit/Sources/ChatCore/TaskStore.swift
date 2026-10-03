import Foundation

/// Step lifecycle from the proposal (§08): persisted before dispatch, advanced only on evidence.
public enum StepStatus: String, Codable, Sendable {
    case planned
    case dispatched
    case observed
    case verified
    /// We cannot prove whether the step took effect. Never resolved by blind retry.
    case uncertain
    case failed
}

public struct TaskRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var goal: String
    public var createdAt: Date
    public var phase: TaskPhase
    public var modelID: String
    public var inputTokens: Int
    public var outputTokens: Int

    public init(id: UUID = UUID(), goal: String, createdAt: Date = Date(), phase: TaskPhase = .ready, modelID: String) {
        self.id = id
        self.goal = goal
        self.createdAt = createdAt
        self.phase = phase
        self.modelID = modelID
        self.inputTokens = 0
        self.outputTokens = 0
    }
}

/// Append-only event log entry. Chat UI and recovery are both derived from these.
public struct TaskEvent: Codable, Sendable, Equatable {
    public enum Kind: Codable, Sendable, Equatable {
        case phaseChanged(TaskPhase)
        case userMessage(String)
        case assistantNote(String)
        case step(stepID: UUID, status: StepStatus, summary: String)
        case usage(inputTokens: Int, outputTokens: Int)
        case artifact(path: String, bytes: Int)
    }

    public var taskID: UUID
    public var at: Date
    public var kind: Kind

    public init(taskID: UUID, at: Date = Date(), kind: Kind) {
        self.taskID = taskID
        self.at = at
        self.kind = kind
    }
}

/// Persistence boundary. The app uses `FileTaskStore`; the in-memory one backs tests.
public protocol TaskStore: Sendable {
    func create(_ task: TaskRecord) async throws
    func task(_ id: UUID) async throws -> TaskRecord?
    func update(_ task: TaskRecord) async throws
    func append(_ event: TaskEvent) async throws
    func events(for taskID: UUID) async throws -> [TaskEvent]
}

public actor InMemoryTaskStore: TaskStore {
    private var tasks: [UUID: TaskRecord] = [:]
    private var log: [TaskEvent] = []

    public init() {}

    public func create(_ task: TaskRecord) { tasks[task.id] = task }
    public func task(_ id: UUID) -> TaskRecord? { tasks[id] }
    public func update(_ task: TaskRecord) { tasks[task.id] = task }
    public func append(_ event: TaskEvent) { log.append(event) }
    public func events(for taskID: UUID) -> [TaskEvent] { log.filter { $0.taskID == taskID } }
}

/// Tasks on disk: `<root>/<task id>/task.json` and an append-only `events.jsonl`, one JSON event per line.
/// Appends are single writes to the end of the file, so a crash loses at most the line being written,
/// and a torn last line is skipped when reading.
public actor FileTaskStore: TaskStore {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    public func create(_ task: TaskRecord) throws {
        try FileManager.default.createDirectory(at: folder(task.id), withIntermediateDirectories: true)
        try update(task)
    }

    public func task(_ id: UUID) -> TaskRecord? {
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent("task.json")) else { return nil }
        return try? Self.decoder.decode(TaskRecord.self, from: data)
    }

    public func update(_ task: TaskRecord) throws {
        try FileManager.default.createDirectory(at: folder(task.id), withIntermediateDirectories: true)
        try Self.encoder.encode(task).write(to: folder(task.id).appendingPathComponent("task.json"), options: .atomic)
    }

    public func append(_ event: TaskEvent) throws {
        let url = folder(event.taskID).appendingPathComponent("events.jsonl")
        try FileManager.default.createDirectory(at: folder(event.taskID), withIntermediateDirectories: true)
        var line = try Self.encoder.encode(event)
        line.append(10)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url)
        }
    }

    public func events(for taskID: UUID) -> [TaskEvent] {
        guard let data = try? Data(contentsOf: folder(taskID).appendingPathComponent("events.jsonl")) else { return [] }
        return data.split(separator: 10).compactMap { try? Self.decoder.decode(TaskEvent.self, from: Data($0)) }
    }

    /// Every task on disk, newest first.
    public func allTasks() -> [TaskRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { UUID(uuidString: $0).flatMap(task) }.sorted { $0.createdAt > $1.createdAt }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
