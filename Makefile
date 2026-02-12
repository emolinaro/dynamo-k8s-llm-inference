SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

RELEASE_VERSION ?= 0.9.0

.PHONY: help k8s dynamo install benchmark-env all

help:
	@printf "Targets:\n"
	@printf "  k8s     Install a single-node Kubernetes cluster (uses sudo)\n"
	@printf "  dynamo  Install NVIDIA Dynamo platform + GPU operator\n"
	@printf "  benchmark-env  Setup Python venv + benchmark deps\n"
	@printf "  install Run k8s then dynamo\n"

k8s:
	sudo -E ./k8s-single-node-cilium.sh

dynamo:
	RELEASE_VERSION="$(RELEASE_VERSION)" ./install-dynamo-1node.sh

install: k8s dynamo

benchmark-env:
	./setup-benchmark-env.sh

all: install
