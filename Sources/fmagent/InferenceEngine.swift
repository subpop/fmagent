import ACPKit
import Foundation

/// Everything the agent needs from an inference backend for one prompt.
///
/// `history` is opaque backend state (encoded transcript) previously returned
/// in ``EngineOutcome/transcript``; `nil` starts a fresh session. Text is
/// delivered incrementally through `onText`. Tools (file/terminal/MCP) are
/// constructed by the engine from `tools` on every call, so each prompt gets
/// tools bound to its own ``AgentContext``.
public struct EngineTools: Sendable {
    public var context: any AgentContext
    public var policy: PermissionPolicy
    public var mcpManager: MCPClientManager
    public var mcpTools: [MCPNamespacedTool]
    public var sessionCwd: String

    public init(
        context: any AgentContext,
        policy: PermissionPolicy,
        mcpManager: MCPClientManager,
        mcpTools: [MCPNamespacedTool],
        sessionCwd: String
    ) {
        self.context = context
        self.policy = policy
        self.mcpManager = mcpManager
        self.mcpTools = mcpTools
        self.sessionCwd = sessionCwd
    }
}

public struct EngineOutcome: Sendable {
    /// Updated backend state to persist for the session.
    public var transcript: Data
    /// Full response text (accumulated from the stream) for the replay log.
    public var responseText: String
    public var stopReason: StopReason

    public init(transcript: Data, responseText: String, stopReason: StopReason) {
        self.transcript = transcript
        self.responseText = responseText
        self.stopReason = stopReason
    }
}

public enum EngineError: Error, Sendable {
    /// Persisted history could not be restored (e.g. SDK version skew).
    /// Callers should retry once with `history: nil`.
    case historyCorrupt(String)
}

public protocol InferenceEngine: Sendable {
    func respond(
        history: Data?,
        instructions: String,
        prompt: ConvertedPrompt,
        tools: EngineTools,
        onText: @Sendable @escaping (String) async throws -> Void
    ) async throws -> EngineOutcome
}
