import ACPKit
import Foundation
import Testing

@testable import fmagent

private func fullCapabilities() -> ClientCapabilities {
    ClientCapabilities(fs: FileSystemCapabilities(readTextFile: true, writeTextFile: true))
}

@Test func mcpToolArgumentParsing() throws {
    #expect(try MCPDispatcherTool.parseArguments(nil) == nil)
    #expect(try MCPDispatcherTool.parseArguments("") == nil)
    #expect(try MCPDispatcherTool.parseArguments("{}") == [:])
    let parsed = try MCPDispatcherTool.parseArguments("{\"a\": 1, \"b\": \"x\"}")
    #expect(parsed?["a"] == .number(1))
    #expect(parsed?["b"] == .string("x"))
    #expect(throws: (any Error).self) {
        try MCPDispatcherTool.parseArguments("[1, 2]")
    }
    #expect(throws: (any Error).self) {
        try MCPDispatcherTool.parseArguments("{oops")
    }
}

@Test func readToolReturnsFileContent() async throws {
    let context = StubContext(clientCapabilities: fullCapabilities())
    context.setFile(path: "/a.txt", content: "file-body")
    let tool = ReadFileTool(context: context)
    let out = try await tool.call(arguments: ReadFileArgs(path: "/a.txt", line: nil, limit: nil))
    #expect(out == "file-body")
    #expect(context.toolCallKinds() == [.read])
}

@Test func writeToolGatesOnPermission() async throws {
    // Allowed path.
    let context = StubContext(clientCapabilities: fullCapabilities())
    let policy = PermissionPolicy()
    let tool = WriteFileTool(context: context, policy: policy)
    let out = try await tool.call(
        arguments: WriteFileArgs(path: "/w.txt", content: "new"))
    #expect(out.contains("wrote"))
    #expect(context.written.map(\.path) == ["/w.txt"])

    // Denied path.
    let denied = StubContext(clientCapabilities: fullCapabilities())
    denied.setOutcome(.selected(optionId: "reject-once", meta: nil))
    let tool2 = WriteFileTool(context: denied, policy: PermissionPolicy())
    let out2 = try await tool2.call(
        arguments: WriteFileArgs(path: "/w.txt", content: "new"))
    #expect(out2 == "permission denied by user")
    #expect(denied.written.isEmpty)
}

@Test func allowAlwaysIsMemoized() async throws {
    let context = StubContext(clientCapabilities: fullCapabilities())
    context.setOutcome(.selected(optionId: "allow-always", meta: nil))
    let policy = PermissionPolicy()
    let allowed = try await PermissionGate.requestToolPermission(
        context: context, policy: policy, key: "run_terminal",
        toolCallId: "t1", title: "Run x", kind: .execute)
    #expect(allowed)
    // Second request with a denying client still passes via memoization.
    context.setOutcome(.selected(optionId: "reject-once", meta: nil))
    let allowed2 = try await PermissionGate.requestToolPermission(
        context: context, policy: policy, key: "run_terminal",
        toolCallId: "t2", title: "Run y", kind: .execute)
    #expect(allowed2)
    #expect(context.permissionRequests.count == 1)
}

@Test func silentPermissionClientTimesOut() async throws {
    let context = StubContext(clientCapabilities: fullCapabilities())
    context.setPermissionHang()
    await #expect(
        throws: PermissionTimeoutError.timedOut(toolKey: "run_terminal", timeoutSeconds: 1)
    ) {
        try await PermissionGate.requestToolPermission(
            context: context, policy: PermissionPolicy(), key: "run_terminal",
            toolCallId: "t1", title: "Run x", kind: .execute, timeout: 1)
    }
}

@Test func terminalToolRunsAndReleases() async throws {
    let capabilities = ClientCapabilities(
        fs: FileSystemCapabilities(), terminal: true)
    let context = StubContext(clientCapabilities: capabilities)
    context.setTerminalOutput("build ok")
    let tool = RunTerminalTool(
        context: context, policy: PermissionPolicy(), sessionCwd: "/work")
    let out = try await tool.call(arguments: RunTerminalArgs(
        command: "make", args: ["all"], cwd: nil, timeoutSeconds: 5))
    #expect(out == "build ok")
    #expect(context.terminalsCreated.map(\.command) == ["make"])
    #expect(context.terminalsReleased == 1)
}
