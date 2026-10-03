#!/bin/sh
# What a task-mode agent runs (AGENT_EXECUTION_MODE=task). The base runs this to
# completion in ${WORKDIR} and exits with its code, which becomes the run's
# phase: 0 is Succeeded, anything else is Failed.
#
# The prompt is the agent's instructions, written to $CLAUDE_CONFIG_DIR/task.md
# by `coding-runtime seed`; the model and MCP servers come from settings.json and
# .claude.json beside it, exactly as for the terminal. It goes in on stdin rather
# than as an argument, so long instructions cannot hit the per-argument size
# limit. AGENT_PERSONA is appended to the system prompt, as launch-claude does.
#
# --dangerously-skip-permissions: there is nobody to answer a permission prompt
# in a task run, and an unanswered one would hang until activeDeadlineSeconds.
# The pod is the boundary, as it already is for the terminal (see the README's
# Security section). --output-format stream-json --verbose puts one event per
# line in the pod log, which is the only artifact a task run leaves behind.
#
# Authentication is whatever the agent has: CLAUDE_CODE_OAUTH_TOKEN, or a /login
# persisted in $CLAUDE_CONFIG_DIR on the workspace volume. Without either,
# `claude -p` exits 1 with "Not logged in" and the run is Failed.
#
# Exit codes are Claude Code's own: 0 when the run completes, 1 on an error (not
# logged in, a bad model name, an API failure). A run killed by SIGTERM from
# activeDeadlineSeconds is reported by the base as 128 + signal.
set -eu

config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
task="$config_dir/task.md"
if [ ! -s "$task" ]; then
    echo "launch-claude-task: $task is empty — a task-mode agent needs spec.instructions" >&2
    exit 1
fi

# The langop plugin (language-operator#942). A non-interactive run loads only
# explicitly installed plugins, so a repository that enables
# langop@language-operator in its committed .claude/settings.json would
# otherwise run without the skills it pins. The marketplace ref comes from that
# file, never a tag hardcoded here, so the repository decides which release it
# gets. Every step is idempotent and runs on every start: that is what picks up
# a bumped ref. Plugins land under $CLAUDE_CONFIG_DIR/plugins, on the workspace
# volume, and the repository's settings file is left as it is.
plugin="langop@language-operator"
settings=".claude/settings.json"
if [ -f "$settings" ] && jq -e --arg p "$plugin" '.enabledPlugins[$p] == true' "$settings" >/dev/null 2>&1; then
    ref="$(jq -r '.extraKnownMarketplaces["language-operator"].source.ref // empty' "$settings")"
    marketplace="language-operator/skills${ref:+#$ref}"
    echo "launch-claude-task: installing $plugin from $marketplace" >&2

    fail() {
        echo "launch-claude-task: $1 failed; $settings enables $plugin, so the run cannot go ahead without it" >&2
        exit 1
    }
    claude plugin marketplace add "$marketplace" >&2 || fail "claude plugin marketplace add $marketplace"
    claude plugin install "$plugin" --scope project >&2 || fail "claude plugin install $plugin"
    claude plugin update "$plugin" --scope project >&2 || fail "claude plugin update $plugin"
    claude plugin list --json \
        | jq -e --arg p "$plugin" '.[] | select(.id == $p and .enabled)' >/dev/null \
        || fail "the check that $plugin is enabled"
fi

set -- -p --dangerously-skip-permissions --output-format stream-json --verbose
if [ -n "${AGENT_PERSONA:-}" ]; then
    set -- "$@" --append-system-prompt "$AGENT_PERSONA"
fi

exec claude "$@" < "$task"
