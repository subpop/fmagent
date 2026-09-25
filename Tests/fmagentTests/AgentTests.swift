import ACPKit
import Foundation
import Testing

@testable import fmagent

private func makeAgent(
    root: URL, engine: MockEngine
) -> (FoundationModelsAgent, SessionStore) {
    let store = SessionStore(root: root)
    return (FoundationModelsAgent(store: store, engine: engine), store)
}

@Test func promptStreamsAndPersists() async throws {
    let root = try makeTempDir()
    let engine = MockEngine()
    await engine.setChunks(["hello", " world"])
    let (agent, store) = makeAgent(root: root, engine: engine)

    let session = try await agent.createSession(request: NewSessionRequest(
        cwd: root.path, mcpServers: []))
    let context = StubContext(sessionId: session.sessionId)
    let response = try await agent.handlePrompt(
        request: PromptRequest(
            sessionId: session.sessionId, prompt: [.text(TextContent(text: "hi"))]),
        context: context)

    #expect(response.stopReason == .endTurn)
    #expect(context.agentTexts().joined() == "hello world")

    // Transcript persisted; second prompt replays history into the engine.
    let calls = await engine.calls
    #expect(calls.count == 1)
    #expect(calls[0].history == nil)
    let saved = try await store.session(for: session.sessionId)
    #expect(saved.transcript == Data("transcript-v1".utf8))

    let context2 = StubContext(sessionId: session.sessionId)
    _ = try await agent.handlePrompt(
        request: PromptRequest(
            sessionId: session.sessionId, prompt: [.text(TextContent(text: "again"))]),
        context: context2)
    #expect(await engine.calls.count == 2)
    let secondCalls = await engine.calls
    #expect(secondCalls[1].history == Data("transcript-v1".utf8))
}

@Test func promptRejectsAudio() async throws {
    let root = try makeTempDir()
    let engine = MockEngine()
    let (agent, _) = makeAgent(root: root, engine: engine)
    let session = try await agent.createSession(request: NewSessionRequest(
        cwd: root.path, mcpServers: []))
    await #expect(throws: AgentError.self) {
        try await agent.handlePrompt(
            request: PromptRequest(
                sessionId: session.sessionId,
                prompt: [.audio(AudioContent(data: "AAA", mimeType: "audio/mp3"))]),
            context: StubContext(sessionId: session.sessionId))
    }
    #expect(await engine.calls.isEmpty)
}

@Test func promptUnknownSession() async throws {
    let root = try makeTempDir()
    let engine = MockEngine()
    let (agent, _) = makeAgent(root: root, engine: engine)
    await #expect(throws: AgentError.sessionNotFound(SessionId("nope"))) {
        try await agent.handlePrompt(
            request: PromptRequest(
                sessionId: SessionId("nope"), prompt: [.text(TextContent(text: "hi"))]),
            context: StubContext())
    }
}

@Test func promptNotesUnconnectedMCPServers() async throws {
    // Configured servers with no connected tools are named in the model
    // instructions so it reports the gap instead of inventing results.
    let root = try makeTempDir()
    let engine = MockEngine()
    let (agent, _) = makeAgent(root: root, engine: engine)
    let session = try await agent.createSession(request: NewSessionRequest(
        cwd: root.path,
        mcpServers: [
            .stdio(
                McpServerStdio(
                    name: "ghost", command: "/nonexistent-binary-xyz", args: [], env: []))
        ]))
    _ = try await agent.handlePrompt(
        request: PromptRequest(
            sessionId: session.sessionId, prompt: [.text(TextContent(text: "hi"))]),
        context: StubContext(sessionId: session.sessionId))
    let instructions = await engine.lastInstructions
    #expect(instructions?.contains("ghost") == true)
    #expect(instructions?.contains("could not be connected") == true)
}

@Test func promptOmitsMCPNoteWhenNoneConfigured() async throws {
    let root = try makeTempDir()
    let engine = MockEngine()
    let (agent, _) = makeAgent(root: root, engine: engine)
    let session = try await agent.createSession(request: NewSessionRequest(
        cwd: root.path, mcpServers: []))
    _ = try await agent.handlePrompt(
        request: PromptRequest(
            sessionId: session.sessionId, prompt: [.text(TextContent(text: "hi"))]),
        context: StubContext(sessionId: session.sessionId))
    #expect(await engine.lastInstructions?.contains("could not be connected") == false)
}

@Test func historyCorruptRetriesFresh() async throws {
    let root = try makeTempDir()
    let engine = MockEngine()
    await engine.setChunks(["recovered"])
    await engine.setHistoryCorruptOnce()
    let (agent, _) = makeAgent(root: root, engine: engine)
    let session = try await agent.createSession(request: NewSessionRequest(
        cwd: root.path, mcpServers: []))

    let response = try await agent.handlePrompt(
        request: PromptRequest(
            sessionId: session.sessionId, prompt: [.text(TextContent(text: "hi"))]),
        context: StubContext(sessionId: session.sessionId))
    #expect(response.stopReason == .endTurn)
    let calls = await engine.calls
    #expect(calls.count == 2)
    #expect(calls[1].history == nil)
}

@Test func createSessionAdvertisesModelOption() async throws {
    let root = try makeTempDir()
    let (agent, _) = makeAgent(root: root, engine: MockEngine())
    let response = try await agent.createSession(request: NewSessionRequest(
        cwd: root.path, mcpServers: []))
    #expect(response.configOptions?.count == 1)
    guard case .select(let id, _, _, let category, let select, _) =
        response.configOptions?.first
    else {
        Issue.record("expected select config option")
        return
    }
    #expect(id == SessionModelOption.id)
    #expect(category == .model)
    #expect(select.currentValue == SessionModelOption.onDevice)
}

@Test func setModelOptionRoundTrip() async throws {
    let root = try makeTempDir()
    let (agent, store) = makeAgent(root: root, engine: MockEngine())
    let session = try await agent.createSession(request: NewSessionRequest(
        cwd: root.path, mcpServers: []))

    let response = try await agent.setSessionConfigOption(
        request: SetSessionConfigOptionRequest(
            sessionId: session.sessionId, configId: SessionModelOption.id,
            value: .valueId(SessionModelOption.onDevice)))
    #expect(response.configOptions.count == 1)

    // Selection is persisted across store instances.
    let reopened = SessionStore(root: root)
    let meta = try await reopened.session(for: session.sessionId).meta
    #expect(meta.modelValue == SessionModelOption.onDevice.rawValue)
    _ = store
}

@Test func setModelOptionOpensSessionFromDisk() async throws {
    // A fresh store (new process) with nothing cached must still accept the
    // valid value by opening the session from disk.
    let root = try makeTempDir()
    let seeder = SessionStore(root: root)
    let id = try await seeder.create(cwd: root.path, additionalDirectories: nil, mcpServers: [])

    let agent = FoundationModelsAgent(store: SessionStore(root: root), engine: MockEngine())
    let response = try await agent.setSessionConfigOption(
        request: SetSessionConfigOptionRequest(
            sessionId: id, configId: SessionModelOption.id,
            value: .valueId(SessionModelOption.onDevice)))
    #expect(response.configOptions.count == 1)
}

@Test func setModelOptionRejects() async throws {
    let root = try makeTempDir()
    let (agent, _) = makeAgent(root: root, engine: MockEngine())
    let session = try await agent.createSession(request: NewSessionRequest(
        cwd: root.path, mcpServers: []))

    await #expect(throws: AgentError.self) {
        try await agent.setSessionConfigOption(
            request: SetSessionConfigOptionRequest(
                sessionId: session.sessionId, configId: "nope",
                value: .valueId(SessionModelOption.onDevice)))
    }
    await #expect(throws: AgentError.self) {
        try await agent.setSessionConfigOption(
            request: SetSessionConfigOptionRequest(
                sessionId: session.sessionId, configId: SessionModelOption.id,
                value: .valueId("gpt-99")))
    }
    await #expect(throws: AgentError.sessionNotFound(SessionId("nope"))) {
        try await agent.setSessionConfigOption(
            request: SetSessionConfigOptionRequest(
                sessionId: SessionId("nope"), configId: SessionModelOption.id,
                value: .valueId(SessionModelOption.onDevice)))
    }
}

@Test func loadSessionReplaysHistory() async throws {
    let root = try makeTempDir()
    let engine = MockEngine()
    await engine.setChunks(["answer"])
    let (agent, _) = makeAgent(root: root, engine: engine)
    let session = try await agent.createSession(request: NewSessionRequest(
        cwd: root.path, mcpServers: []))
    _ = try await agent.handlePrompt(
        request: PromptRequest(
            sessionId: session.sessionId, prompt: [.text(TextContent(text: "question"))]),
        context: StubContext(sessionId: session.sessionId))

    let replay = StubContext(sessionId: session.sessionId)
    _ = try await agent.loadSession(
        request: LoadSessionRequest(
            sessionId: session.sessionId, cwd: root.path, mcpServers: []),
        context: replay)
    let kinds = replay.updates.map { update -> String in
        switch update {
        case .userMessageChunk: return "user"
        case .agentMessageChunk: return "agent"
        default: return "other"
        }
    }
    #expect(kinds == ["user", "agent"])
}

@Test func loadSessionReturnsModelOption() async throws {
    let root = try makeTempDir()
    let (agent, _) = makeAgent(root: root, engine: MockEngine())
    let session = try await agent.createSession(request: NewSessionRequest(
        cwd: root.path, mcpServers: []))
    let response = try await agent.loadSession(
        request: LoadSessionRequest(
            sessionId: session.sessionId, cwd: root.path, mcpServers: []),
        context: StubContext(sessionId: session.sessionId))
    #expect(response.configOptions?.count == 1)
}

@Test func createSessionRejectsBadCwd() async throws {
    let root = try makeTempDir()
    let engine = MockEngine()
    let (agent, _) = makeAgent(root: root, engine: engine)
    await #expect(throws: AgentError.self) {
        try await agent.createSession(request: NewSessionRequest(
            cwd: "/does/not/exist", mcpServers: []))
    }
}

@Test func closeAndDeleteLifecycle() async throws {
    let root = try makeTempDir()
    let engine = MockEngine()
    let (agent, _) = makeAgent(root: root, engine: engine)
    let session = try await agent.createSession(request: NewSessionRequest(
        cwd: root.path, mcpServers: []))
    _ = try await agent.closeSession(request: CloseSessionRequest(sessionId: session.sessionId))
    let listed = try await agent.listSessions(request: ListSessionsRequest())
    #expect(listed.sessions.count == 1)
    _ = try await agent.deleteSession(
        request: DeleteSessionRequest(sessionId: session.sessionId))
    let listed2 = try await agent.listSessions(request: ListSessionsRequest())
    #expect(listed2.sessions.isEmpty)
}

@Test func agentCapabilities() async throws {
    let root = try makeTempDir()
    let (agent, _) = makeAgent(root: root, engine: MockEngine())
    #expect(agent.capabilities.loadSession == true)
    #expect(agent.capabilities.promptCapabilities.image == true)
    #expect(agent.capabilities.promptCapabilities.audio == false)
    #expect(agent.info?.name == "fmagent")
}
