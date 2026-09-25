import ACPKit
import CoreImage
import Foundation
import FoundationModels

/// ``InferenceEngine`` backed by Apple Foundation Models.
///
/// Sessions are stateless: every prompt rebuilds a `LanguageModelSession`
/// from the persisted transcript plus freshly-constructed tools bound to the
/// current ``AgentContext``. This makes session restore, MCP tool-set changes,
/// and per-request contexts share a single code path.
struct FoundationModelsEngine: InferenceEngine, Sendable {
    init() {}

    func respond(
        history: Data?,
        instructions: String,
        prompt: ConvertedPrompt,
        tools: EngineTools,
        onText: @Sendable @escaping (String) async throws -> Void
    ) async throws -> EngineOutcome {
        guard SystemLanguageModel.default.isAvailable else {
            throw AgentError.internalError(
                "Apple Foundation Models are unavailable: \(availabilityReason())")
        }

        let fmTools = makeTools(tools)
        let session: LanguageModelSession
        if let history {
            let transcript: Transcript
            do {
                transcript = try JSONDecoder().decode(Transcript.self, from: history)
            } catch {
                throw EngineError.historyCorrupt("\(error)")
            }
            session = LanguageModelSession(
                model: SystemLanguageModel.default, tools: fmTools, transcript: transcript)
        } else {
            session = LanguageModelSession(
                model: SystemLanguageModel.default, tools: fmTools,
                instructions: instructions)
        }

        let fmPrompt = try makePrompt(prompt)

        var accumulated = ""
        do {
            let stream = session.streamResponse(to: fmPrompt)
            for try await snapshot in stream {
                try Task.checkCancellation()
                let text = snapshot.content
                let delta = deltaSince(accumulated, text)
                if !delta.isEmpty {
                    try await onText(delta)
                }
                accumulated = text
            }
        } catch let error as LanguageModelError {
            // Persist whatever the session holds so a retry keeps context.
            let transcriptData =
                (try? JSONEncoder().encode(session.transcript))
                ?? history
                ?? Data()
            switch error {
            case .contextSizeExceeded:
                return EngineOutcome(
                    transcript: transcriptData, responseText: accumulated,
                    stopReason: .maxTokens)
            case .guardrailViolation, .refusal:
                return EngineOutcome(
                    transcript: transcriptData, responseText: accumulated,
                    stopReason: .refusal)
            default:
                throw AgentError.internalError(
                    "Language model error: \(error.localizedDescription)")
            }
        }

        let transcriptData = try JSONEncoder().encode(session.transcript)
        return EngineOutcome(
            transcript: transcriptData, responseText: accumulated, stopReason: .endTurn)
    }

    // MARK: - Tools

    private func makeTools(_ tools: EngineTools) -> [any FoundationModels.Tool] {
        var fmTools: [any FoundationModels.Tool] = [
            ReadFileTool(context: tools.context),
            WriteFileTool(context: tools.context, policy: tools.policy),
            RunTerminalTool(
                context: tools.context, policy: tools.policy, sessionCwd: tools.sessionCwd),
        ]
        if !tools.mcpTools.isEmpty {
            fmTools.append(
                MCPDispatcherTool(
                    context: tools.context, policy: tools.policy,
                    manager: tools.mcpManager, catalog: tools.mcpTools))
        }
        return fmTools
    }

    // MARK: - Prompt

    private func makePrompt(_ prompt: ConvertedPrompt) throws -> Prompt {
        var parts: [Prompt] = [Prompt(prompt.text)]
        for image in prompt.images {
            guard image.mimeType.lowercased().hasPrefix("image/") else {
                throw AgentError.invalidParams(
                    "Unsupported image MIME type: \(image.mimeType)")
            }
            guard let ciImage = CIImage(data: image.data) else {
                throw AgentError.invalidParams("Image content could not be decoded")
            }
            parts.append(Attachment(ciImage).promptRepresentation)
        }
        return Prompt(parts)
    }

    /// Suffix of `current` not yet sent, tolerating non-monotonic updates.
    private func deltaSince(_ sent: String, _ current: String) -> String {
        if current.hasPrefix(sent) {
            return String(current.dropFirst(sent.count))
        }
        return current
    }

    private func availabilityReason() -> String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "reported available but inference failed the pre-check"
        case .unavailable(let reason):
            return "\(reason)"
        }
    }
}
