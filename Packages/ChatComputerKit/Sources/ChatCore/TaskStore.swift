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

/// Persistence boundary. The shipping implementation is SQLite (see ROADMAP §2.1);
/// the in-memory one backs tests and early prototypes.
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
