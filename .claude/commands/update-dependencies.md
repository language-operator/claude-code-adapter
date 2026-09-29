---
description: Bring every pinned upstream dependency up to date, with an audit trail
argument-hint: "[all|base|claude|actions] (default: all)"
allowed-tools: Bash(git:*), Bash(gh:*), Bash(npm:*), Bash(curl:*), Bash(jq:*), Bash(node:*), Bash(docker:*), Bash(helm:*), Bash(make:*), Bash(diff:*), Bash(grep:*), Read, Edit, Grep
---

Update the upstream dependencies of `claude-code-adapter`. Scope: **$ARGUMENTS** (empty means `all`).

This runs for security and compliance: the point is not only that versions move, but that the move is **recorded** — old version, new version, digest, and what changed — so the PR is the audit trail. A bump with no evidence behind it is worse than no bump, because it looks reviewed.

## The dependency surface

This repo vendors almost nothing of its own; it is a thin layer over a base image. Four groups, two of which span multiple files that must move together.

**1. The `coding-runtime` base image** — the OS layer, the web terminal, `tini` and the config ETL all come from here, so this is the security-relevant one.

Pinned in exactly one place: `Dockerfile` `ARG BASE`, as `ghcr.io/language-operator/coding-runtime:X.Y.Z@sha256:…` — tag **and** digest.

It used to be pinned in four places, because the conformance suite was fetched from a release tarball and had to be told which tag to fetch. Since the suite is extracted from the image under test, the image reference is the only version that exists, and the "all four must move together" hazard is gone. Do not reintroduce a second copy of the version.

**2. The Claude Code CLI** — `Dockerfile`, installed as the npm package `@anthropic-ai/claude-code`.

> **This is currently unpinned** (`npm install -g @anthropic-ai/claude-code`), so every image build takes whatever `latest` is at that moment and two builds of the same commit can ship different CLIs. Pinning it is a real change in behaviour, not a version bump — raise it as its own decision rather than folding it into a routine update. If it is still unpinned when you run this, say so in the report.

**3. GitHub Actions** — across `.github/workflows/{test,build-image,release-chart}.yaml`: `actions/checkout`, `docker/setup-buildx-action`, `docker/login-action`, `docker/metadata-action`, `docker/build-push-action`, `azure/setup-helm`.

**4. Vendored upstream files** — `runtime.json` and `emit.mjs` started as verbatim copies of `examples/claude-code/` in `coding-runtime`. Nothing fails when they drift, which is exactly why they get missed. **Read the divergence rule below before re-copying either.**

## Rules that must not be broken

- **Pin the base by tag *and* digest.** Never `:latest`.
- **Never pin a `main` or `sha-` build of the base.** `metadata-action` stamps those with the version literal `main`, which no `requires.codingRuntime` range in `runtime.json` can satisfy — every boot warns about a mismatch that is not real — and which also fails the conformance suite's own `reports a version` check, since that asserts semver. Only released semver tags.
- **Bump `requires.codingRuntime` in `runtime.json` when the adapter starts depending on something newer.** It is what makes a build on too old a base fail the manifest check instead of failing at seed time with a confusing error.
- **`emit.mjs` is the file that actually runs** — `runtime.json` points the emitter at `/opt/adapter/emit.mjs`, which the Dockerfile fills from this repo. The base's `examples/claude-code/emit.mjs` is a template nothing executes, so a difference between them changes behaviour here and nowhere else. Diff before taking any upstream copy.

  **What a flat `owns` list means depends on the base.** On `0.1.2` and later, deletion is provenance-gated: an owned key the emitter does not supply is removed only if the runtime wrote that value and it is unchanged on disk, so listing a conditionally-supplied key is safe and gives correct clean-up in both directions. On `0.1.0`/`0.1.1` it is [#17](https://github.com/language-operator/claude-code-adapter/issues/17) — the runtime deletes an interactive `/login` on every seed. So the check is not "is `owns` conditional" but:

  ```bash
  # Does the base being pinned gate deletion on provenance?
  gh api repos/language-operator/coding-runtime/contents/src/config/writers.mjs?ref=<vX.Y.Z> \
    -H 'Accept: application/vnd.github.raw' | grep -c 'provenance'
  ```

  If it does, take upstream's emitter. If it does not, an emitter that lists `hasCompletedOnboarding`, `oauthAccount` or `model` in a fixed `owns` array while supplying them conditionally will delete user state — keep a conditional version and record the divergence.
- **Do not unpin anything to make an update easier.** If a pin is in the way, that is the finding — report it rather than loosening it.

## Steps

Stop and report if any precondition fails; do not continue past a failure.

**1. Preconditions.** On `main`, working tree clean (`git status --porcelain` empty), `git fetch origin`, `main` not behind `origin/main`. Then `git checkout -b chore/update-dependencies`. Never work on `main`.

**2. Record the current state** — the "before" column of the audit trail.

```bash
grep -nE 'ARG BASE=|npm install -g' Dockerfile
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

Claude Code CLI — the `latest` dist-tag:

```bash
npm view @anthropic-ai/claude-code dist-tags --json
```

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
- **Vendored files:** fetch the upstream copies at the new tag and **diff** — never overwrite unread.

  ```bash
  gh api repos/language-operator/coding-runtime/contents/examples/claude-code/runtime.json?ref=<vX.Y.Z> -H 'Accept: application/vnd.github.raw' > /tmp/runtime.json
  gh api repos/language-operator/coding-runtime/contents/examples/claude-code/emit.mjs?ref=<vX.Y.Z>     -H 'Accept: application/vnd.github.raw' > /tmp/emit.mjs
  diff -u runtime.json /tmp/runtime.json; diff -u emit.mjs /tmp/emit.mjs
  ```

  For `runtime.json`, take upstream unless it changes something this adapter deliberately sets; a new field is a real decision, so surface it rather than copying past it. For `emit.mjs`, apply the divergence rule above — a diff that removes the conditional `owns` is a regression, not an update.
- **Claude Code CLI:** if pinned, bump it. If not, do not silently start pinning as part of a bulk update — raise it.
- **Actions:** update the `uses:` pins.

**6. Keep the suite coming from the image.** `make test` and `test.yaml` extract `/opt/coding-runtime/test/conformance.sh` from the image under test, so the checks always match the runtime being checked and the probe the terminal check needs is already beside it. Do not replace this with a fetch from a tag — that is what required a second copy of the version, and a tolerance for a check that had drifted.

**7. Verify.**

```bash
helm lint chart && helm template claude-code chart >/dev/null
node --check emit.mjs && node -e "JSON.parse(require('fs').readFileSync('runtime.json','utf8'))"
make test        # builds the image and runs the conformance suite; needs Docker
```

Docker is usually unavailable in an agent pod. If it is, say so plainly rather than implying the suite ran — CI runs it on the PR, and the PR is where the evidence belongs.

**8. Commit and open a PR.** One commit per dependency group, so a bad bump reverts on its own. Never push to `main`; never tag — releasing is `/release` and it is a separate decision. Merging is safe: chart publishing is restricted to `v*` tags, so a merge publishes nothing.

The PR body is the audit record. For each dependency:

| | |
|---|---|
| Dependency | `ghcr.io/language-operator/coding-runtime` |
| Before → after | `0.1.0` → `0.1.1` |
| Digest | `sha256:…` |
| Notes | link to the release, one line on what changed |
| Security | the advisory it addresses, or "no advisories in range" |

End with what you did **not** update and why — a held-back major, a pin with a breaking change, a dependency with no newer release, the CLI still unpinned. An empty "not updated" section should be written as such, not omitted.

**9. Report.** What moved, what did not, and anything needing a human decision. If a bump carries a breaking change this repo has to absorb — the `HOME` relocation in the `0.1.0` migration is the worked example — say so explicitly rather than burying it in the diff.
