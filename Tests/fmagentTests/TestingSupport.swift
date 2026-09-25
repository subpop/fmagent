import ACPKit
import Foundation

@testable import fmagent

/// In-memory ``AgentContext`` recording everything the agent sends.
final class StubContext: AgentContext, @unchecked Sendable {
    let sessionId: SessionId
    let clientCapabilities: ClientCapabilities

    private let lock = NSLock()
    private var _updates: [SessionUpdate] = []
    private var _permissionRequests: [(toolCall: ToolCallUpdate, options: [PermissionOption])] =
        []
    private var _permissionOutcome: RequestPermissionOutcome = .selected(
        optionId: "allow-once", meta: nil)
    private var _permissionHang = false
    private var _fileContents: [String: String] = [:]
    private var _written: [(path: String, content: String)] = []
    private var _terminalOutputText = ""
    private var _terminalsCreated: [(command: String, args: [String]?)] = []
    private var _terminalsKilled = 0
    private var _terminalsReleased = 0

    init(
        sessionId: SessionId = SessionId("test"),
        clientCapabilities: ClientCapabilities = ClientCapabilities()
    ) {
        self.sessionId = sessionId
        self.clientCapabilities = clientCapabilities
    }

    var updates: [SessionUpdate] { lock.withLock { _updates } }
    var permissionRequests: [(toolCall: ToolCallUpdate, options: [PermissionOption])] {
        lock.withLock { _permissionRequests }
    }
    var written: [(path: String, content: String)] { lock.withLock { _written } }
    var terminalsCreated: [(command: String, args: [String]?)] {
        lock.withLock { _terminalsCreated }
    }
    var terminalsKilled: Int { lock.withLock { _terminalsKilled } }
    var terminalsReleased: Int { lock.withLock { _terminalsReleased } }

    func setFile(path: String, content: String) {
        lock.withLock { _fileContents[path] = content }
    }

    func setOutcome(_ outcome: RequestPermissionOutcome) {
        lock.withLock { _permissionOutcome = outcome }
    }

    /// Makes the next permission requests hang (until cancelled), simulating
    /// a client that never answers.
    func setPermissionHang(_ hang: Bool = true) {
        lock.withLock { _permissionHang = hang }
    }

    func setTerminalOutput(_ text: String) {
        lock.withLock { _terminalOutputText = text }
    }

    func requestPermission(
        toolCall: ToolCallUpdate,
        options: [PermissionOption],
        meta: [String: JSONValue]?
    ) async throws -> RequestPermissionOutcome {
        if lock.withLock({ _permissionHang }) {
            // Hang until the caller gives up and cancels (mirrors a silent
            // client; sleep throws on cancellation so no task lingers).
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        return lock.withLock {
            _permissionRequests.append((toolCall, options))
            return _permissionOutcome
        }
    }

    func sendUpdate(_ update: SessionUpdate, meta: [String: JSONValue]?) async throws {
        lock.withLock { _updates.append(update) }
    }

    func readTextFile(path: String, line: UInt32?, limit: UInt32?) async throws -> String {
        guard clientCapabilities.fs.readTextFile else {
            throw AgentContextError.capabilityNotSupported("fs.readTextFile")
        }
        guard let content = lock.withLock({ _fileContents[path] }) else {
            throw AgentContextError.capabilityNotSupported("no stub for \(path)")
        }
        return content
    }

    func writeTextFile(path: String, content: String) async throws {
        guard clientCapabilities.fs.writeTextFile else {
            throw AgentContextError.capabilityNotSupported("fs.writeTextFile")
        }
        lock.withLock { _written.append((path, content)) }
    }

    func createTerminal(
        command: String,
        args: [String]?,
        env: [EnvVariable]?,
        cwd: String?,
        outputByteLimit: UInt64?
    ) async throws -> TerminalId {
        guard clientCapabilities.terminal else {
            throw AgentContextError.capabilityNotSupported("terminal")
        }
        return lock.withLock {
            _terminalsCreated.append((command, args))
            return TerminalId("t\(_terminalsCreated.count)")
        }
    }

    func terminalOutput(terminalId: TerminalId) async throws -> TerminalOutputResponse {
        TerminalOutputResponse(output: lock.withLock { _terminalOutputText }, truncated: false)
    }

    func waitForTerminalExit(terminalId: TerminalId) async throws -> WaitForTerminalExitResponse {
        WaitForTerminalExitResponse(exitCode: 0)
    }

    func killTerminal(terminalId: TerminalId) async throws {
        lock.withLock { _terminalsKilled += 1 }
    }

    func releaseTerminal(terminalId: TerminalId) async throws {
        lock.withLock { _terminalsReleased += 1 }
    }

    /// Plain text of all `agent_message_chunk` updates, in order.
    func agentTexts() -> [String] {
        updates.compactMap { update in
            guard case .agentMessageChunk(let chunk) = update,
                case .text(let content) = chunk.content
            else { return nil }
            return content.text
        }
    }

    func toolCallKinds() -> [ToolKind?] {
        updates.compactMap { update in
            guard case .toolCall(let call) = update else { return nil }
            return call.kind
        }
    }
}

/// Configurable ``InferenceEngine`` recording its inputs.
actor MockEngine: InferenceEngine {
    var chunks: [String] = []
    var stopReason: StopReason = .endTurn
    var transcriptToReturn = Data("transcript-v1".utf8)
    var errorToThrow: (any Error)?
    /// When true, the next call throws `historyCorrupt`, then behaves normally.
    var historyCorruptOnce = false

    var calls: [(history: Data?, text: String)] = []
    var lastInstructions: String?

    func setChunks(_ chunks: [String]) {
        self.chunks = chunks
    }

    func setHistoryCorruptOnce() {
        self.historyCorruptOnce = true
    }

    func respond(
        history: Data?,
        instructions: String,
        prompt: ConvertedPrompt,
        tools: EngineTools,
        onText: @Sendable @escaping (String) async throws -> Void
    ) async throws -> EngineOutcome {
        calls.append((history, prompt.text))
        lastInstructions = instructions
        for chunk in chunks {
            try await onText(chunk)
        }
        if historyCorruptOnce {
            historyCorruptOnce = false
            throw EngineError.historyCorrupt("test corruption")
        }
        if let errorToThrow {
            throw errorToThrow
        }
        return EngineOutcome(
            transcript: transcriptToReturn, responseText: chunks.joined(),
            stopReason: stopReason)
    }
}

func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fmagent-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
