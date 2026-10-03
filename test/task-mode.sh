#!/usr/bin/env bash
# Task mode, end to end: the image under test runs one task-mode agent the way
# the operator runs it (read-only root, uid 1000, all capabilities dropped, tmpfs
# /tmp, AGENT_EXECUTION_MODE=task), against a mock of Anthropic's Messages API.
#
# The conformance suite proves the base honours task.exec, but with manifests of
# its own; nothing there runs launch-claude-task or Claude Code. This does, and
# checks what #34 asks of a task agent:
#
#   - a good model: exit 0, with the instructions sent as the prompt;
#   - a bad model name: a non-zero exit, so the run is Failed;
#   - no instructions: a non-zero exit naming the problem, not a hang;
#   - a repository whose .claude/settings.json enables langop@language-operator:
#     the plugin is installed at the pinned ref and loaded into the run. This
#     one clones language-operator/skills, so it needs GitHub egress.
#
# Only these test containers are pointed at the mock (ANTHROPIC_BASE_URL and
# ANTHROPIC_API_KEY on `docker run`). The runtime itself writes no endpoint or
# credential: claude-code talks to api.anthropic.com on the agent's own login.
#
# Usage: test/task-mode.sh <image>
set -euo pipefail

IMAGE="${1:?usage: task-mode.sh <image>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$(mktemp -d)"
NET="claude-task-$$"
MOCK="claude-task-mock-$$"
MODEL="claude-task-test-model"
FAIL=0

cleanup() {
    local status=$?
    docker rm -f "$MOCK" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    # The agent runs as uid 1000 and writes into the bind-mounted workspace;
    # remove those files from a root container, since the caller may not be 1000.
    docker run --rm -v "$WORKDIR:/w" --user 0:0 --entrypoint sh "$IMAGE" \
        -c 'rm -rf /w/*' >/dev/null 2>&1 || true
    rm -rf "$WORKDIR" 2>/dev/null || true
    return "$status"
}
trap cleanup EXIT

docker network create "$NET" >/dev/null
# The image under test already carries node, so the mock needs no other image.
docker run -d --name "$MOCK" --network "$NET" --network-alias anthropic \
    -v "$HERE/mock-anthropic.mjs:/mock-anthropic.mjs:ro" -e MOCK_MODEL="$MODEL" \
    --entrypoint node "$IMAGE" /mock-anthropic.mjs >/dev/null
for _ in $(seq 1 30); do
    docker logs "$MOCK" 2>&1 | grep -q 'mock anthropic on' && break
    sleep 1
done

# run_task <name> <model> <instructions> [repo-settings]: one task-mode run on a
# fresh workspace. With repo-settings, that file becomes the cloned repository's
# .claude/settings.json and the run starts there, as it does for an agent with
# spec.repository. Prints the agent's output; returns its exit code.
run_task() {
    local name="$1" model="$2" instructions="$3" repo_settings="${4:-}" dir="$WORKDIR/$1"
    local repo_env=()
    mkdir -p "$dir/workspace" "$dir/etc-agent"
    if [ -n "$repo_settings" ]; then
        mkdir -p "$dir/workspace/repo/.claude"
        cp "$repo_settings" "$dir/workspace/repo/.claude/settings.json"
        repo_env=(-e AGENT_REPO_DIR=/workspace/repo)
    fi
    chmod -R a+rwX "$dir/workspace"
    {
        echo "agent: {name: $name, namespace: default}"
        [ -n "$instructions" ] && echo "instructions: '$instructions'"
        echo "models:"
        echo "  primary: {role: primary, model: $model}"
    } > "$dir/etc-agent/config.yaml"
    docker run --rm --network "$NET" \
        --read-only --tmpfs /tmp:rw,size=256m \
        --user 1000:1000 --cap-drop ALL \
        -v "$dir/workspace:/workspace" \
        -v "$dir/etc-agent:/etc/agent:ro" \
        -e AGENT_NAME="$name" -e AGENT_NAMESPACE=default \
        -e AGENT_EXECUTION_MODE=task \
        -e ANTHROPIC_BASE_URL=http://anthropic:18080 \
        -e ANTHROPIC_API_KEY=sk-task-mode-test \
        ${repo_env[@]+"${repo_env[@]}"} \
        "$IMAGE" 2>&1
}

check() {
    local description="$1"; shift
    if "$@"; then
        echo "  ok   $description"
    else
        echo "  FAIL $description"
        FAIL=$((FAIL + 1))
    fi
}

# A good model completes. Exit 0 already proves a prompt arrived (`claude -p`
# with empty input fails); the marker proves it was the instructions.
good() {
    local out status=0
    out="$(run_task good "$MODEL" 'Reply with TASK-MARKER-7.')" || status=$?
    if [ "$status" != 0 ]; then
        printf '%s\n' "wanted exit 0, got $status" "$out"
        return 1
    fi
    if ! docker logs "$MOCK" 2>/dev/null | grep "\"model\":\"$MODEL\"" | grep -q 'TASK-MARKER-7'; then
        printf '%s\n' "the mock never saw the instructions as a prompt" "$out"
        return 1
    fi
}
check "a task run with a good model exits 0, prompted by the instructions" good

bad_model() {
    local out status=0
    out="$(run_task bad no-such-model 'Reply with anything.')" || status=$?
    [ "$status" != 0 ] && return 0
    printf '%s\n' "wanted a non-zero exit for a bad model name, got 0" "$out"
    return 1
}
check "a task run with a bad model name exits non-zero" bad_model

no_instructions() {
    local out status=0
    out="$(run_task empty "$MODEL" '')" || status=$?
    [ "$status" != 0 ] && grep -q 'spec.instructions' <<<"$out" && return 0
    printf '%s\n' "status=$status (wanted non-zero, output naming spec.instructions)" "$out"
    return 1
}
check "a task run with no instructions fails, saying so" no_instructions

# This repository's own settings file is the fixture: it is exactly what a repo
# that pins the plugin commits. The init event lists the skills the run loaded.
plugin() {
    local out status=0
    out="$(run_task plugin "$MODEL" 'Reply with anything.' "$HERE/../.claude/settings.json")" || status=$?
    if [ "$status" != 0 ]; then
        printf '%s\n' "wanted exit 0, got $status" "$out"
        return 1
    fi
    if ! grep -q 'launch-claude-task: installing langop@language-operator' <<<"$out"; then
        printf '%s\n' "the plugin install never ran" "$out"
        return 1
    fi
    if ! grep -q '"langop:iterate"' <<<"$out"; then
        printf '%s\n' "the run did not load langop:iterate" "$out"
        return 1
    fi
}
check "a repository that pins the langop plugin gets it installed and loaded" plugin

if [ "$FAIL" -gt 0 ]; then
    echo "task mode: $FAIL check(s) failed"
    exit 1
fi
echo "task mode: all checks passed"
