SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

RELEASE_VERSION ?= 1.0.2
CHART_VERSION ?= $(RELEASE_VERSION)
DYNAMO_STORAGE_CLASS ?= local-path
PROMETHEUS_ENDPOINT ?= http://prometheus-server.monitoring.svc.cluster.local
INSTALL_GPU_OPERATOR ?= true
REQUIRE_GPUS ?= true

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
	RELEASE_VERSION="$(RELEASE_VERSION)" CHART_VERSION="$(CHART_VERSION)" DYNAMO_STORAGE_CLASS="$(DYNAMO_STORAGE_CLASS)" PROMETHEUS_ENDPOINT="$(PROMETHEUS_ENDPOINT)" INSTALL_GPU_OPERATOR="$(INSTALL_GPU_OPERATOR)" REQUIRE_GPUS="$(REQUIRE_GPUS)" ./install-dynamo-1node.sh

install: k8s dynamo

benchmark-env:
	./setup-benchmark-env.sh

all: install
