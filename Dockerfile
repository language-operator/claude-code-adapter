# -----------------------------------------------------------------------------
# claude-code adapter.
#
# The OS layer, the web terminal, tini, and the /etc/agent/config.yaml ETL all
# live in coding-runtime. What is left here is the Claude Code CLI plus the
# three files that describe it to the base: a manifest, an emitter, and a
# launcher.
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
ARG BASE=ghcr.io/language-operator/coding-runtime:0.1.0@sha256:9ed651b2c661d80622b3c5a15b454b4dffe9cae3bbd7643f21b592690afc4cb9

FROM ${BASE}

# Claude Code CLI. The thick base already carries node, tmux, gh, glab, Go,
# Helm, make, shellcheck, ripgrep and vim, so this is the only install left.
USER root
RUN npm install -g --no-audit --no-fund @anthropic-ai/claude-code \
    && npm cache clean --force

# runtime.json  — what this adapter is: config dir, serving surface, tmux launch.
# emit.mjs      — normalized operator config -> settings.json + .claude.json.
# launch-claude — what tmux runs inside the terminal.
COPY runtime.json /etc/coding-runtime/runtime.json
COPY emit.mjs /opt/adapter/emit.mjs
COPY --chmod=755 launch-claude.sh /usr/local/bin/launch-claude

# The operator pins the agent container to uid 1000 with no override, and the
# base already has a matching passwd entry. Do not create a user here.
USER node
