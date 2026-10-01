# CLAUDE.md

Guidance for working in the `claude-code-adapter` repository.

## What this is

A [Language Operator](https://github.com/language-operator) **runtime** that runs
[Claude Code](https://claude.com/claude-code) as an interactive terminal agent on
Kubernetes. It is built on
[`coding-runtime`](https://github.com/language-operator/coding-runtime), which owns the OS
layer, the xterm.js / tmux web terminal, `tini` as PID 1, and the
`/etc/agent/config.yaml` ETL. What lives here is the Claude Code CLI plus **three files
that describe it to the base**: a manifest, an emitter and a launcher.

It ships as a **single image** plus a **Helm chart** registering the cluster-scoped
`claude-code` `LanguageAgentRuntime`. There is **no init container** — the base seeds
config in the agent container on every start, because the operator mounts `/tmp` into the
agent container only, so an init container would share no writable path with it.

## Key files

- `runtime.json` → `/etc/coding-runtime/runtime.json` — the manifest the base reads:
  `requires.codingRuntime` (the base range this adapter needs), `serve.surface: terminal`,
  `terminal.launch: ["launch-claude"]`, `terminal.cwd`, and the emitter path.
  `env.CLAUDE_CONFIG_DIR` is `${WORKSPACE}/.claude`, so credentials, sessions and project
  history live on the workspace PVC and survive restarts.
- `emit.mjs` → `/opt/adapter/emit.mjs` — translates the normalized operator config into
  `settings.json` and `.claude.json`. **This is the copy that actually runs.** The base's
  `examples/claude-code/emit.mjs` is a template nothing executes, so a difference between
  them changes behaviour here and nowhere else. Both this and `runtime.json` are vendored
  from that example — diff against upstream before changing either.
- `launch-claude.sh` → `/usr/local/bin/launch-claude` — what tmux runs: `--continue` only
  when a conversation exists for this directory, `AGENT_PERSONA` via
  `--append-system-prompt`, `AGENT_INSTRUCTIONS` as the opening message.
- `chart/` — the `LanguageAgentRuntime` chart. Consumed by the umbrella
  `language-operator-runtimes` chart as subchart `claude-code`, with values keyed
  `claude-code.*`.
- `hack/conformance.sh` — runs the base's conformance suite, extracted from the image
  under test. Tolerates one check by name — "a keystroke reaches the program under tmux",
  which Claude Code cannot pass because an uncredentialed container sits on the first-run
  theme picker, a menu that renders none of the typed text
  ([coding-runtime#27](https://github.com/language-operator/coding-runtime/pull/27)). That
  PR merged `CONFORMANCE_SKIP` upstream, which does this accounting in the suite; it is in
  no released base yet, so **when `ARG BASE` moves to one that has it, delete this script**
  and pass the declaration to the extracted suite instead. The script's header says how.

## Testing

- `make test` — builds the image and runs `hack/conformance.sh` against it under the
  posture the operator imposes and an adapter cannot override: read-only root, uid 1000,
  all capabilities dropped, tmpfs `/tmp`. A failure here is a failure in-cluster.
- `make lint-chart`, or `helm lint chart && helm template claude-code chart >/dev/null`.
- CI correctness == the two `.github/workflows/test.yaml` jobs: `image-test` and
  `chart-lint`. **`make test` needs Docker, which an agent pod does not have** — when it is
  unavailable, say so and let CI be the gate rather than implying the suite ran.

## Build & dev deploy

- `make build` — `ghcr.io/language-operator/claude-code-adapter:<git-sha>` + `:latest`.
- `make dev` — build, import into local k3s, `helm upgrade` with `pullPolicy=Never`. It
  **deletes the `LanguageAgentRuntime` first**: the resource is cluster-scoped and may be
  owned by the umbrella chart, and Helm's 3-way merge then cannot update the image.
- `make publish` — push image tags. `make uninstall` — remove the release.

**Both upstreams are pinned.** The Claude Code CLI is `ARG CLAUDE_CODE_VERSION`, an exact
version — unpinned, a rebuild of a release tag shipped a different agent than the release
did. The flip side is that CLI security fixes now arrive only when that number moves, which
is `/update-dependencies`' job.

**The base is pinned by tag *and* digest** in `ARG BASE`. Never `:latest`, and never a
`main` build — `metadata-action` stamps those with the version literal `main`, which no
`requires.codingRuntime` range can satisfy, so every boot warns about a mismatch that is
not real. **Do not create a user** in the Dockerfile: the operator pins the agent container
to uid 1000 and the base already has a matching passwd entry.

## Releases

Cut one with `/release major|minor|patch` (`.claude/commands/release.md`). Version is kept
in **lockstep**: `chart/Chart.yaml` `version` + `appVersion`, `chart/values.yaml`
`image.tag`, and the git tag `vX.Y.Z` all become the same `X.Y.Z`. Pushing a `v*` tag
triggers `build-image.yaml` and `release-chart.yaml`.

**Chart publishing is `v*` tags only** — a merge to `main` publishes nothing. It used to
fire on every push, which silently overwrote already-published versions in place.

Dependencies move with `/update-dependencies`.

## Issue-driven workflow

`/iterate [#issue] [--auto]` (`.claude/commands/iterate.md`) runs one issue from selection
to a merged PR and a closed issue, then stops. Work happens in a git worktree under
`.claude/worktrees/`. The command body and the scripts in `.claude/commands/iterate/` are
canonical across the org (language-operator#932) — only the `allowed-tools` build tools and
the `## Testing` section are ours to change.
