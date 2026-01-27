SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

.PHONY: help k8s dynamo install all

help:
	@printf "Targets:\n"
	@printf "  k8s     Install a single-node Kubernetes cluster (uses sudo)\n"
	@printf "  dynamo  Install NVIDIA Dynamo platform + GPU operator\n"
	@printf "  install Run k8s then dynamo\n"

k8s:
	sudo -E ./k8s-single-node-cilium.sh

dynamo:
	./install-dynamo-1node.sh

install: k8s dynamo

all: install
