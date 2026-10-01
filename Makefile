# `make test` extracts the conformance suite from the image under test — it ships
# inside the base image — so the checks always match the runtime being checked,
# the probe the terminal check needs is already beside it, and nothing here needs
# to know a coding-runtime version. It runs the image the way the operator does
# (read-only root, uid 1000, all capabilities dropped), so a failure here is a
# failure in-cluster.
REGISTRY  := ghcr.io/language-operator
IMAGE     := $(REGISTRY)/claude-code-adapter
GIT_SHA   := $(shell git rev-parse --short HEAD)
TAG       ?= $(GIT_SHA)
NAMESPACE ?= language-operator
RELEASE   ?= claude-code

# The one check Claude Code cannot pass. It types text and greps `tmux
# capture-pane` for it, which holds for a shell at a command line and for a TUI
# at its prompt box — but the conformance container has no credentials, so Claude
# Code sits on its first-run theme picker, a menu that renders none of the typed
# characters. The check before it passes and the tmux session exists, so delivery
# works; the assumption about what the program does with the keystrokes does not.
#
# This is the suite's own mechanism (coding-runtime 0.1.4+), not a local
# tolerance. A declared check still runs: it reports `skip` when it fails, and
# fails the run when it passes or when it never ran at all — so this declaration
# cannot outlive the limitation that justifies it, and cannot silently rot if the
# suite renames the check. Declare as little as possible; a check that fails
# because the image is wrong is the suite working.
CONFORMANCE_SKIP ?= a keystroke reaches the program under tmux

.PHONY: build publish test lint-chart dev uninstall

build:
	docker build -t $(IMAGE):$(TAG) -t $(IMAGE):latest .

publish: build
	docker push $(IMAGE):$(TAG)
	docker push $(IMAGE):latest

test: build
	@suite=$$(mktemp -t conformance.XXXXXX.sh); \
	trap 'rm -f "$$suite"' EXIT; \
	docker run --rm --entrypoint cat $(IMAGE):$(TAG) \
	    /opt/coding-runtime/test/conformance.sh > "$$suite"; \
	chmod +x "$$suite"; \
	CONFORMANCE_SKIP="$(CONFORMANCE_SKIP)" "$$suite" $(IMAGE):$(TAG) adapter

dev: build
	docker save $(IMAGE):$(TAG) | sudo k3s ctr images import -
	@# The claude-code LanguageAgentRuntime is cluster-scoped and may already
	@# exist, owned by the umbrella language-operator-runtimes chart. Adopting it
	@# into this release leaves helm's 3-way merge unable to update the image, so
	@# delete it first and let helm recreate it with the locally built image.
	kubectl delete languageagentruntime $(RELEASE) --ignore-not-found --wait
	helm upgrade --install $(RELEASE) chart \
		--namespace $(NAMESPACE) \
		--create-namespace \
		--set image.repository=$(IMAGE) \
		--set-string image.tag=$(TAG) \
		--set image.pullPolicy=Never \
		--wait --timeout 2m

uninstall:
	helm uninstall $(RELEASE) --namespace $(NAMESPACE) --ignore-not-found

lint-chart:
	helm lint chart/
