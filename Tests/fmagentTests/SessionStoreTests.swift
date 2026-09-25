import ACPKit
import Foundation
import Testing

@testable import fmagent

@Test func sessionPersistsAcrossStoreInstances() async throws {
    let root = try makeTempDir()
    let store = SessionStore(root: root)
    let cwd = root.path
    let id = try await store.create(cwd: cwd, additionalDirectories: nil, mcpServers: [])

    try await store.savePrompt(
        sessionId: id, transcript: Data("t1".utf8),
        userText: "hello", agentText: "world")

    // A fresh store (simulating process restart) sees the session.
    let reopened = SessionStore(root: root)
    let listed = await reopened.list(cwd: nil)
    #expect(listed.count == 1)
    #expect(listed[0].sessionId == id)
    #expect(listed[0].cwd == cwd)

    let session = try await reopened.session(for: id)
    #expect(session.transcript == Data("t1".utf8))
    #expect(session.meta.events.map(\.text) == ["hello", "world"])

    try await reopened.delete(sessionId: id)
    #expect(await reopened.list(cwd: nil).isEmpty)
}

@Test func sessionListFiltersByCwd() async throws {
    let root = try makeTempDir()
    let store = SessionStore(root: root)
    let other = root.appendingPathComponent("other", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let a = try await store.create(cwd: root.path, additionalDirectories: nil, mcpServers: [])
    let b = try await store.create(cwd: other.path, additionalDirectories: nil, mcpServers: [])

    #expect(await store.list(cwd: nil).count == 2)
    let filtered = await store.list(cwd: root.path)
    #expect(filtered.map(\.sessionId) == [a])
    _ = b
}

@Test func openUnknownSessionThrows() async throws {
    let store = SessionStore(root: try makeTempDir())
    await #expect(throws: SessionStoreError.sessionNotFound(SessionId("nope"))) {
        try await store.session(for: SessionId("nope"))
    }
}

@Test func resetTranscriptClearsHistory() async throws {
    let root = try makeTempDir()
    let store = SessionStore(root: root)
    let id = try await store.create(cwd: root.path, additionalDirectories: nil, mcpServers: [])
    try await store.savePrompt(
        sessionId: id, transcript: Data("t".utf8), userText: "u", agentText: "a")
    try await store.resetTranscript(sessionId: id)
    let session = try await store.session(for: id)
    #expect(session.transcript == nil)
    // Events are kept for replay.
    #expect(session.meta.events.count == 2)
}

@Test func closeKeepsFilesDeleteRemovesThem() async throws {
    let root = try makeTempDir()
    let store = SessionStore(root: root)
    let id = try await store.create(cwd: root.path, additionalDirectories: nil, mcpServers: [])
    await store.close(sessionId: id)
    #expect(await store.list(cwd: nil).count == 1)
    try await store.delete(sessionId: id)
    #expect(await store.list(cwd: nil).isEmpty)
}

@Test func sessionCreateSurvivesSilentMCPServer() async throws {
    // `/bin/sleep` spawns but never answers the MCP handshake. Creation
    // must return immediately (without tools) instead of waiting out the
    // connect timeout: dials run in the background and adopt late.
    let root = try makeTempDir()
    let store = SessionStore(root: root, mcpConnectTimeout: 30)
    let servers: [McpServer] = [
        .stdio(McpServerStdio(name: "silent", command: "/bin/sleep", args: ["5"], env: []))
    ]
    let start = Date()
    let id = try await store.create(
        cwd: root.path, additionalDirectories: nil, mcpServers: servers)
    #expect(Date().timeIntervalSince(start) < 10)
    let session = try await store.session(for: id)
    #expect(session.mcpTools.isEmpty)
}
