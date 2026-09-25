import ACPKit
import Foundation
import Logging

/// ``Agent`` implementation serving ACP clients with Apple Foundation Models.
///
/// All inference goes through an ``InferenceEngine`` (production:
/// ``FoundationModelsEngine``); all state lives in ``SessionStore`` with
/// on-disk persistence. The agent itself holds no session data and is safe to
/// share across connections.
///
/// Failures are logged with method/session context (successes stay quiet so
/// `--log-file` output means something is wrong). When configured MCP
/// servers have no connected tools, the model is told so explicitly rather
/// than left to assume their results.
public struct FoundationModelsAgent: Agent, Sendable {
    private let store: SessionStore
    private let engine: any InferenceEngine
    private let logger: Logger

    public init(
        store: SessionStore, engine: any InferenceEngine,
        logger: Logger = Logger(label: "fmagent")
    ) {
        self.store = store
        self.engine = engine
        self.logger = logger
    }

    /// Runs `operation`, logging failures with the method name before
    /// rethrowing. Successes are not logged: stdout is protocol-only and the
    /// log file stays quiet unless something actually goes wrong.
    private func reportingErrors<T: Sendable>(
        _ method: String, metadata: Logger.Metadata? = nil,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            var combined = metadata ?? [:]
            combined["error"] = "\(error)"
            logger.error("\(method) failed", metadata: combined)
            throw error
        }
    }

    // MARK: - Identity

    public var capabilities: AgentCapabilities {
        AgentCapabilities(
            loadSession: true,
            promptCapabilities: PromptCapabilities(
                image: true, audio: false, embeddedContext: true),
            mcpCapabilities: McpCapabilities(http: false, sse: false),
            sessionCapabilities: SessionCapabilities(
                list: SessionListCapabilities(),
                delete: SessionDeleteCapabilities(),
                close: SessionCloseCapabilities()
            )
        )
    }

    public var info: Implementation? {
        Implementation(
            name: "fmagent", title: "Foundation Models Agent", version: "0.1.0")
    }

    // MARK: - Sessions

    public func createSession(request: NewSessionRequest) async throws -> NewSessionResponse {
        try await reportingErrors(
            "session/new", metadata: ["cwd": "\(request.cwd)"]
        ) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: request.cwd, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw AgentError.invalidParams("cwd does not exist: \(request.cwd)")
            }
            let sessionId = try await store.create(
                cwd: request.cwd, additionalDirectories: request.additionalDirectories,
                mcpServers: request.mcpServers)
            return NewSessionResponse(
                sessionId: sessionId, configOptions: [SessionModelOption.configOption()])
        }
    }

    public func loadSession(
        request: LoadSessionRequest, context: AgentContext
    ) async throws -> LoadSessionResponse {
        try await reportingErrors(
            "session/load", metadata: ["sessionId": "\(request.sessionId)"]
        ) {
            let session: OpenSession
            do {
                session = try await store.session(for: request.sessionId)
            } catch SessionStoreError.sessionNotFound {
                throw AgentError.sessionNotFound(request.sessionId)
            }
            for event in session.meta.events {
                switch event.kind {
                case .user:
                    try await context.sendUpdate(
                        .userMessageChunk(
                            ContentChunk(
                                content: .text(TextContent(text: event.text)))))
                case .agent:
                    try await context.sendUpdate(
                        .agentMessageChunk(
                            ContentChunk(
                                content: .text(TextContent(text: event.text)))))
                }
            }
            return LoadSessionResponse(configOptions: [SessionModelOption.configOption()])
        }
    }

    public func listSessions(request: ListSessionsRequest) async throws -> ListSessionsResponse {
        try await reportingErrors("session/list") {
            ListSessionsResponse(sessions: await store.list(cwd: request.cwd))
        }
    }

    public func closeSession(request: CloseSessionRequest) async throws -> CloseSessionResponse {
        try await reportingErrors(
            "session/close", metadata: ["sessionId": "\(request.sessionId)"]
        ) {
            await store.close(sessionId: request.sessionId)
            return CloseSessionResponse()
        }
    }

    public func deleteSession(
        request: DeleteSessionRequest
    ) async throws -> DeleteSessionResponse {
        try await reportingErrors(
            "session/delete", metadata: ["sessionId": "\(request.sessionId)"]
        ) {
            do {
                try await store.delete(sessionId: request.sessionId)
            } catch SessionStoreError.sessionNotFound {
                throw AgentError.sessionNotFound(request.sessionId)
            }
            return DeleteSessionResponse()
        }
    }

    // MARK: - Config options

    public func setSessionConfigOption(
        request: SetSessionConfigOptionRequest
    ) async throws -> SetSessionConfigOptionResponse {
        try await reportingErrors(
            "session/set_config_option",
            metadata: ["sessionId": "\(request.sessionId)", "configId": "\(request.configId)"]
        ) {
            guard request.configId == SessionModelOption.id else {
                throw AgentError.invalidParams("Unknown config option: \(request.configId)")
            }
            guard case .valueId(let value) = request.value, value == SessionModelOption.onDevice
            else {
                throw AgentError.invalidParams(
                    "Unsupported model value. Only '\(SessionModelOption.onDevice)' is available.")
            }
            do {
                try await store.setModelValue(sessionId: request.sessionId, value: value.rawValue)
            } catch SessionStoreError.sessionNotFound {
                throw AgentError.sessionNotFound(request.sessionId)
            }
            return SetSessionConfigOptionResponse(
                configOptions: [SessionModelOption.configOption()])
        }
    }

    // MARK: - Prompt

    public func handlePrompt(
        request: PromptRequest, context: AgentContext
    ) async throws -> PromptResponse {
        try await reportingErrors(
            "session/prompt", metadata: ["sessionId": "\(request.sessionId)"]
        ) {
            logger.debug(
                "session/prompt begin", metadata: ["sessionId": "\(request.sessionId)"])
            let converted = try PromptConverter.convert(request.prompt)

            let session: OpenSession
            do {
                session = try await store.session(for: request.sessionId)
            } catch SessionStoreError.sessionNotFound {
                throw AgentError.sessionNotFound(request.sessionId)
            }
            logger.debug(
                "session loaded",
                metadata: [
                    "sessionId": "\(request.sessionId)",
                    "hasTranscript": "\(session.transcript != nil)",
                    "mcpTools": "\(session.mcpTools.count)",
                ])

            let tools = EngineTools(
                context: context, policy: session.policy,
                mcpManager: session.mcpManager, mcpTools: session.mcpTools,
                sessionCwd: session.meta.cwd)

            // MCP servers configured but unconnected (timed-out dial, still
            // awaiting client approval): name them so the model says so
            // instead of inventing their results.
            let missingMCP =
                session.mcpTools.isEmpty ? mcpServerNames(session.meta.mcpServers) : []
            let instructions = instructions(
                cwd: session.meta.cwd, unavailableMCP: missingMCP)

            // Traces engine progress at debug level: a hang shows its last
            // completed stage (begin / first text / done).
            let trace = PromptTrace(
                logger: logger, metadata: ["sessionId": "\(request.sessionId)"])
            let outcome: EngineOutcome
            do {
                await trace.engineBegin()
                outcome = try await engine.respond(
                    history: session.transcript,
                    instructions: instructions,
                    prompt: converted,
                    tools: tools,
                    onText: { text in
                        await trace.firstText()
                        try await context.sendTextMessage(text)
                    }
                )
                await trace.engineDone("\(outcome.stopReason)")
            } catch EngineError.historyCorrupt {
                // Persisted transcript is unreadable (e.g. SDK skew): start fresh
                // but keep the replay log, then retry once.
                logger.warning(
                    "session/prompt retrying with fresh transcript",
                    metadata: ["sessionId": "\(request.sessionId)"])
                try await store.resetTranscript(sessionId: request.sessionId)
                await trace.engineBeginRetry()
                let retried = try await engine.respond(
                    history: nil,
                    instructions: instructions,
                    prompt: converted,
                    tools: tools,
                    onText: { text in
                        await trace.firstText()
                        try await context.sendTextMessage(text)
                    }
                )
                await trace.engineDone("\(retried.stopReason)")
                try await store.savePrompt(
                    sessionId: request.sessionId, transcript: retried.transcript,
                    userText: PromptConverter.summarize(converted),
                    agentText: retried.responseText)
                await trace.promptSaved()
                return PromptResponse(stopReason: retried.stopReason)
            }

            try await store.savePrompt(
                sessionId: request.sessionId, transcript: outcome.transcript,
                userText: PromptConverter.summarize(converted),
                agentText: outcome.responseText)
            await trace.promptSaved()
            return PromptResponse(stopReason: outcome.stopReason)
        }
    }

    // MARK: - Instructions

    private func mcpServerNames(_ servers: [McpServer]) -> [String] {
        servers.map {
            switch $0 {
            case .stdio(let server): return server.name
            case .http(let server): return server.name
            case .sse(let server): return server.name
            }
        }
    }

    private func instructions(cwd: String, unavailableMCP: [String] = []) -> String {
        var text = """
            You are fmagent, an AI coding assistant running on-device via Apple Foundation Models.
            The session working directory is: \(cwd)
            Answer concisely. Use the available tools (file reads/writes, terminal commands, MCP tools) to act on the user's codebase rather than guessing. Prefer read_file over terminal output for viewing files. Writes and command execution require user permission, which is requested automatically — if denied, respect it and propose an alternative.
            Today's date is \(ISO8601DateFormatter().string(from: Date())).
            """
        if !unavailableMCP.isEmpty {
            text +=
                "\nNote: the configured MCP servers (\(unavailableMCP.joined(separator: ", "))) could not be connected (they may still be awaiting approval in the client), so their tools are unavailable. Do not claim to have used them or invent their results; tell the user to approve the servers and re-prompt if the task needs them."
        }
        return text
    }
}

/// Debug-level trace of one prompt's engine progress.
///
/// All lines are `logger.debug`, so they only appear with `--debug`: normal
/// runs stay quiet, while a hung prompt's log ends at its last completed
/// stage (begin / first text / done / saved).
private actor PromptTrace {
    private let logger: Logger
    private let metadata: Logger.Metadata
    private var firstTextLogged = false

    init(logger: Logger, metadata: Logger.Metadata) {
        self.logger = logger
        self.metadata = metadata
    }

    func engineBegin() {
        logger.debug("engine begin", metadata: metadata)
    }

    func engineBeginRetry() {
        logger.debug("engine begin (fresh transcript retry)", metadata: metadata)
    }

    func firstText() {
        guard !firstTextLogged else { return }
        firstTextLogged = true
        logger.debug("engine first text", metadata: metadata)
    }

    func engineDone(_ stopReason: String) {
        var metadata = metadata
        metadata["stopReason"] = "\(stopReason)"
        logger.debug("engine done", metadata: metadata)
    }

    func promptSaved() {
        logger.debug("prompt saved", metadata: metadata)
    }
}
