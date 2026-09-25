import ACPKit
import Foundation
import FoundationModels

// MARK: - read_file

@Generable
struct ReadFileArgs {
    @Guide(description: "Absolute path, or relative to the session working directory.")
    var path: String
    @Guide(description: "1-based first line to read. Omit to start at the beginning.")
    var line: Int?
    @Guide(description: "Maximum number of lines to read. Omit for the whole file.")
    var limit: Int?
}

struct ReadFileTool: Tool, Sendable {
    typealias Arguments = ReadFileArgs
    typealias Output = String

    let name = "read_file"
    let description =
        "Read a text file through the connected client. Prefer this over terminal commands for viewing file content."

    let context: any AgentContext

    @concurrent
    func call(arguments: ReadFileArgs) async throws -> String {
        let toolCallId = ToolCallId(UUID().uuidString)
        let title = "Read \(arguments.path)"
        try? await context.sendUpdate(
            .toolCall(
                ToolCall(
                    toolCallId: toolCallId, title: title, kind: .read, status: .inProgress)))

        do {
            let content = try await context.readTextFile(
                path: arguments.path,
                line: arguments.line.map { UInt32(max($0, 0)) },
                limit: arguments.limit.map { UInt32(max($0, 0)) }
            )
            try? await context.sendUpdate(
                .toolCallUpdate(
                    ToolCallUpdate(
                        toolCallId: toolCallId, status: .completed,
                        content: [.content(.text(TextContent(text: content)))])))
            return content
        } catch {
            try? await context.sendUpdate(
                .toolCallUpdate(
                    ToolCallUpdate(
                        toolCallId: toolCallId, status: .failed)))
            return "error reading file: \(error.localizedDescription)"
        }
    }
}

// MARK: - write_file

@Generable
struct WriteFileArgs {
    @Guide(description: "Absolute path, or relative to the session working directory.")
    var path: String
    @Guide(description: "Complete new content of the file.")
    var content: String
}

struct WriteFileTool: Tool, Sendable {
    typealias Arguments = WriteFileArgs
    typealias Output = String

    let name = "write_file"
    let description =
        "Create or overwrite a text file through the connected client. Requires user permission."

    let context: any AgentContext
    let policy: PermissionPolicy

    @concurrent
    func call(arguments: WriteFileArgs) async throws -> String {
        let toolCallId = ToolCallId(UUID().uuidString)
        let title = "Write \(arguments.path)"
        try? await context.sendUpdate(
            .toolCall(
                ToolCall(
                    toolCallId: toolCallId, title: title, kind: .edit, status: .inProgress)))

        let finish: (ToolCallStatus, String) async -> String = { status, output in
            try? await self.context.sendUpdate(
                .toolCallUpdate(
                    ToolCallUpdate(
                        toolCallId: toolCallId, status: status)))
            return output
        }

        let allowed: Bool
        do {
            allowed = try await PermissionGate.requestToolPermission(
                context: context, policy: policy, key: "write_file",
                toolCallId: toolCallId, title: title, kind: .edit)
        } catch {
            return await finish(
                .failed, "error requesting permission: \(error.localizedDescription)")
        }
        guard allowed else {
            return await finish(.failed, "permission denied by user")
        }

        do {
            try await context.writeTextFile(path: arguments.path, content: arguments.content)
            try? await context.sendUpdate(
                .toolCallUpdate(
                    ToolCallUpdate(
                        toolCallId: toolCallId, status: .completed,
                        content: [
                            .diff(path: arguments.path, newText: arguments.content, oldText: nil)
                        ])))
            return "wrote \(arguments.content.utf8.count) bytes to \(arguments.path)"
        } catch {
            return await finish(.failed, "error writing file: \(error.localizedDescription)")
        }
    }
}

// MARK: - run_terminal

@Generable
struct RunTerminalArgs {
    @Guide(description: "Executable to run, e.g. 'rg' or '/bin/ls'.")
    var command: String
    @Guide(description: "Arguments. Omit for none.")
    var args: [String]?
    @Guide(description: "Working directory. Omit for the session working directory.")
    var cwd: String?
    @Guide(description: "Seconds to wait before killing the command. Omit for 60.")
    var timeoutSeconds: Double?
}

private enum TerminalTimeout: Error {
    case timedOut
}

struct RunTerminalTool: Tool, Sendable {
    typealias Arguments = RunTerminalArgs
    typealias Output = String

    let name = "run_terminal"
    let description =
        "Execute a command in the client's terminal (searching, listing files, running builds and tests). Requires user permission. Prefer the read_file tool for viewing file content."

    let context: any AgentContext
    let policy: PermissionPolicy
    let sessionCwd: String

    @concurrent
    func call(arguments: RunTerminalArgs) async throws -> String {
        let toolCallId = ToolCallId(UUID().uuidString)
        let title = "Run \(( [arguments.command] + (arguments.args ?? []) ).joined(separator: " "))"
        try? await context.sendUpdate(
            .toolCall(
                ToolCall(
                    toolCallId: toolCallId, title: title, kind: .execute, status: .inProgress)))

        let finish: (ToolCallStatus, String) async -> String = { status, output in
            try? await self.context.sendUpdate(
                .toolCallUpdate(
                    ToolCallUpdate(
                        toolCallId: toolCallId, status: status)))
            return output
        }

        let allowed: Bool
        do {
            allowed = try await PermissionGate.requestToolPermission(
                context: context, policy: policy, key: "run_terminal",
                toolCallId: toolCallId, title: title, kind: .execute)
        } catch {
            return await finish(
                .failed, "error requesting permission: \(error.localizedDescription)")
        }
        guard allowed else {
            return await finish(.failed, "permission denied by user")
        }

        let terminalId: TerminalId
        do {
            terminalId = try await context.createTerminal(
                command: arguments.command,
                args: arguments.args,
                env: nil,
                cwd: arguments.cwd ?? sessionCwd,
                outputByteLimit: nil
            )
        } catch {
            return await finish(.failed, "error creating terminal: \(error.localizedDescription)")
        }
        try? await context.sendUpdate(
            .toolCallUpdate(
                ToolCallUpdate(
                    toolCallId: toolCallId, status: .inProgress,
                    content: [.terminal(terminalId: terminalId)])))

        let timeout = arguments.timeoutSeconds ?? 60
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await self.context.waitForTerminalExit(terminalId: terminalId)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(timeout, 1) * 1_000_000_000))
                    throw TerminalTimeout.timedOut
                }
                try await group.next()
                group.cancelAll()
            }
        } catch is CancellationError {
            try? await context.killTerminal(terminalId: terminalId)
            try? await context.releaseTerminal(terminalId: terminalId)
            throw CancellationError()
        } catch {
            try? await context.killTerminal(terminalId: terminalId)
            let partial = (try? await context.terminalOutput(terminalId: terminalId))?.output ?? ""
            try? await context.releaseTerminal(terminalId: terminalId)
            return await finish(
                .failed,
                "command timed out after \(Int(timeout))s and was killed. Partial output:\n\(partial)"
            )
        }

        do {
            let output = try await context.terminalOutput(terminalId: terminalId)
            try? await context.releaseTerminal(terminalId: terminalId)
            var result = output.output
            if output.truncated {
                result += "\n[output truncated by client]"
            }
            if let exit = output.exitStatus?.exitCode, exit != 0 {
                return await finish(.failed, "exit code \(exit):\n\(result)")
            }
            return await finish(.completed, result.isEmpty ? "(no output)" : result)
        } catch {
            try? await context.releaseTerminal(terminalId: terminalId)
            return await finish(
                .failed, "error reading terminal output: \(error.localizedDescription)")
        }
    }
}
