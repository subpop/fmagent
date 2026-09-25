# fmagent

An [Agent Client Protocol (ACP)](https://agentclientprotocol.com/) agent that
answers with Apple Foundation Models (on-device inference). It speaks ACP over
stdio, so any ACP-compatible client (editor, IDE harness, test driver) can
spawn it as a subprocess and drive coding sessions.

Backing ACP layer: [`ACPKit`](https://github.com/subpop/ACPKit) (local path
dependency; will move to a git URL later). MCP tool fan-out is provided by
ACPKit's MCP client.

## Requirements

- macOS 27+ (Foundation Models image attachments require the macOS 27 SDK)
- Xcode 27+, Swift 6.4
- Apple Intelligence enabled (on-device model must be available; check with
  `SystemLanguageModel.default.isAvailable`)

## Build & test

```sh
swift build
swift test
```

The binary lands at `.build/<config>/fmagent`.

End-to-end driver (real binary over stdio, needs Apple Intelligence for
the prompt scenarios — they skip without it):

```sh
Tests/harness.sh   # ~3-5 min: initialize, session/new, late MCP server
                   # with adoption check, two streaming prompts
```

## Run

```sh
# Serve ACP over stdio (stdout is protocol traffic; logs go to stderr)
.build/debug/fmagent

# Custom session storage / verbose logging
.build/debug/fmagent --sessions-dir ~/.local/share/fmagent/sessions --debug
```

Minimal smoke test (keep stdin open briefly — see Troubleshooting):

```sh
( printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{},"terminal":false}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}' \
  ; sleep 3 ) | .build/debug/fmagent --sessions-dir "$(mktemp -d)"
```

## Capabilities

Advertised in `initialize`:

| Area | Support |
|---|---|
| Prompt content | text, resource links, embedded text resources, images |
| Prompt content | audio and binary resource blobs are rejected (`-32602`) |
| Tools | `read_file` (no approval), `write_file` + `run_terminal` (user approval via `session/request_permission`, `allow_always` memoized per session) |
| MCP | stdio servers from `session/new` `mcpServers`, exposed as one `mcp_call` tool (same approval policy as terminal). HTTP/SSE servers are skipped until ACPKit gains an HTTP transport |
| Sessions | create / load / list / close / delete, persisted across restarts |
| Model option | single-entry `model` select (`on-device`), changeable via `session/set_config_option` |

## Sessions & persistence

Sessions live under `~/.local/share/fmagent/sessions/<sessionId>/`
(override with `--sessions-dir`):

- `meta.json` — cwd, MCP server config, replay log, permission memo, model selection
- `transcript.json` — encoded Foundation Models transcript, restored on load

`close` keeps files; `delete` removes the directory. Each prompt rebuilds the
`LanguageModelSession` from the persisted transcript plus freshly-built tools,
so restore, MCP changes, and per-request client contexts share one code path.

## Layout

```
Sources/fmagent/
  fmagent.swift              # CLI entry (AsyncParsableCommand), stderr logging
  AgentLogging.swift         # --log-file tee + log bootstrap
  FoundationModelsAgent.swift # Agent protocol implementation
  FoundationModelsEngine.swift # InferenceEngine on Foundation Models
  InferenceEngine.swift      # Backend seam (mocked in tests)
  PromptConverter.swift      # ACP ContentBlock -> text + images
  SessionModelOption.swift   # Single-entry model config option
  SessionStore.swift         # Actor: lifecycle + atomic on-disk persistence
  Tools/
    BuiltInTools.swift       # read_file / write_file / run_terminal
    MCPTool.swift            # mcp_call dispatcher over ACPKit's MCP client
    Permissions.swift        # PermissionPolicy + approval helper
Tests/fmagentTests/          # Unit tests (mock engine + stub client context)
Tests/harness.sh             # End-to-end driver: real binary over stdio ND-JSON
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for development conventions and
[AGENTS.md](AGENTS.md) for the agent-oriented repo guide.
