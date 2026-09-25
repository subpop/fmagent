#!/usr/bin/env bash
# End-to-end driver for the fmagent binary over stdio ND-JSON.
#
# Why this exists: unit tests mock the inference engine and the client
# context, so real world hangs (silent MCP servers, second-prompt stalls)
# never reproduce there. This script drives the REAL binary with scripted
# requests and asserts one JSON-RPC response per request id.
#
# Usage: Tests/harness.sh    (run from anywhere; finds the repo root)
# Expect ~3-5 minutes: one 35 s simulated MCP-approval delay plus two
# on-device inference prompts. Requires Apple Foundation Models for the
# prompt scenarios; without them those scenarios SKIP instead of failing.
#
# Exit status: 0 when every scenario passes or skips, 1 on any failure.
# Needs only bash + coreutils (no jq/python): ids are matched textually.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/debug/fmagent"

PASS=0
FAIL=0
SKIP=0
NOTIF_SEEN=0
FOUND_LINE=""

log()  { printf '[harness] %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "ok: $*"; }
fail() { FAIL=$((FAIL + 1)); log "FAIL: $*"; }
skip() { SKIP=$((SKIP + 1)); log "SKIP: $*"; }

T=""
AGENT_PID=""
cleanup() {
    if [ -n "$AGENT_PID" ] && kill -0 "$AGENT_PID" 2>/dev/null; then
        kill "$AGENT_PID" 2>/dev/null
    fi
    exec 3>&- 4<&- 2>/dev/null
    if [ -n "$T" ]; then
        if [ "${HARNESS_KEEP_TMP:-0}" = 1 ]; then
            log "keeping tmp dir for inspection: $T"
        else
            rm -rf "$T"
        fi
    fi
}
trap cleanup EXIT

# --- setup ---------------------------------------------------------------

T="$(mktemp -d "${TMPDIR:-/tmp}/fmagent-harness.XXXXXX")"
REQ="$T/req.fifo"
RESP="$T/resp.fifo"
SESSIONS="$T/sessions"
HARNESS_LOG="$T/fmagent.log"
FAKE="$T/fake-mcp.sh"
mkdir -p "$SESSIONS"
mkfifo "$REQ" "$RESP"

log "building fmagent"
if ! (cd "$ROOT" && swift build 2>&1 | tail -2); then
    fail "swift build failed"
    exit 1
fi
[ -x "$BIN" ] || { fail "binary missing: $BIN"; exit 1; }

# Fake MCP server: answers initialize after $1 seconds (simulating a user
# staring at Xcode's approval dialog), tools/list at once, ignores
# notifications (which carry no id).
#
# NOTE: ACPKit's JSON encoder escapes "/" as "\/", so match bare words
# ("initialize" vs "notifications", "list" vs "call") — never the full
# "tools/list" method string, which never appears unescaped on the wire.
cat > "$FAKE" <<'EOF'
#!/bin/sh
delay="$1"
while IFS= read -r line; do
  case "$line" in
    *notifications*) continue ;;
    *initialize*)
      sleep "$delay"
      id=$(printf '%s' "$line" | sed -n 's/.*"id": *\([0-9][0-9]*\).*/\1/p')
      if [ -n "$id" ]; then
        printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"fakesrv","version":"0.1"}}}\n' "$id"
      fi
      ;;
    *tools*)
      case "$line" in
        *list*)
          id=$(printf '%s' "$line" | sed -n 's/.*"id": *\([0-9][0-9]*\).*/\1/p')
          if [ -n "$id" ]; then
            printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"fake_tool","description":"fake","inputSchema":{"type":"object"}}]}}\n' "$id"
          fi
          ;;
      esac
      ;;
  esac
done
EOF
chmod +x "$FAKE"

log "starting agent (log: $HARNESS_LOG)"
"$BIN" --debug --sessions-dir "$SESSIONS" --log-file "$HARNESS_LOG" \
    <"$REQ" >"$RESP" &
AGENT_PID=$!
exec 3>"$REQ"
exec 4<"$RESP"

# --- rpc helpers ---------------------------------------------------------

rpc_send() { printf '%s\n' "$1" >&3; }

# Wait up to $2 seconds for the response whose "id" is $1. Notifications
# (session/update) are counted in NOTIF_SEEN and skipped. Sets FOUND_LINE.
rpc_await() {
    local id=$1 timeout=$2 start=$SECONDS
    FOUND_LINE=""
    while (( SECONDS - start < timeout )); do
        local line
        if IFS= read -r -t 1 -u 4 line; then
            case "$line" in
                *session/update*|*session\\/update*) NOTIF_SEEN=$((NOTIF_SEEN + 1)) ;;
            esac
            if printf '%s' "$line" | grep -q -F "\"id\":${id},"; then
                FOUND_LINE=$line; return 0
            fi
            if printf '%s' "$line" | grep -q -F "\"id\":${id}}"; then
                FOUND_LINE=$line; return 0
            fi
        fi
    done
    return 1
}

session_id_of() {
    printf '%s' "$1" | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

dump_log() {
    log "--- agent log tail (failure context) ---"
    tail -30 "$HARNESS_LOG" 2>/dev/null || log "(no log file)"
}

# --- scenarios -----------------------------------------------------------

log "== 1. initialize =="
rpc_send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}'
if rpc_await 1 10; then
    case "$FOUND_LINE" in
        *'"protocolVersion":1'*) pass "initialize negotiates protocolVersion 1" ;;
        *) fail "initialize response lacks protocolVersion ($(printf '%s' "$FOUND_LINE" | head -c 200))"; dump_log ;;
    esac
else
    fail "no initialize response within 10s"; dump_log
fi

log "== 2. session/new without MCP =="
mkdir -p "$T/work"
rpc_send '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"'"$T"'/work","mcpServers":[]}}'
SID_PLAIN=""
if rpc_await 2 15; then
    SID_PLAIN="$(session_id_of "$FOUND_LINE")"
    if [ -n "$SID_PLAIN" ]; then
        pass "session/new returns sessionId ($SID_PLAIN)"
    else
        fail "session/new response has no sessionId"; dump_log
    fi
else
    fail "no session/new response within 15s"; dump_log
fi

log "== 3. session/new with 35 s-late MCP server =="
rpc_send '{"jsonrpc":"2.0","id":3,"method":"session/new","params":{"cwd":"'"$T"'/work","mcpServers":[{"name":"slowsrv","command":"'"$FAKE"'","args":["35"],"env":[]}]}}'
SID_SLOW=""
start=$SECONDS
if rpc_await 3 45; then
    elapsed=$((SECONDS - start))
    SID_SLOW="$(session_id_of "$FOUND_LINE")"
    if [ -n "$SID_SLOW" ] && [ "$elapsed" -lt 40 ]; then
        pass "slow session/new returns without tools in ${elapsed}s (id $SID_SLOW)"
    else
        fail "slow session/new wrong (elapsed=${elapsed}s id='$SID_SLOW')"; dump_log
    fi
else
    fail "slow session/new produced no response within 45s (would hang Xcode)"; dump_log
fi

if [ -n "$SID_SLOW" ]; then
    log "== 3b. late MCP adoption =="
    deadline=$((SECONDS + 60))
    adopted=0
    while (( SECONDS < deadline )); do
        if grep -q "late connect adopted" "$HARNESS_LOG" 2>/dev/null; then
            adopted=1; break
        fi
        sleep 2
    done
    if [ "$adopted" = 1 ]; then
        pass "abandoned dial adopted once the server answered"
    else
        fail "no late adoption within 60s of approval"; dump_log
    fi
fi

prompt_case() { # name, session, id, text, timeout
    local name=$1 session=$2 id=$3 text=$4 timeout=$5
    log "== $name =="
    NOTIF_SEEN=0
    rpc_send '{"jsonrpc":"2.0","id":'"$id"',"method":"session/prompt","params":{"sessionId":"'"$session"'","prompt":[{"type":"text","text":"'"$text"'"}]}}'
    if ! rpc_await "$id" "$timeout"; then
        fail "$name: no prompt response within ${timeout}s (prompt hangs)"; dump_log
        return 1
    fi
    case "$FOUND_LINE" in
        *[Uu]navailable*)
            skip "$name: Apple Foundation Models unavailable here"
            return 2
            ;;
    esac
    case "$FOUND_LINE" in
        *'"stopReason"'*)
            if [ "$NOTIF_SEEN" -ge 1 ]; then
                pass "$name completes with streaming updates ($NOTIF_SEEN notifications)"
            else
                fail "$name completed but streamed zero updates"; dump_log
                return 1
            fi
            ;;
        *)
            fail "$name response is not a completion ($(printf '%s' "$FOUND_LINE" | head -c 200))"; dump_log
            return 1
            ;;
    esac
    return 0
}

if [ -n "$SID_PLAIN" ]; then
    rc=0
    prompt_case "4. first prompt" "$SID_PLAIN" 4 "Reply with the single word PONG and nothing else." 150 || rc=$?
    if [ "$rc" = 2 ]; then
        skip "5. second prompt (no FM here)"
    elif [ "$rc" = 0 ]; then
        prompt_case "5. second prompt, same session" "$SID_PLAIN" 5 "Reply with the single word PONG2 and nothing else." 150 || true
    fi
fi

log "== summary: $PASS passed, $SKIP skipped, $FAIL failed =="
[ "$FAIL" -eq 0 ]
