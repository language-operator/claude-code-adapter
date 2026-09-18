#!/bin/sh
# Runs inside the container image to verify seed-config.mjs behaviour.
# Exit 0 = all pass, non-zero = failure.
set -e

PASS=0
FAIL=0

assert() {
  local desc="$1"; local cmd="$2"
  if eval "$cmd" > /dev/null 2>&1; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}

set_config() {
  mkdir -p /etc/agent
  cat > /etc/agent/config.yaml
}

clear_config() {
  rm -f /etc/agent/config.yaml
}

# ---------------------------------------------------------------------------
# Test 1: full config.yaml mapping
# ---------------------------------------------------------------------------
echo "--- Test 1: full config.yaml mapping ---"

set_config << 'EOF'
agent:
  name: test-agent
  instructions: You are an expert code reviewer.
personas:
  - name: p
    displayName: Test Persona
    description: A test persona.
    systemPrompt: You are a test agent.
    instructions:
      - Do the thing
    capabilities:
      - research
    limitations:
      - No speculation
tools:
  my-tool:
    endpoint: http://my-tool.default.svc.cluster.local:8080
    protocol: mcp
models:
  claude-sonnet:
    model: claude-sonnet-4-5
EOF

mkdir -p /tmp/t1/home
HOME=/tmp/t1/home AGENT_NAME=test-agent \
  node /app/seed-config.mjs > /tmp/t1/out.txt 2>&1
clear_config

assert "settings.json created"          "[ -f /tmp/t1/home/.claude/settings.json ]"
assert "settings has model"             "grep -q 'claude-sonnet-4-5' /tmp/t1/home/.claude/settings.json"
assert "no ANTHROPIC_BASE_URL"          "! grep -q 'ANTHROPIC_BASE_URL' /tmp/t1/home/.claude/settings.json"
assert "no ANTHROPIC_API_KEY"           "! grep -q 'ANTHROPIC_API_KEY' /tmp/t1/home/.claude/settings.json"
assert ".claude.json created"           "[ -f /tmp/t1/home/.claude.json ]"
assert "mcpServers present"             "grep -q 'mcpServers' /tmp/t1/home/.claude.json"
assert "tool endpoint in .claude.json"  "grep -q 'my-tool.default.svc' /tmp/t1/home/.claude.json"
assert "MCP type is http"               "grep -q '\"type\": \"http\"' /tmp/t1/home/.claude.json"
assert "CLAUDE.md NOT written"          "[ ! -f /workspace/CLAUDE.md ]"

# ---------------------------------------------------------------------------
# Test 2: MCP servers merge-safe (existing .claude.json preserved)
# ---------------------------------------------------------------------------
echo "--- Test 2: merge-safe .claude.json ---"

set_config << 'EOF'
tools:
  new-tool:
    endpoint: http://new-tool.default.svc.cluster.local:8080
EOF

mkdir -p /tmp/t2/home/.claude
echo '{"userKey":"preserve-me","mcpServers":{"old-tool":{"type":"http","url":"http://old"}}}' \
  > /tmp/t2/home/.claude.json

HOME=/tmp/t2/home AGENT_NAME=test-agent \
  node /app/seed-config.mjs > /tmp/t2/out.txt 2>&1
clear_config

assert ".claude.json still exists"      "[ -f /tmp/t2/home/.claude.json ]"
assert "user key preserved"             "grep -q 'preserve-me' /tmp/t2/home/.claude.json"
assert "new tool present"               "grep -q 'new-tool' /tmp/t2/home/.claude.json"
assert "old mcpServer replaced"         "! grep -q 'old-tool' /tmp/t2/home/.claude.json"

# ---------------------------------------------------------------------------
# Test 3: env var fallback (no config.yaml, LLM_MODEL set)
# ---------------------------------------------------------------------------
echo "--- Test 3: LLM_MODEL env var fallback ---"

mkdir -p /tmp/t3/home/.claude

HOME=/tmp/t3/home AGENT_NAME=test-agent \
  LLM_MODEL=claude-sonnet-4-5 \
  node /app/seed-config.mjs > /tmp/t3/out.txt 2>&1

assert "settings.json created"          "[ -f /tmp/t3/home/.claude/settings.json ]"
assert "model from LLM_MODEL"           "grep -q 'claude-sonnet-4-5' /tmp/t3/home/.claude/settings.json"

# ---------------------------------------------------------------------------
# Test 4: no config.yaml, no env vars → no error
# ---------------------------------------------------------------------------
echo "--- Test 4: graceful empty (no config, no env vars) ---"

mkdir -p /tmp/t4/home/.claude

HOME=/tmp/t4/home AGENT_NAME=empty-agent \
  node /app/seed-config.mjs > /tmp/t4/out.txt 2>&1

assert "settings.json still created"    "[ -f /tmp/t4/home/.claude/settings.json ]"

# ---------------------------------------------------------------------------
# Test 5: terminal server runtime — node, native modules, claude, tmux
# ---------------------------------------------------------------------------
echo "--- Test 5: terminal server runtime present ---"

assert "node present"                   "node --version"
assert "node-pty + ws resolvable"       "cd /app && node -e \"require('node-pty');require('ws')\""
assert "@xterm assets resolvable"       "cd /app && node -e \"require.resolve('@xterm/xterm/lib/xterm.js');require.resolve('@xterm/xterm/css/xterm.css');require.resolve('@xterm/addon-fit/lib/addon-fit.js')\""
assert "claude CLI present"             "claude --version"
assert "gh CLI present"                 "gh --version"
assert "glab CLI present"               "glab --version"
assert "tmux present"                   "tmux -V"
assert "helm present"                   "helm version"
assert "make present"                   "make --version"
assert "shellcheck present"             "shellcheck --version"

# ---------------------------------------------------------------------------
# Test 6: WebSocket Origin check (cross-site WebSocket hijacking guard)
# ---------------------------------------------------------------------------
echo "--- Test 6: WebSocket Origin check ---"

mkdir -p /tmp/t6

# Handshake probe: prints "open" if the upgrade succeeded, "rejected:<code>"
# if the server refused it. Requires ws by absolute path so it runs from /tmp.
cat > /tmp/t6/probe.cjs << 'PROBE'
const WebSocket = require('/app/node_modules/ws');
const [url, origin] = process.argv.slice(2);
const ws = new WebSocket(url, origin ? { headers: { Origin: origin } } : {});
const done = (s) => { console.log(s); process.exit(0); };
ws.on('open', () => { ws.close(); done('open'); });
ws.on('unexpected-response', (req, res) => done('rejected:' + res.statusCode));
ws.on('error', (err) => done('error:' + err.message));
setTimeout(() => done('timeout'), 5000);
PROBE

start_server() {
  # $1 = port, $2 = ALLOWED_ORIGINS (may be empty)
  ALLOWED_ORIGINS="$2" PORT="$1" node /app/server.mjs > "/tmp/t6/server-$1.log" 2>&1 &
  SERVER_PID=$!
  i=0
  while [ "$i" -lt 50 ]; do
    wget -qO- "http://127.0.0.1:$1/" > /dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 0.1
  done
  echo "  (server on :$1 never came up)"
  return 1
}

stop_server() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}

probe() {
  node /tmp/t6/probe.cjs "ws://127.0.0.1:$1/ws" "$2"
}

# --- default policy: Origin must match Host ---
if start_server 8099 ""; then
  assert "same-origin accepted"       "[ \"\$(probe 8099 http://127.0.0.1:8099)\" = open ]"
  assert "cross-origin rejected"      "[ \"\$(probe 8099 https://evil.example)\" = rejected:403 ]"
  assert "host mismatch rejected"     "[ \"\$(probe 8099 http://127.0.0.1:9999)\" = rejected:403 ]"
  assert "unparseable origin rejected" "[ \"\$(probe 8099 'not a url')\" = rejected:403 ]"
  assert "no Origin accepted (non-browser client)" "[ \"\$(probe 8099 '')\" = open ]"
  assert "rejection logged"           "grep -q 'ws upgrade rejected' /tmp/t6/server-8099.log"
  stop_server
else
  FAIL=$((FAIL + 1))
fi

# --- explicit allowlist: ALLOWED_ORIGINS replaces the Host comparison ---
if start_server 8098 "https://console.example.com"; then
  assert "allowlisted origin accepted"     "[ \"\$(probe 8098 https://console.example.com)\" = open ]"
  assert "non-allowlisted origin rejected" "[ \"\$(probe 8098 http://127.0.0.1:8098)\" = rejected:403 ]"
  stop_server
else
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
