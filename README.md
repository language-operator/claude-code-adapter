# claude-code-adapter

The **claude-code** runtime for the [Language Operator](https://github.com/language-operator/language-operator):
an interactive [Claude Code](https://claude.com/claude-code) terminal agent that
runs as a native Kubernetes workload.

This repository is self-contained — it builds both the runtime image and the
Helm chart that registers the `claude-code` `LanguageAgentRuntime`.

## What's here

- **Image** (`ghcr.io/language-operator/claude-code-adapter`) — a combined image
  used by both the init container (`seed-config.mjs`, which translates the
  operator's `/etc/agent/config.yaml` into Claude Code's native settings) and the
  main container (`server.mjs`, the xterm.js / tmux WebSocket terminal). Ships
  the Claude Code CLI, the GitHub CLI, a Go toolchain, and common Unix tools.
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

## Development

```bash
make build      # docker build -t ghcr.io/language-operator/claude-code-adapter:latest .
make test       # build, then run the in-image smoke tests (/app/test.sh)
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
- `release-chart.yaml` — packages `chart/` and pushes it to `oci://ghcr.io/language-operator/charts`.
- `test.yaml` — builds the image, runs the smoke tests, and lints/templates the chart on every PR.
