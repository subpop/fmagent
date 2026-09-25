import ACPKit
import Foundation
import Logging

/// One entry in a session's replay log, streamed back on `session/load`.
public struct SessionEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case user
        case agent
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Persisted session metadata (`meta.json`).
public struct SessionMeta: Codable, Sendable {
    var sessionId: String
    var cwd: String
    var additionalDirectories: [String]?
    var mcpServers: [McpServer]
    var title: String?
    var updatedAt: String
    var alwaysAllowed: Set<String>
    var events: [SessionEvent]
    /// Selected `model` config-option value. Single choice today (`on-device`).
    var modelValue: String = "on-device"

    static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

/// An open session: persisted metadata plus live connections.
///
/// The store keeps at most one `OpenSession` per id; repeated prompts reuse
/// the MCP connections. `LanguageModelSession`s are intentionally *not* kept
/// here — the engine rebuilds them per prompt from the persisted transcript.
public struct OpenSession: Sendable {
    var meta: SessionMeta
    var transcript: Data?
    var policy: PermissionPolicy
    var mcpManager: MCPClientManager
    var mcpTools: [MCPNamespacedTool]
}

public enum SessionStoreError: Error, Sendable, Equatable {
    case sessionNotFound(SessionId)
    case ioError(String)
}

/// First-claim-wins gate so exactly one side of the `connectMCP` race resumes
/// its continuation; the loser is abandoned.
private final class MCPConnectGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

/// Actor owning session lifecycle and on-disk persistence.
///
/// Layout: `<root>/<sessionId>/meta.json` + `transcript.json`. Writes are
/// atomic (temporary file + rename). `close` drops in-memory state and keeps
/// files; `delete` removes the directory.
///
/// MCP dials never block the caller: `create`, reopen, and touches return
/// immediately with whatever tools are connected so far (usually none on
/// first touch), while at most one background dial per session runs to
/// completion and adopts its tools into the open session for later
/// prompts. A silent or approval-gated server therefore delays tools,
/// never responses. `mcpConnectTimeout` only sets how soon the "proceeding
/// without tools" warning is logged; the dial itself runs to ACPKit's own
/// bounds. Dials are never cancelled: `close`/`delete` drop the session,
/// and a late dial for a gone session simply closes its own manager.
public actor SessionStore {
    private let root: URL
    private let mcpConnectTimeout: TimeInterval
    private let logger: Logger
    private var open: [String: OpenSession] = [:]
    /// Session ids with a dial in flight. Inserted synchronously before the
    /// dial task is created (same actor turn, so no race); cleared when the
    /// dial task finishes. Deliberately untouched by `close`/`delete`: a
    /// reopened session adopts the still-running dial instead of spawning
    /// a competitor.
    private var inflightDials: Set<String> = []

    public init(
        root: URL, mcpConnectTimeout: TimeInterval = 30,
        logger: Logger = Logger(label: "fmagent.SessionStore")
    ) {
        self.root = root
        self.mcpConnectTimeout = mcpConnectTimeout
        self.logger = logger
    }

    public static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/fmagent/sessions", isDirectory: true)
    }

    // MARK: - Create / open

    /// Creates a session and persists initial metadata, returning
    /// immediately: the MCP dial runs in the background (see
    /// `dialInBackground`) and its tools land via adoption.
    public func create(
        cwd: String, additionalDirectories: [String]?, mcpServers: [McpServer]
    ) async throws -> SessionId {
        let sessionId = SessionId(UUID().uuidString)
        let meta = SessionMeta(
            sessionId: sessionId.rawValue, cwd: cwd,
            additionalDirectories: additionalDirectories, mcpServers: mcpServers,
            title: nil, updatedAt: SessionMeta.now(), alwaysAllowed: [], events: [])
        dialInBackground(sessionKey: sessionId.rawValue, servers: mcpServers)
        open[sessionId.rawValue] = OpenSession(
            meta: meta, transcript: nil,
            policy: PermissionPolicy(), mcpManager: MCPClientManager(), mcpTools: [])
        try saveMeta(meta)
        return sessionId
    }

    /// Returns the cached session or reopens it from disk. Reopening also
    /// returns immediately: a missing MCP connection is re-dialled in the
    /// background rather than stalling `session/load`.
    public func session(for sessionId: SessionId) async throws -> OpenSession {
        if let session = open[sessionId.rawValue] {
            if !session.meta.mcpServers.isEmpty, session.mcpTools.isEmpty {
                dialInBackground(
                    sessionKey: sessionId.rawValue, servers: session.meta.mcpServers)
            }
            return session
        }
        let meta = try loadMeta(sessionId: sessionId)
        let transcript = loadTranscript(sessionId: sessionId)
        dialInBackground(sessionKey: sessionId.rawValue, servers: meta.mcpServers)
        let session = OpenSession(
            meta: meta, transcript: transcript,
            policy: PermissionPolicy(alwaysAllowed: meta.alwaysAllowed),
            mcpManager: MCPClientManager(), mcpTools: [])
        open[sessionId.rawValue] = session
        return session
    }

    // MARK: - MCP dial (background, single-flight, with late adoption)

    /// Starts a dial for `servers` unless one is already running for the
    /// session, and returns immediately. The dial runs to ACPKit's own
    /// bounds; after `mcpConnectTimeout` a warning notes the session is
    /// proceeding without MCP tools so far. Whatever the dial finds is
    /// adopted into the still-open session (see `adoptLateConnect`), so
    /// later prompts get the tools — including servers approved in the
    /// client long after the session started.
    ///
    /// Synchronous (no awaits) so the check-and-register is atomic: at most
    /// one dial per session key can exist.
    private func dialInBackground(sessionKey: String, servers: [McpServer]) {
        guard !servers.isEmpty, inflightDials.insert(sessionKey).inserted else { return }
        let timeout = mcpConnectTimeout
        let logger = self.logger
        Task.detached {
            let gate = MCPConnectGate()
            let manager = MCPClientManager()
            Task.detached {
                let tools = await manager.connectAll(servers: servers)
                // Claim first so a fast dial suppresses the timeout warning;
                // adoption happens in dialDidFinish either way.
                _ = gate.claim()
                await self.dialDidFinish(
                    sessionKey: sessionKey, manager: manager, tools: tools)
            }
            Task.detached {
                try? await Task.sleep(
                    nanoseconds: UInt64(max(timeout, 1) * 1_000_000_000))
                if gate.claim() {
                    logger.warning(
                        "MCP connect timed out; continuing without MCP tools",
                        metadata: ["timeoutSeconds": "\(Int(max(timeout, 1)))"])
                }
            }
        }
    }

    /// Settles a finished dial: releases its single-flight slot, then
    /// adopts genuine successes into a still-open, still-tool-less session.
    /// Anything else (empty result, closed session, newer tools already
    /// adopted) closes the late manager instead of leaking it.
    private func dialDidFinish(
        sessionKey: String, manager: MCPClientManager, tools: [MCPNamespacedTool]
    ) async {
        inflightDials.remove(sessionKey)
        await adoptLateConnect(sessionKey: sessionKey, manager: manager, tools: tools)
    }

    /// Adopts a finished dial's tools into the open session when they add
    /// something (non-empty tools into a still-tool-less session).
    private func adoptLateConnect(
        sessionKey: String, manager: MCPClientManager, tools: [MCPNamespacedTool]
    ) async {
        guard !tools.isEmpty,
            var session = open[sessionKey],
            session.mcpTools.isEmpty
        else {
            await manager.closeAll()
            return
        }
        await session.mcpManager.closeAll()
        session.mcpManager = manager
        session.mcpTools = tools
        open[sessionKey] = session
        logger.info(
            "MCP late connect adopted",
            metadata: ["sessionId": "\(sessionKey)", "tools": "\(tools.count)"])
    }

    // MARK: - Save

    /// Persists a completed prompt: transcript, replay events, permissions, timestamp.
    public func savePrompt(
        sessionId: SessionId, transcript: Data, userText: String, agentText: String
    ) async throws {
        guard var session = open[sessionId.rawValue] else {
            throw SessionStoreError.sessionNotFound(sessionId)
        }
        session.transcript = transcript
        session.meta.events.append(SessionEvent(kind: .user, text: userText))
        session.meta.events.append(SessionEvent(kind: .agent, text: agentText))
        session.meta.updatedAt = SessionMeta.now()
        session.meta.alwaysAllowed = await session.policy.snapshot()
        open[sessionId.rawValue] = session
        try saveMeta(session.meta)
        try saveTranscript(sessionId: sessionId, data: transcript)
    }

    /// Clears corrupted history so the next prompt starts fresh (events kept).
    public func resetTranscript(sessionId: SessionId) async throws {
        guard var session = open[sessionId.rawValue] else {
            throw SessionStoreError.sessionNotFound(sessionId)
        }
        session.transcript = nil
        open[sessionId.rawValue] = session
        try removeTranscript(sessionId: sessionId)
    }

    /// Persists the selected `model` config-option value, opening the session
    /// from disk first when this process has not cached it yet.
    public func setModelValue(sessionId: SessionId, value: String) async throws {
        if open[sessionId.rawValue] == nil {
            _ = try await session(for: sessionId)
        }
        guard var session = open[sessionId.rawValue] else {
            throw SessionStoreError.sessionNotFound(sessionId)
        }
        session.meta.modelValue = value
        session.meta.updatedAt = SessionMeta.now()
        open[sessionId.rawValue] = session
        try saveMeta(session.meta)
    }

    // MARK: - List / close / delete

    public func list(cwd: String?) -> [SessionInfo] {
        let ids =
            ((try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath }
        var infos: [SessionInfo] = []
        for url in ids {
            guard let data = try? Data(contentsOf: url.appendingPathComponent("meta.json")),
                let meta = try? JSONDecoder().decode(SessionMeta.self, from: data)
            else { continue }
            if let cwd, meta.cwd != cwd { continue }
            infos.append(
                SessionInfo(
                    sessionId: SessionId(meta.sessionId), cwd: meta.cwd,
                    additionalDirectories: meta.additionalDirectories,
                    title: meta.title, updatedAt: meta.updatedAt))
        }
        // Merge in-memory-only sessions (created but Meta write failed is
        // impossible — create writes synchronously — so this is just a safety net).
        for session in open.values
        where !infos.contains(where: {
            $0.sessionId == SessionId(session.meta.sessionId)
        }) {
            if let cwd, session.meta.cwd != cwd { continue }
            infos.append(
                SessionInfo(
                    sessionId: SessionId(session.meta.sessionId), cwd: session.meta.cwd,
                    additionalDirectories: session.meta.additionalDirectories,
                    title: session.meta.title, updatedAt: session.meta.updatedAt))
        }
        return infos.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
    }

    public func close(sessionId: SessionId) async {
        if let session = open.removeValue(forKey: sessionId.rawValue) {
            await session.mcpManager.closeAll()
        }
    }

    public func delete(sessionId: SessionId) async throws {
        if let session = open.removeValue(forKey: sessionId.rawValue) {
            await session.mcpManager.closeAll()
        }
        let dir = root.appendingPathComponent(sessionId.rawValue, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.removeItem(at: dir)
            } catch {
                throw SessionStoreError.ioError("\(error)")
            }
        }
    }

    // MARK: - Disk I/O (synchronous, called from the actor)

    private func directory(for sessionId: SessionId) -> URL {
        root.appendingPathComponent(sessionId.rawValue, isDirectory: true)
    }

    private func loadMeta(sessionId: SessionId) throws -> SessionMeta {
        let url = directory(for: sessionId).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url),
            let meta = try? JSONDecoder().decode(SessionMeta.self, from: data)
        else {
            throw SessionStoreError.sessionNotFound(sessionId)
        }
        return meta
    }

    private func loadTranscript(sessionId: SessionId) -> Data? {
        let url = directory(for: sessionId).appendingPathComponent("transcript.json")
        return try? Data(contentsOf: url)
    }

    private func saveMeta(_ meta: SessionMeta) throws {
        try writeAtomically(
            data: try JSONEncoder().encode(meta),
            to: directory(for: SessionId(meta.sessionId)).appendingPathComponent("meta.json"))
    }

    private func saveTranscript(sessionId: SessionId, data: Data) throws {
        try writeAtomically(
            data: data,
            to: directory(for: sessionId).appendingPathComponent("transcript.json"))
    }

    private func removeTranscript(sessionId: SessionId) throws {
        let url = directory(for: sessionId).appendingPathComponent("transcript.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw SessionStoreError.ioError("\(error)")
            }
        }
    }

    private func writeAtomically(data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent(UUID().uuidString + ".tmp")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            throw SessionStoreError.ioError("\(error)")
        }
    }
}
