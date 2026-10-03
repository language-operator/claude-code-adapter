# CLAUDE.md

Guidance for working in the `claude-code-adapter` repository.

## What this is

A [Language Operator](https://github.com/language-operator) **runtime** that runs
[Claude Code](https://claude.com/claude-code) as an interactive terminal agent on
Kubernetes, or headless as a task agent (`spec.execution.mode: task`). It is built on
[`coding-runtime`](https://github.com/language-operator/coding-runtime), which owns the OS
layer, the xterm.js / tmux web terminal, `tini` as PID 1, and the
`/etc/agent/config.yaml` ETL. What lives here is the Claude Code CLI plus **the files
that describe it to the base**: a manifest, an emitter and two launchers.

It ships as a **single image** plus a **Helm chart** registering the cluster-scoped
`claude-code` `LanguageAgentRuntime`. There is **no init container** — the base seeds
config in the agent container on every start, because the operator mounts `/tmp` into the
agent container only, so an init container would share no writable path with it.

## Key files

- `runtime.json` → `/etc/coding-runtime/runtime.json` — the manifest the base reads:
  `requires.codingRuntime` (the base range this adapter needs), `serve.surface: terminal`,
  `terminal.launch: ["launch-claude"]`, `terminal.cwd`, `task.exec: ["launch-claude-task"]`,
  and the emitter path.
  `env.CLAUDE_CONFIG_DIR` is `${WORKSPACE}/.claude`, so credentials, sessions and project
  history live on the workspace PVC and survive restarts.
- `emit.mjs` → `/opt/adapter/emit.mjs` — translates the normalized operator config into
  `settings.json`, `.claude.json` and `task.md` (the task-mode prompt). There is no
  upstream copy to keep in step any more: `examples/claude-code/` and `example-drift.yaml`
  were deleted upstream (coding-runtime #37), whose examples now demonstrate behaviours
  rather than mirror adapters. On a base bump, read upstream's
  `docs/authoring-an-adapter.md` for what a new base expects, not an example.
- `launch-claude.sh` → `/usr/local/bin/launch-claude` — what tmux runs: `--continue` only
  when a conversation exists for this directory, `AGENT_PERSONA` via
  `--append-system-prompt`, `AGENT_INSTRUCTIONS` as the opening message.
- `launch-claude-task.sh` → `/usr/local/bin/launch-claude-task` — what a task-mode run
  executes, in `${WORKDIR}`: fails on an empty `task.md`; installs the `langop` plugin at
  the marketplace `ref` pinned in the working directory's `.claude/settings.json`, when that
  file enables it; then `claude -p --dangerously-skip-permissions --output-format
  stream-json --verbose` with `task.md` on stdin. Its exit code is the run's phase.
- `test/task-mode.sh`, `test/mock-anthropic.mjs` — the task-mode test; see **Testing**.
- `chart/` — the `LanguageAgentRuntime` chart. Consumed by the umbrella
  `language-operator-runtimes` chart as subchart `claude-code`, with values keyed
  `claude-code.*`.
There is no `hack/` — `hack/conformance.sh` existed to let one check fail by name and was
deleted once base `0.1.4` shipped `CONFORMANCE_SKIP`, which does that accounting inside the
suite. Both `make test` and `test.yaml` now extract the suite from the image and declare the
check directly.

## Testing

- `make test` — builds the image, extracts `/opt/coding-runtime/test/conformance.sh` from
  it, and runs the suite under the posture the operator imposes and an adapter cannot
  override: read-only root, uid 1000, all capabilities dropped, tmpfs `/tmp`. A failure here
  is a failure in-cluster. It then runs `test/task-mode.sh`, under the same posture.
- `test/task-mode.sh <image>` — the suite checks task mode only with manifests of its own,
  so this runs the image's real `launch-claude-task` and `claude -p` against
  `test/mock-anthropic.mjs`. It checks four things: a good model exits 0 with the
  instructions as the prompt, a bad model exits non-zero, no instructions exits non-zero
  naming `spec.instructions`, and a repo pinning the `langop` plugin gets it installed and
  loaded. That last check clones `language-operator/skills`, so it needs GitHub egress.
  Only the test's containers are pointed at the mock; the runtime itself writes no
  endpoint or credential. Touching `launch-claude-task.sh`? You can run it outside Docker
  against the local `claude` and the mock: set `CLAUDE_CONFIG_DIR` to a scratch dir
  holding `settings.json` (`{"model":"<MOCK_MODEL>"}`) and `task.md`, and point
  `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY` at the mock.
- **One check is declared via `CONFORMANCE_SKIP`**, in the `Makefile` and in `test.yaml`:
  "a keystroke reaches the program under tmux", which greps the tmux pane for typed text
  that an uncredentialed Claude Code never renders — it sits on the first-run theme picker.
  The suite still runs it and **fails the run if it starts passing, or if the declaration
  stops matching a real check**, so the declaration cannot rot. Keep the two copies in step,
  and declare nothing else: a check failing because the image is wrong is the suite working.
- `make lint-chart`, or `helm lint chart && helm template claude-code chart >/dev/null`.
  Run it whenever you touch `chart/`.
- Touching `emit.mjs` or `runtime.json`? `node --check emit.mjs`, and confirm
  `runtime.json` parses (`node -e "JSON.parse(require('fs').readFileSync('runtime.json','utf8'))"`).
  Neither is covered by the conformance suite, which checks the config the emitter
  *produces* rather than the file itself.
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

`/iterate [#issue] [--auto]` runs one issue from selection to a merged PR and a closed
issue, then stops. Work happens in a git worktree under `.claude/worktrees/`.

It is **not a file in this repo**. It comes from the `iterate` skill in the `langop`
plugin ([language-operator/skills](https://github.com/language-operator/skills)), pinned by
`ref` in `.claude/settings.json` — currently `v0.1.0`. `/iterate` and `/langop:iterate` both
run it. Take a newer release by changing that `ref`; there is nothing to re-copy and no
drift to reconcile, which is why the local copy was deleted.

**The one per-repo part is the `## Testing` section of this file** — the skill reads it by
heading name, so keep that heading exactly `## Testing`. Machine-specific permissions go in
`.claude/settings.local.json`, which is gitignored; `.claude/settings.json` is committed and
holds only the plugin and marketplace entries.

An interactive session needs no install step. A non-interactive run (`claude -p`, a
scheduled agent) loads only explicitly installed plugins, so it needs
`claude plugin marketplace add 'language-operator/skills#v0.1.0'` and
`claude plugin install langop@language-operator --scope project` once, at the pinned tag.
