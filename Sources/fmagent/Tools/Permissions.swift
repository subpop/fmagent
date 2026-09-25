import ACPKit
import Foundation
import Logging

/// Per-session permission memoization for `allow_always` outcomes.
///
/// Owned by ``SessionStore`` (one instance per open session, seeded from
/// persisted `meta.json` and snapshotted back after each prompt). Tools consult
/// it before sending `session/request_permission`.
public actor PermissionPolicy {
    private var alwaysAllowed: Set<String>

    public init(alwaysAllowed: Set<String> = []) {
        self.alwaysAllowed = alwaysAllowed
    }

    public func isAllowed(_ key: String) -> Bool {
        alwaysAllowed.contains(key)
    }

    public func grantAlways(_ key: String) {
        alwaysAllowed.insert(key)
    }

    public func snapshot() -> Set<String> {
        alwaysAllowed
    }
}

public enum PermissionGate {
    private static let logger = Logger(label: "fmagent.PermissionGate")

    /// Returns `true` when the tool may proceed.
    ///
    /// `allow_always` grants are memoized in `policy` under `key`. Denials and
    /// cancellations return `false` (callers surface them as tool output text
    /// so the model can react, rather than throwing).
    ///
    /// - Parameter timeout: maximum time to wait for the client to answer.
    ///   Generous by default (a human may be deciding), but finite: a client
    ///   that never answers would otherwise hang the prompt forever. Expiry
    ///   throws ``PermissionTimeoutError/timedOut``, which callers already
    ///   surface as tool output text. Prompt unblocking on timeout relies on
    ///   the context failing the in-flight request when its task is
    ///   cancelled (true of ACPKit's context).
    public static func requestToolPermission(
        context: any AgentContext,
        policy: PermissionPolicy,
        key: String,
        toolCallId: ToolCallId,
        title: String,
        kind: ToolKind,
        timeout: TimeInterval = 120
    ) async throws -> Bool {
        if await policy.isAllowed(key) {
            return true
        }

        let allowOnce = PermissionOption(
            optionId: "allow-once", name: "Allow once", kind: .allowOnce)
        let allowAlways = PermissionOption(
            optionId: "allow-always", name: "Allow always for this session", kind: .allowAlways)
        let rejectOnce = PermissionOption(
            optionId: "reject-once", name: "Reject", kind: .rejectOnce)

        let seconds = Int(max(timeout, 1))
        logger.debug(
            "permission requested", metadata: ["key": "\(key)", "title": "\(title)"])
        let outcome = try await withThrowingTaskGroup(of: RequestPermissionOutcome.self) {
            group in
            group.addTask {
                try await context.requestPermission(
                    toolCall: ToolCallUpdate(
                        toolCallId: toolCallId, kind: kind, status: .inProgress, title: title),
                    options: [allowOnce, allowAlways, rejectOnce]
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw PermissionTimeoutError.timedOut(toolKey: key, timeoutSeconds: seconds)
            }
            guard let first = try await group.next() else {
                throw PermissionTimeoutError.timedOut(toolKey: key, timeoutSeconds: seconds)
            }
            group.cancelAll()
            return first
        }
        logger.debug(
            "permission answered",
            metadata: ["key": "\(key)", "outcome": "\(outcome)"])

        switch outcome {
        case .cancelled:
            return false
        case .selected(let optionId, _):
            if optionId == allowAlways.optionId {
                await policy.grantAlways(key)
                return true
            }
            return optionId == allowOnce.optionId
        }
    }
}

/// Thrown when the client does not answer a permission request before
/// ``PermissionGate/requestToolPermission``'s timeout. Callers surface it as
/// tool output text (like other permission-channel errors) so the model can
/// retry the tool or work around the denial.
public enum PermissionTimeoutError: Error, Sendable, Equatable {
    case timedOut(toolKey: String, timeoutSeconds: Int)
}

extension PermissionTimeoutError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .timedOut(let toolKey, let timeoutSeconds):
            return "Permission request for '\(toolKey)' timed out after \(timeoutSeconds)s without a client response"
        }
    }
}
