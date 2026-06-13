#!/bin/sh
set -e

# server.mjs honors PORT (default 8080), AGENT_REPO_DIR, and CLAUDE_CWD (default /workspace).
exec node /app/server.mjs
