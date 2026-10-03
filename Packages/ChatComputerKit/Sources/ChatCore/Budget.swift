import Foundation

/// Per-task limits enforced outside the model (proposal §06 step 5, §08).
public struct TaskBudget: Codable, Sendable, Equatable {
    public var maxModelTurns: Int
    public var maxActions: Int
    public var maxInputTokens: Int
    public var maxOutputTokens: Int
    /// Consecutive failed actions before the task stops instead of retrying.
    public var maxConsecutiveFailures: Int

    public init(maxModelTurns: Int = 60, maxActions: Int = 300, maxInputTokens: Int = 4_000_000, maxOutputTokens: Int = 400_000, maxConsecutiveFailures: Int = 3) {
        self.maxModelTurns = maxModelTurns
        self.maxActions = maxActions
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
        self.maxConsecutiveFailures = maxConsecutiveFailures
    }
}

public struct BudgetUsage: Codable, Sendable, Equatable {
    public var modelTurns = 0
    public var actions = 0
    public var inputTokens = 0
    public var outputTokens = 0
    /// Of `inputTokens`, served from the provider's prompt cache.
    public var cachedInputTokens = 0
    public var consecutiveFailures = 0

    public init() {}

    /// The first limit that is exhausted, if any.
    public func exceeded(_ budget: TaskBudget) -> String? {
        if modelTurns >= budget.maxModelTurns { return "model turn limit (\(budget.maxModelTurns))" }
        if actions >= budget.maxActions { return "action limit (\(budget.maxActions))" }
        if inputTokens >= budget.maxInputTokens { return "input token budget" }
        if outputTokens >= budget.maxOutputTokens { return "output token budget" }
        if consecutiveFailures >= budget.maxConsecutiveFailures { return "\(consecutiveFailures) consecutive failed actions" }
        return nil
    }
}
