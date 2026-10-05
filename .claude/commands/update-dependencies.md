---
description: Bring every pinned upstream dependency up to date, with an audit trail
argument-hint: "[all|base|claude|actions] (default: all)"
allowed-tools: Bash(git:*), Bash(gh:*), Bash(npm:*), Bash(curl:*), Bash(jq:*), Bash(node:*), Bash(docker:*), Bash(helm:*), Bash(make:*), Bash(diff:*), Bash(grep:*), Read, Edit, Grep
---

Update the upstream dependencies of `claude-code-adapter`. Scope: **$ARGUMENTS** (empty means `all`).

This runs for security and compliance: the point is not only that versions move, but that the move is **recorded** — old version, new version, digest, and what changed — so the PR is the audit trail. A bump with no evidence behind it is worse than no bump, because it looks reviewed.

## The dependency surface

This repo carries almost no code of its own; it is a thin layer over a base image. Four groups: two are single pins, one spans several workflow files, and the last is not a pin at all but a pair of files shared with upstream, checked for drift rather than bumped.

**1. The `coding-runtime` base image** — the OS layer, the web terminal, `tini` and the config ETL all come from here, so this is the security-relevant one.

Pinned in exactly one place: `Dockerfile` `ARG BASE`, as `ghcr.io/language-operator/coding-runtime:X.Y.Z@sha256:…` — tag **and** digest.

It used to be pinned in four places, because the conformance suite was fetched from a release tarball and had to be told which tag to fetch. Since the suite is extracted from the image under test, the image reference is the only version that exists, and the "all four must move together" hazard is gone. Do not reintroduce a second copy of the version.

**2. The Claude Code CLI** — `Dockerfile` `ARG CLAUDE_CODE_VERSION`, installed as `@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}`.

This is the agent itself, so it is the dependency that moves most often. It is pinned to an exact version — never a range and never `latest` — so two builds of one git tag ship the same agent.

> **A pin is why this command matters for the CLI.** While it was unpinned, every rebuild silently picked up upstream's security fixes. Pinned, those fixes arrive only when this number moves, which is here. `@anthropic-ai/claude-code` publishes often and advisories against it are routine, so treat a stale CLI pin as a finding in its own right rather than as a tidy-up — check its advisories (step 4) even when the version gap looks small.

**3. GitHub Actions** — across `.github/workflows/{test,build-image,release-chart}.yaml`: `actions/checkout`, `docker/setup-buildx-action`, `docker/login-action`, `docker/metadata-action`, `docker/build-push-action`, `azure/setup-helm`.

**4. Files shared with `coding-runtime`** — `runtime.json` and `emit.mjs`, which also exist as `examples/claude-code/` upstream.

**This repo is the source of truth, and the direction is the opposite of what it looks like.** They began as copies taken *from* upstream, so the old instinct was to re-copy them *from* upstream on every base bump. Since base `0.1.3`, upstream's [`example-drift.yaml`](https://github.com/language-operator/coding-runtime/blob/main/.github/workflows/example-drift.yaml) fetches both files from **this repo's `main`** and fails **its own** CI when its examples differ — weekly, and on any PR there touching `examples/`. Their copies are generated from ours: they are the authoring reference the upstream docs point at, the source its CI fixture adapter is built from, and what its emitted goldens are generated against.

So drift is no longer silent, and it is no longer ours to absorb by overwriting. **Read the divergence rule below before taking any upstream copy.**

## Rules that must not be broken

- **Pin the base by tag *and* digest.** Never `:latest`.
- **Never pin a `main` or `sha-` build of the base.** `metadata-action` stamps those with the version literal `main`, which no `requires.codingRuntime` range in `runtime.json` can satisfy — every boot warns about a mismatch that is not real — and which also fails the conformance suite's own `reports a version` check, since that asserts semver. Only released semver tags.
- **Bump `requires.codingRuntime` in `runtime.json` when the adapter starts depending on something newer.** It is what makes a build on too old a base fail the manifest check instead of failing at seed time with a confusing error.
- **`emit.mjs` is the file that actually runs *here*** — `runtime.json` points the emitter at `/opt/adapter/emit.mjs`, which the Dockerfile fills from this repo. Nothing upstream runs this adapter's emitter in production, so a change made here is a change to this runtime's behaviour and to nothing else.

  Upstream's copy is not inert, though: its CI builds a fixture adapter from `examples/` and generates emitted goldens against it. A drift therefore has consequences in both repos — wrong behaviour here, or wrong goldens there — which is why the resolution is to make both sides match deliberately rather than to leave one wrong. Diff before taking any upstream copy.

  **What a flat `owns` list means depends on the base.** On `0.1.2` and later, deletion is provenance-gated: an owned key the emitter does not supply is removed only if the runtime wrote that value and it is unchanged on disk, so listing a conditionally-supplied key is safe and gives correct clean-up in both directions. On `0.1.0`/`0.1.1` it is [#17](https://github.com/language-operator/claude-code-adapter/issues/17) — the runtime deletes an interactive `/login` on every seed. So the check is not "is `owns` conditional" but:

  ```bash
  # Does the base being pinned gate deletion on provenance?
  gh api repos/language-operator/coding-runtime/contents/src/config/writers.mjs?ref=<vX.Y.Z> \
    -H 'Accept: application/vnd.github.raw' | grep -c 'provenance'
  ```

  If it does, a flat `owns` list is safe — so upstream's emitter is safe to take, *if* the drift rule says to take it at all. If it does not, an emitter that lists `hasCompletedOnboarding`, `oauthAccount` or `model` in a fixed `owns` array while supplying them conditionally will delete user state — keep a conditional version and record the divergence.
- **Do not unpin anything to make an update easier.** If a pin is in the way, that is the finding — report it rather than loosening it.

## Steps

Stop and report if any precondition fails; do not continue past a failure.

**1. Preconditions.** On `main`, working tree clean (`git status --porcelain` empty), `git fetch origin`, `main` not behind `origin/main`. Then `git checkout -b chore/update-dependencies`. Never work on `main`.

**2. Record the current state** — the "before" column of the audit trail.

```bash
grep -nE 'ARG BASE=|ARG CLAUDE_CODE_VERSION=' Dockerfile
grep -rn 'uses: .*@' .github/workflows/
```

**3. Discover the latest versions.**

Base image — released semver tags only, then resolve the digest of the one you pick:

```bash
T=$(curl -s "https://ghcr.io/token?scope=repository:language-operator/coding-runtime:pull&service=ghcr.io" | jq -r .token)
curl -s -H "Authorization: Bearer $T" \
  "https://ghcr.io/v2/language-operator/coding-runtime/tags/list?n=1000" \
  | jq -r '.tags[]' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -5

curl -sI -H "Authorization: Bearer $T" \
  -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
  "https://ghcr.io/v2/language-operator/coding-runtime/manifests/<X.Y.Z>" \
  | grep -i docker-content-digest
```

Take the **thick** variant — the unsuffixed tag. `-python` is the thin base and carries no Node, no tmux and no serving surface.

Claude Code CLI — the dist-tags, and take `latest`:

```bash
npm view @anthropic-ai/claude-code dist-tags --json
```

`latest` is what the install resolved to before it was pinned, so it is the version to keep taking; `stable` usually trails it by a few patches. If you take `stable` instead — a release where the extra caution is worth it, say — record which tag you took and why, because the next run will otherwise read it as a version that went backwards.

If npm fails with `ENOENT … mkdir`, the cache directory is read-only; re-run with `npm_config_cache="$(mktemp -d)"` prefixed.

GitHub Actions:

```bash
for a in actions/checkout docker/setup-buildx-action docker/login-action \
         docker/metadata-action docker/build-push-action azure/setup-helm; do
  printf '%s: %s\n' "$a" "$(gh api "repos/$a/releases/latest" --jq .tag_name)"
done
```

**4. Read what changed, before editing anything.** For each dependency that moved, fetch release notes and check advisories. This is the compliance half and it is not optional:

```bash
gh release view <tag> --repo <owner>/<repo>
gh api repos/<owner>/<repo>/security-advisories --jq '.[] | "\(.ghsa_id) \(.severity) \(.summary)"'
```

Note anything that reads as a security fix and anything that reads as breaking. A major-version jump in an action is a deliberate decision, not a routine bump — either handle it in this PR or leave that pin alone and record why.

**5. Apply the updates** for the requested scope.

- **Base:** `ARG BASE` with the new tag **and** digest. Then `runtime.json` `requires.codingRuntime`, if this bump is what the adapter now depends on.
- **Shared files:** diff against the upstream copies — at the new tag *and* at upstream `main`, since its examples track this repo continuously rather than per release. This is a **drift check**, not a sync step: the expected result is "identical", and in that case there is nothing to do.

  ```bash
  d=$(mktemp -d)
  for ref in <vX.Y.Z> main; do
    for f in runtime.json emit.mjs; do
      gh api "repos/language-operator/coding-runtime/contents/examples/claude-code/$f?ref=$ref" \
        -H 'Accept: application/vnd.github.raw' > "$d/$ref-$f"
      diff -u "$f" "$d/$ref-$f" --label "$f (here)" --label "examples/claude-code/$f ($ref)" \
        && echo "identical: $f vs $ref"
    done
  done
  ```

  **If they differ, decide which side is right before touching anything — do not default to copying.** Ours is what runs, and upstream's CI already treats ours as correct, so the common case is that *their* copy is stale and the fix belongs in a PR there, not here. Take upstream's version only when it is upstream that deliberately changed, which in practice means a new base genuinely expects something new — a `runtime.json` field the manifest check now reads, or an emitter change that goes with a new `ctx.*` helper. Even then it is a real decision: say in the PR body what the field does and why this adapter wants it, rather than copying past it.

  For `emit.mjs`, also apply the divergence rule above: a diff that removes a conditional `owns` is a regression, not an update.

  Either way, **record the drift and the direction you resolved it in.** A diff found and silently flattened is the one outcome that makes both repos wrong.
- **Claude Code CLI:** `ARG CLAUDE_CODE_VERSION` to the exact new version. Nothing else references it — the install line interpolates the ARG — so this is a one-line change.
- **Actions:** update the `uses:` pins.

**6. Keep the suite coming from the image.** `make test` and `test.yaml` extract `/opt/coding-runtime/test/conformance.sh` from the image under test, so the checks always match the runtime being checked and the probe the terminal check needs is already beside it. Do not replace this with a fetch from a tag — that is what required a second copy of the version, and a tolerance for a check that had drifted.

**7. Verify.**

```bash
helm lint chart && helm template claude-code chart >/dev/null
node --check emit.mjs && node -e "JSON.parse(require('fs').readFileSync('runtime.json','utf8'))"
make test        # builds the image and runs the conformance suite; needs Docker
```

Docker is usually unavailable in an agent pod. If it is, say so plainly rather than implying the suite ran — CI runs it on the PR, and the PR is where the evidence belongs.

**8. Commit and open a PR.** One commit per dependency group, so a bad bump reverts on its own. Never push to `main` directly; never tag — releasing is `/release` and it is a separate decision.

If nothing moved, there is no PR: `git checkout main && git branch -D chore/update-dependencies`, and go straight to the report.

The PR body is the audit record. For each dependency:

| | |
|---|---|
| Dependency | `ghcr.io/language-operator/coding-runtime` |
| Before → after | `0.1.0` → `0.1.1` |
| Digest | `sha256:…` |
| Notes | link to the release, one line on what changed |
| Security | the advisory it addresses, or "no advisories in range" |

End with what you did **not** update and why — a held-back major, a pin with a breaking change, a dependency with no newer release, a CLI version deliberately left behind. An empty "not updated" section should be written as such, not omitted.

**9. Merge it — without asking.** This command runs end to end: it finishes with the update on `main`, not with an open PR waiting for someone. Merging is safe because chart publishing is restricted to `v*` tags, so a merge publishes nothing; CI is the gate.

```bash
gh pr checks <pr> --watch --fail-fast --interval 20   # wait for build, image-test, chart-lint
gh pr merge <pr> --rebase --delete-branch
git checkout main && git pull --ff-only && git branch -D chore/update-dependencies
```

`main` is not branch-protected, so GitHub auto-merge is unavailable — wait on the checks here instead. Merge with `--rebase`, never `--squash`: squashing collapses the per-group commits and defeats the point of making them.

Merge only on green. If a check fails, do **not** merge and do not loosen a pin or skip a check to get it through: leave the PR open, and report the failure with its run link — that is the one outcome that hands back to a human. Findings that are only reported (a held-back major, a stale doc) are not a reason to hold the merge.

**10. Report.** What moved, what did not, and anything needing a human decision. If a bump carries a breaking change this repo has to absorb — the `HOME` relocation in the `0.1.0` migration is the worked example — say so explicitly rather than burying it in the diff.
