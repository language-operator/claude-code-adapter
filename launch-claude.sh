#!/bin/sh
# Launch Claude Code with the agent's role and opening task from operator
# env vars. AGENT_PERSONA → --append-system-prompt (role/tone); AGENT_INSTRUCTIONS
# → initial user message (the task to execute on startup). Either or both may be
# absent — falls back to bare interactive claude.
#
# --continue resumes this directory's last conversation after a restart, but
# only once one has been saved: on a first start, or after a run that never
# got past onboarding (the login flow, say), `claude --continue` fails with
# "No conversation found to continue" and exits, which the web terminal can
# only show as a dead session. So the flag is added only when Claude Code has
# a conversation file for this directory.
set -eu

config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# Claude Code keys conversations by the working directory with every
# non-alphanumeric character replaced by "-" (/workspace/app → -workspace-app).
project_dir="$config_dir/projects/$(pwd | sed 's/[^A-Za-z0-9]/-/g')"

set --
if ls "$project_dir"/*.jsonl >/dev/null 2>&1; then
    set -- --continue
fi

if [ -n "${AGENT_PERSONA:-}" ]; then
    set -- "$@" --append-system-prompt "$AGENT_PERSONA"
fi

if [ -n "${AGENT_INSTRUCTIONS:-}" ]; then
    exec claude "$@" "$AGENT_INSTRUCTIONS"
else
    exec claude "$@"
fi
