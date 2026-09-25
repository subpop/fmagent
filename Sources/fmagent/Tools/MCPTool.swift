import ACPKit
import Foundation
import FoundationModels

@Generable
struct MCPCallArgs {
    @Guide(description: "Server-qualified tool name from the catalog, e.g. 'myserver__read_file'.")
    var tool: String
    @Guide(
        description:
            "JSON object string of tool arguments, e.g. '{\"path\": \"/tmp/x\"}'. Use '{}' when the tool takes no arguments."
    )
    var argumentsJson: String?
}

/// Bridges every MCP tool discovered for the session through a single
/// model-facing tool. Per-tool dynamic schemas are intentionally avoided:
/// the catalog (names, descriptions, JSON schemas) is embedded in the tool
/// description and arguments travel as a JSON string, which is robust to
/// arbitrary MCP input schemas.
struct MCPDispatcherTool: Tool, Sendable {
    typealias Arguments = MCPCallArgs
    typealias Output = String

    let name = "mcp_call"
    let description: String

    let context: any AgentContext
    let policy: PermissionPolicy
    let manager: MCPClientManager
    let catalog: [MCPNamespacedTool]

    init(
        context: any AgentContext,
        policy: PermissionPolicy,
        manager: MCPClientManager,
        catalog: [MCPNamespacedTool]
    ) {
        self.context = context
        self.policy = policy
        self.manager = manager
        self.catalog = catalog

        var lines = [
            "Call a tool on a connected MCP server. Requires user permission (same policy as terminal commands). Available tools:"
        ]
        for entry in catalog {
            var line = "- \(entry.qualifiedName)"
            if let description = entry.tool.description, !description.isEmpty {
                line += ": \(description)"
            }
            let schema = entry.tool.inputSchema
            if let data = try? JSONEncoder().encode(schema),
                let text = String(data: data, encoding: .utf8),
                text != "{}"
            {
                line += " Arguments schema: \(text)"
            }
            lines.append(line)
        }
        self.description = lines.joined(separator: "\n")
    }

    @concurrent
    func call(arguments: MCPCallArgs) async throws -> String {
        let toolCallId = ToolCallId(UUID().uuidString)
        let title = "MCP \(arguments.tool)"
        try? await context.sendUpdate(
            .toolCall(
                ToolCall(
                    toolCallId: toolCallId, title: title, kind: .other, status: .inProgress)))

        let finish: (ToolCallStatus, String) async -> String = { status, output in
            try? await self.context.sendUpdate(
                .toolCallUpdate(
                    ToolCallUpdate(
                        toolCallId: toolCallId, status: status)))
            return output
        }

        guard let entry = catalog.first(where: { $0.qualifiedName == arguments.tool }) else {
            return await finish(
                .failed,
                "unknown MCP tool '\(arguments.tool)'. Use a qualified name from the catalog.")
        }

        let key = "mcp::\(entry.qualifiedName)"
        let allowed: Bool
        do {
            allowed = try await PermissionGate.requestToolPermission(
                context: context, policy: policy, key: key,
                toolCallId: toolCallId, title: title, kind: .other)
        } catch {
            return await finish(
                .failed, "error requesting permission: \(error.localizedDescription)")
        }
        guard allowed else {
            return await finish(.failed, "permission denied by user")
        }

        let jsonArguments: [String: JSONValue]?
        do {
            jsonArguments = try Self.parseArguments(arguments.argumentsJson)
        } catch {
            return await finish(
                .failed, "argumentsJson is not a JSON object: \(error.localizedDescription)")
        }

        do {
            let result = try await manager.callTool(
                serverName: entry.serverName, toolName: entry.tool.name,
                arguments: jsonArguments
            )
            let text = result.combinedText
            if result.isError {
                return await finish(.failed, "MCP tool reported an error:\n\(text)")
            }
            return await finish(.completed, text.isEmpty ? "(no output)" : text)
        } catch {
            return await finish(.failed, "error calling MCP tool: \(error.localizedDescription)")
        }
    }

    static func parseArguments(_ json: String?) throws -> [String: JSONValue]? {
        guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let data = json.data(using: .utf8) else {
            throw MCPToolArgumentError.notUTF8
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let object) = value else {
            throw MCPToolArgumentError.notAnObject
        }
        return object
    }
}

enum MCPToolArgumentError: Error {
    case notUTF8
    case notAnObject
}
