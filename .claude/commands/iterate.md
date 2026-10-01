---
description: Do the next logical piece of work — one issue, from pick to merged PR to closed
argument-hint: "[#issue] [--auto]"
allowed-tools: Bash(gh:*), Bash(git:*), Bash(bash .claude/commands/iterate/*), Bash(printenv:*), Bash(make:*), Bash(helm:*), Bash(docker:*), Read, Edit, Write, Glob, Grep
---
<!-- Canonical /iterate (language-operator#932). Only the frontmatter `allowed-tools`
     build-tool entries and the `## Testing` section vary per repo; everything else,
     and the scripts in .claude/commands/iterate/, is copied verbatim. -->

# Iterate: do the next logical piece of work

One run handles **one issue**, from selection to a merged PR and a closed issue, then stops.
For continuous work, use `/loop /iterate` or a scheduled agent.

## Context

Read:
- `CLAUDE.md`
- `README.md`
- `.claude/MEMORY.md`, if it exists

## Arguments

`$ARGUMENTS` may contain:
- *(nothing)*: pick the next issue (see below).
- `#N` or `N`: work issue N.
- `--auto`: unattended mode (see step 4).

## Picking the next issue

```bash
gh issue list --state open --limit 500 --json number,title,labels,createdAt --jq '
  map(select([.labels[].name] | (index("in-progress") or index("question")) | not))
  | map(. + {rank: ([.labels[].name] as $l |
      if $l | index("ready") then 0
      elif $l | index("bug") then 1
      elif $l | index("enhancement") then 2
      elif ($l | index("tech-debt")) or ($l | index("documentation")) then 3
      else 4 end)})
  | sort_by(.rank, .createdAt) | first // empty'
```

This skips issues labelled `in-progress` or `question`, then takes the first match in order: `ready` (set by `/prioritize`), `bug`, `enhancement`, `tech-debt`/`documentation`, everything else; oldest first within a group. If the output is empty, report idle and stop.

## Steps

1. **Select** the issue, either as above or from `#N`. If it's closed or not found, report and stop. Read the body and comments: `gh issue view <N> --comments`.
2. **Validate.** If the issue is invalid, a duplicate or out of date, comment why, close it, and go back to step 1. (With `#N`, stop instead.)
3. **Claim** the issue. Pick a short slug (2–4 words) from the title, then:
   ```bash
   bash .claude/commands/iterate/start-issue.sh <N> <short-slug>
   ```
   - The script adds `in-progress` (creating the label if the repo lacks it) before creating the worktree.
   - If it exits non-zero because the issue is already `in-progress`, go back to step 1 (with `#N`, stop).
   - It prints `worktree:<path>`. `cd` into that path and stay there for the rest of the run.
4. **Plan.** The run is unattended if `printenv AGENT_NAME` prints a value (the operator injects it into every agent pod) or `$ARGUMENTS` contains `--auto`.
   - Interactive: enter plan mode, propose the plan, and wait for approval.
   - Unattended: post the plan as a comment (`gh issue comment <N> --body "<plan>"`) and continue.
5. **Implement** the plan inside the worktree.
6. **Test**, following `## Testing` below. Add tests as needed.
7. **Commit** with a one-line conventional message (e.g. `fix: set GatewayReady false on error`), then push. Run these as separate commands, without inline variable assignments:
   ```bash
   bash .claude/commands/iterate/push-branch.sh <branch-name>
   ```
8. **Open a PR**: `gh pr create --title "<commit message>" --body "Closes #<N>"`.
9. **Watch CI**: `gh pr checks <PR> --watch`. Fix failures until all checks are green.
10. **Merge**: `gh pr merge <PR> --squash --delete-branch`.
11. **Clean up** the worktree (run from inside it; no arguments needed):
    ```bash
    bash .claude/commands/iterate/remove-worktree.sh
    ```
12. **Close the issue**:
    ```bash
    gh issue comment <N> --body "<resolution details>"
    gh issue edit <N> --remove-label "in-progress"
    gh issue close <N>
    ```
13. **Update `.claude/MEMORY.md`** if it exists and something is worth remembering for the next run (it's not a changelog). Then **stop**.

<!-- per-repo: Testing -->
## Testing

Mirror the two PR CI jobs in `.github/workflows/test.yaml`:

- **`make test`** — builds the image and runs `hack/conformance.sh`, which extracts the
  conformance suite from the image under test so the checks always match the runtime being
  checked. Mirrors the `image-test` job. One check is tolerated by name; see #23.
- **`make lint-chart`**, or `helm lint chart && helm template claude-code chart >/dev/null`.
  Mirrors the `chart-lint` job. Run it whenever you touch `chart/`.
- Touching `emit.mjs` or `runtime.json`? `node --check emit.mjs` and confirm
  `runtime.json` parses. Both are vendored from coding-runtime's `examples/claude-code/` —
  diff against upstream before changing them, and see CLAUDE.md for why `emit.mjs` is the
  copy that actually runs.
- **`make test` needs Docker, which an agent pod does not have.** When it is unavailable,
  say so plainly and let CI be the gate — do not report a suite that never ran as passing.
<!-- /per-repo -->
