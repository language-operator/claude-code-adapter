# claude-code-adapter

The **claude-code** runtime for the [Language Operator](https://github.com/language-operator/language-operator):
an interactive [Claude Code](https://claude.com/claude-code) terminal agent that
runs as a native Kubernetes workload.

This repository is self-contained — it builds both the runtime image and the
Helm chart that registers the `claude-code` `LanguageAgentRuntime`.

## What's here

- **Image** (`ghcr.io/language-operator/claude-code-adapter`) — the
  [`coding-runtime`](https://github.com/language-operator/coding-runtime) base
  plus the Claude Code CLI and three files that describe it to the base:
  `runtime.json` (the manifest), `emit.mjs` (operator config → Claude Code's
  native settings) and `launch-claude.sh` (what tmux runs). The base owns the OS
  layer — the GitHub and GitLab CLIs, a Go toolchain, Helm, and common Unix tools
  — along with the web terminal, `tini` as PID 1, and the
  `/etc/agent/config.yaml` ETL.
- **Chart** (`chart/`) — renders the cluster-scoped `claude-code`
  `LanguageAgentRuntime`. Published to `oci://ghcr.io/language-operator/charts/claude-code`.

## Install

Prerequisite: the [`language-operator`](https://github.com/language-operator/language-operator)
chart must be installed first — it provides the `LanguageAgentRuntime` CRD.

```bash
helm install claude-code oci://ghcr.io/language-operator/charts/claude-code \
  --namespace language-operator
```

Then reference it from a `LanguageAgent`:

```yaml
apiVersion: langop.io/v1alpha1
kind: LanguageAgent
metadata:
  name: my-agent
spec:
  runtime: claude-code
```

Claude Code authentication is interactive: open the agent terminal and run `/login`.

## Security

The terminal has no authentication of its own — agents sit behind the cluster
OIDC proxy (`auth.enabled` in the chart). Two things follow from that:

- **Origin is enforced on the WebSocket upgrade.** WebSocket handshakes are not
  subject to the same-origin policy, so a cookie-authenticating proxy on its own
  does not stop a third-party page from opening `wss://<agent-host>/ws` and
  driving the terminal as the signed-in user. The base rejects any upgrade whose
  `Origin` doesn't match the request's `Host` (403, logged as
  `ws upgrade rejected: ...` — that line is what to look for if a terminal
  suddenly connects to nothing after a proxy change). Set `ALLOWED_ORIGINS` to a
  comma-separated list of exact origins when the proxy rewrites `Host`, or when
  some other origin — a console embedding the terminal — has to connect. The
  check is `serve.originGuard` in `runtime.json`; it started life here as
  `server.mjs` and now lives in the base, which also normalises implied ports so
  `https://x` and `x:443` compare equal.
  Requests carrying no `Origin` at all (curl, probes, in-cluster clients) are
  allowed: they aren't browsers, so they aren't the attack this stops.
- **Pod reachability is still the real boundary.** Anything that can reach port
  8080 on the pod directly bypasses the proxy entirely. Keep a NetworkPolicy in
  front that admits only the proxy.
- **Repository contents execute in the pod.** `emit.mjs` marks
  `/workspace` as trusted so Claude Code doesn't prompt on first run, and
  `launch-claude` runs `AGENT_INSTRUCTIONS` as the opening message. Together with
  the operator cloning the agent's repository into `/workspace/<repo>`, that means
  anything on the tracked branch — `.claude/settings.json` hooks, `CLAUDE.md`,
  a `Makefile` target an instruction tells the agent to run — takes effect inside
  the pod, unprompted, with the agent's git credentials and whatever else is
  mounted. Treat push access to an agent's repository as equivalent to shell
  access in that agent's pod: protect the branch, review what merges, and don't
  point an agent at a repository you don't control.

## Development

```bash
make build      # docker build -t ghcr.io/language-operator/claude-code-adapter:latest .
make test       # build, then run the upstream conformance suite against the image
make dev        # build, import into k3s, and install the chart with pullPolicy=Never
make publish    # build and push the image to ghcr.io

helm lint chart
helm template claude-code chart
```

For a local cluster, build the image and import it into k3s, then install the
chart with `image.pullPolicy=Never`:

```bash
make build
docker save ghcr.io/language-operator/claude-code-adapter:latest | sudo k3s ctr images import -
helm install claude-code chart --namespace language-operator --set image.pullPolicy=Never
```

## CI

- `build-image.yaml` — builds and pushes the image to `ghcr.io` on push to `main` and `v*` tags.
- `release-chart.yaml` — packages `chart/` and pushes it to `oci://ghcr.io/language-operator/charts`, **on `v*` tags only**: a published chart version is immutable in practice, so publishing is a release action rather than a merge action.
- `test.yaml` — builds the image, runs the `coding-runtime` conformance suite
  against it (`hack/conformance.sh`, pinned to the tag the Dockerfile pins), and
  lints/templates the chart on every PR.
