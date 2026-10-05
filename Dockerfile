# -----------------------------------------------------------------------------
# claude-code adapter.
#
# The OS layer, the web terminal, tini, and the /etc/agent/config.yaml ETL all
# live in coding-runtime. What is left here is the Claude Code CLI plus the
# files that describe it to the base: a manifest, an emitter, and two
# launchers — one for the terminal, one for a task-mode run.
#
# Much of that base came from this repo — server.mjs, index.html, tmux.conf and
# the cross-origin guard were lifted out of it, and src/serve/origin.mjs still
# names the commit. What this repo gains in return is the other direction: gh,
# glab, helm, make and shellcheck all landed here and never reached the other
# adapters. They are the base's problem now.
#
# The base is pinned by tag *and* digest. Never :latest, and never a `main`
# build — metadata-action stamps those with the version literal `main`, which no
# `requires.codingRuntime` range can satisfy, so every boot would warn about a
# version mismatch that is not real.
# -----------------------------------------------------------------------------
ARG BASE=ghcr.io/language-operator/coding-runtime:0.1.7@sha256:1eb526429b7636a8e7a5e60b947ff6e5cbb9feccdfc867f8f7885e6c3b0ca8e2

# The CLI is pinned for the same reason the base is: two builds of one git tag
# must ship the same agent. Unpinned, `npm install -g` took whatever `latest`
# was at build time, so a rebuild of a release tag silently shipped a different
# Claude Code than the release did.
#
# The cost of a pin is that CLI security fixes no longer arrive by rebuilding —
# they arrive when this number moves. /update-dependencies bumps it alongside
# the base, and that is what keeps the pin from going stale.
ARG CLAUDE_CODE_VERSION=2.1.289

FROM ${BASE}

# Claude Code CLI. The thick base already carries node, tmux, gh, glab, Go,
# Helm, make, shellcheck, ripgrep, vim and — since 0.1.4 — python3 and uv, so
# this is the only install left.
# ARG is re-declared because the one above FROM is outside the build stage.
ARG CLAUDE_CODE_VERSION
USER root
RUN npm install -g --no-audit --no-fund "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force

# runtime.json       — what this adapter is: config dir, serving surface, tmux launch.
# emit.mjs           — normalized operator config -> settings.json + .claude.json.
# launch-claude      — what tmux runs inside the terminal.
# launch-claude-task — what a task-mode run executes instead: headless `claude -p`.
COPY runtime.json /etc/coding-runtime/runtime.json
COPY emit.mjs /opt/adapter/emit.mjs
COPY --chmod=755 launch-claude.sh /usr/local/bin/launch-claude
COPY --chmod=755 launch-claude-task.sh /usr/local/bin/launch-claude-task

# The operator pins the agent container to uid 1000 with no override, and the
# base already has a matching passwd entry. Do not create a user here.
USER node
