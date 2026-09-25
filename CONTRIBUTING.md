# Contributing to fmagent

## Setup

- Xcode 27+ on macOS 27+, Swift 6.4.
- No other setup; dependencies resolve via SwiftPM.

## Commands

```sh
swift build          # debug binary -> .build/debug/fmagent
swift build -c release
swift test           # full suite (no Apple Intelligence needed; FM is mocked)
```

`swift test` must stay green without Apple Intelligence. Anything touching
`FoundationModelsEngine` directly needs an availability guard or a mock.

## Conventions

- Swift 6 strict concurrency throughout (`ApproachableConcurrency` is on).
  Everything crossing tasks is `Sendable`; shared mutable state lives in
  actors (`SessionStore`, `PermissionPolicy`, `MCPClientManager`).
- Never use `NSLock.lock()`/`unlock()` in async contexts (Swift 6 forbids it);
  use `lock.withLock { }`. Prefer actors for new shared state.
- **Stdout is protocol traffic.** All logging goes to stderr
  (`StreamLogHandler.standardError`, already wired in `fmagent.swift`).
  Never `print()` from the agent target.
- ACP wire types come from ACPKit — do not redefine them. Error mapping:
  bad input → `AgentError.invalidParams`, unknown session →
  `AgentError.sessionNotFound`, model/backend failures →
  `AgentError.internalError` (or the matching `StopReason` for generation
  outcomes).
- Tools report via `toolCall` (`in_progress`) → `toolCallUpdate`
  (`completed`/`failed`) on the request's `AgentContext`, best-effort
  (`try?`); permission is a *request* and must be awaited, never swallowed.
- Tool denials and errors return as **tool output text** (e.g.
  `"permission denied by user"`) so the model can react — don't throw
  through the tool boundary except on cancellation.
- Persistence: extend `SessionMeta` with defaulted fields so old `meta.json`
  files keep decoding; writes must stay atomic (see `writeAtomically`).
  `close` keeps files, `delete` removes the directory.

## Adding a tool

1. Define `@Generable` args + a `struct …: Tool` in `Tools/` holding the
   request's `any AgentContext` (and `PermissionPolicy` if approval-gated).
2. Construct it per-prompt in `FoundationModelsEngine.makeTools` (tools are
   rebuilt every prompt — never cache a tool across requests).
3. Cover it in `Tests/fmagentTests/ToolTests.swift` with `StubContext`:
   happy path, denial path, and the `toolCall` update sequence.

## MCP changes

MCP wire code lives in ACPKit (`Sources/ACPKit/MCP/`), not here. This repo
only owns the FM-facing bridge (`Tools/MCPTool.swift`). If the bridge needs
protocol behavior ACPKit lacks, add it in ACPKit with its own tests.

## Smoke test (real binary, mocked client)

```sh
( printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{},"terminal":false}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}' \
  ; sleep 3 ) | .build/debug/fmagent --sessions-dir "$(mktemp -d)"
```

The `sleep` matters: stdin must stay open while the reader starts (piping
with immediate EOF can exit before any message is processed). The same
applies to `session/prompt` smoke tests (allow ~60s for on-device inference).

## End-to-end harness (`Tests/harness.sh`)

Unit tests mock the engine and the client, so client-visible hangs never
reproduce there. The harness drives the real binary over stdio ND-JSON
with scripted requests (bash + coreutils only, no extra dependencies)
and asserts one JSON-RPC response per request id:

1. `initialize` negotiates the protocol version.
2. `session/new` (no MCP) returns a session id.
3. `session/new` with a fake MCP server that answers 35 s late (simulated
   user approval): must return promptly without tools, and the abandoned
   dial must be adopted once the server answers.
4. First prompt completes with streaming `session/update` notifications.
5. Second prompt on the same session completes (regression: prompt hangs).

Run it with `./Tests/harness.sh` (~3–5 min, hermetic temp dirs). The
prompt scenarios need Apple Intelligence; without it they SKIP instead
of failing. Any failure dumps the agent `--log-file` tail plus the
unanswered request id. Set `HARNESS_KEEP_TMP=1` to keep the temp dir
(binary log, sessions, fake server) for post-mortems.
