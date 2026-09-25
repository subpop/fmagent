# AGENTS.md — fmagent

Repo guide for coding agents working in `fmagent`.

## What this is

ACP agent binary (`fmagent`) + unit tests. Backing protocol layer is
[`ACPKit`](https://github.com/subpop/ACPKit). `fmagent` owns: CLI entry, `Agent`
implementation, Foundation Models inference, tools, session persistence.
ACP/MCP wire code lives in ACPKit — don't duplicate it here.

## Commands

```sh
swift build          # .build/debug/fmagent
swift test           # must pass without Apple Intelligence
```

## Architecture (read in this order)

1. `Sources/fmagent/fmagent.swift` — entry: stdio transport + `AgentConnection`.
2. `Sources/fmagent/FoundationModelsAgent.swift` — request handlers.
3. `Sources/fmagent/SessionStore.swift` — session actor + `meta.json`/`transcript.json`.
4. `Sources/fmagent/FoundationModelsEngine.swift` + `InferenceEngine.swift` — FM seam.
5. `Sources/fmagent/PromptConverter.swift` — content mapping (audio/blob rejected).
6. `Sources/fmagent/Tools/` — `BuiltInTools.swift`, `MCPTool.swift`, `Permissions.swift`.

Key design facts (don't "fix" these):

- Sessions are **stateless**: `LanguageModelSession` is rebuilt per prompt
  from the persisted transcript + fresh context-bound tools. Never cache FM
  objects or tools across requests.
- `MCPTool.swift` is intentionally a **single generic dispatcher**
  (`mcp_call`, JSON-string args, catalog in description), not per-tool
  schemas — see `MCPTool.swift` header.
- Stdout = JSON-RPC only. Log to stderr. Never add `print()`.
- `close` ≠ `delete`: close drops connections, keeps files.
- MCP dials never block: `create`/reopen/touch return immediately while at
  most one background dial per session runs to completion and adopts its
  tools for later prompts. A silent or approval-gated server delays tools,
  never responses.

## Gotchas

- Platform floor is macOS 27 (FM image attachments); don't lower it.
- `NSLock.lock()/unlock()` is banned in async code — use `withLock`.
- `@testable import fmagent` exposes internals to tests; keep `SessionMeta`
  fields defaulted so old `meta.json` decodes.
- Test fakes: `MockEngine` (actor) + `StubContext` (locked class — actors
  can't satisfy `AgentContext`'s sync getters) in `Tests/fmagentTests/TestingSupport.swift`.
- Smoke tests must hold stdin open (`sleep` after `printf`); immediate EOF
  can exit before the reader starts.
- If behavior needs protocol support ACPKit lacks, implement it in `ACPKit`
  (`Sources/ACPKit/MCP/` for MCP, `Sources/ACPKit/JSONRPC/` for transport) with
  ACPKit-side tests — then consume it here.
