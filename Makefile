# hack/conformance.sh extracts the suite from the image under test — it ships
# inside the base image — so the checks always match the runtime being checked
# and nothing here needs to know a coding-runtime version. It runs the image the
# way the operator does (read-only root, uid 1000, all capabilities dropped), so
# a failure here is a failure in-cluster. See the script for the one check it
# tolerates, and why.
REGISTRY  := ghcr.io/language-operator
IMAGE     := $(REGISTRY)/claude-code-adapter
GIT_SHA   := $(shell git rev-parse --short HEAD)
TAG       ?= $(GIT_SHA)
NAMESPACE ?= language-operator
RELEASE   ?= claude-code

.PHONY: build publish test lint-chart dev uninstall

build:
	docker build -t $(IMAGE):$(TAG) -t $(IMAGE):latest .

publish: build
	docker push $(IMAGE):$(TAG)
	docker push $(IMAGE):latest

test: build
	./hack/conformance.sh $(IMAGE):$(TAG)

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
