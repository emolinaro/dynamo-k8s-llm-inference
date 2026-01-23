#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Single-node Kubernetes on Ubuntu 24.04 with containerd + kubeadm + Cilium
#
# Fixes included:
#  - Remove control-plane taint BEFORE waiting for Cilium, so hubble-ui/relay
#    Deployments can schedule on a 1-node cluster.
#  - Install Helm from get.helm.sh (default HELM_VERSION=v4.1.0).
###############################################################################

#------------------------------#
# User-tunable configuration   #
#------------------------------#

K8S_REPO_MINOR="${K8S_REPO_MINOR:-v1.30}"
CLUSTER_NAME="${CLUSTER_NAME:-k8s-single}"
POD_CIDR="${POD_CIDR:-10.0.0.0/16}"
ENABLE_HUBBLE="${ENABLE_HUBBLE:-true}"

# Helm install (Helm 4 example; override if you want something else)
HELM_VERSION="${HELM_VERSION:-v4.1.0}"   # e.g. v4.1.0, v4.0.5, v3.20.0, ...
INSTALL_HELM="${INSTALL_HELM:-true}"     # true/false

# kube-prometheus-stack install (requires Helm)
INSTALL_PROMETHEUS_STACK="${INSTALL_PROMETHEUS_STACK:-true}"  # true/false

#------------------------------#
# Helpers                      #
#------------------------------#

log() { echo -e "\n==> $*\n"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run as root (use sudo)." >&2
    exit 1
  fi
}

detect_primary_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    PRIMARY_USER="${SUDO_USER}"
    PRIMARY_HOME="$(getent passwd "${PRIMARY_USER}" | cut -d: -f6)"
  else
    PRIMARY_USER="root"
    PRIMARY_HOME="/root"
  fi
}

already_initialized() {
  [[ -f /etc/kubernetes/admin.conf ]]
}

detect_arch() {
  # Returns one of: amd64, arm64
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *)
      echo "ERROR: Unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

install_helm_from_get_helm_sh() {
  local arch="$1"         # amd64/arm64
  local ver="$2"          # v4.1.0
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN

  log "Install Helm ${ver} (from get.helm.sh)"
  (
    cd "${tmp}"
    local tar="helm-${ver}-linux-${arch}.tar.gz"
    local sum="${tar}.sha256sum"
    wget -q "https://get.helm.sh/${tar}" -O "${tar}"

    # Checksum file exists for released versions; verify if we can fetch it.
    if wget -q "https://get.helm.sh/${sum}" -O "${sum}"; then
      sha256sum --check "${sum}"
    else
      echo "WARN: Could not fetch checksum file for ${tar}; installing without sha256 verification." >&2
    fi

    tar -xzvf "${tar}"
    install -m 0755 "linux-${arch}/helm" /usr/local/bin/helm
  )

  helm version || true
}

#------------------------------#
# Main                         #
#------------------------------#

require_root
detect_primary_user

log "Sanity checks"
. /etc/os-release
if [[ "${ID}" != "ubuntu" ]]; then
  echo "ERROR: This script expects Ubuntu. Detected: ${ID}" >&2
  exit 1
fi

if already_initialized; then
  echo "A Kubernetes control-plane already seems initialized on this machine."
  echo "Found: /etc/kubernetes/admin.conf"
  echo "Exiting to avoid clobbering an existing cluster."
  exit 0
fi

log "Step 1: Update OS packages"
apt-get update -y
apt-get upgrade -y

log "Step 2: Install base dependencies"
apt-get install -y \
  curl wget gnupg ca-certificates apt-transport-https lsb-release

log "Step 3: Disable swap"
swapoff -a
sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab

log "Step 4: Load kernel modules"
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

log "Step 5: Set sysctl params"
cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

log "Step 6: Install containerd"
apt-get install -y containerd

log "Step 7: Configure containerd (systemd cgroups)"
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl enable containerd
systemctl restart containerd

log "Step 8: Install kubeadm/kubelet/kubectl from pkgs.k8s.io"
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/deb/ /
EOF

apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

if [[ "${INSTALL_HELM}" == "true" ]]; then
  arch="$(detect_arch)"
  install_helm_from_get_helm_sh "${arch}" "${HELM_VERSION}"
fi

log "Step 9: Initialize Kubernetes control plane with kubeadm (single-node cluster)"
kubeadm init \
  --pod-network-cidr="${POD_CIDR}" \
  --node-name="$(hostname -s)"

log "Step 10: Configure kubectl for ${PRIMARY_USER}"
install -d -m 0755 "${PRIMARY_HOME}/.kube"
cp -f /etc/kubernetes/admin.conf "${PRIMARY_HOME}/.kube/config"
chown -R "${PRIMARY_USER}:${PRIMARY_USER}" "${PRIMARY_HOME}/.kube"

log "Step 11: Install Cilium CLI"
CILIUM_CLI_VERSION="$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)"
CLI_ARCH="$(detect_arch)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

(
  cd "${tmpdir}"
  curl -L --fail --remote-name-all \
    "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz" \
    "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"
  sha256sum --check "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"
  tar xzvf "cilium-linux-${CLI_ARCH}.tar.gz" -C /usr/local/bin
)

log "Step 12: Install Cilium CNI"
if [[ "${ENABLE_HUBBLE}" == "true" ]]; then
  sudo -u "${PRIMARY_USER}" -H cilium install \
    --set hubble.enabled=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true
else
  sudo -u "${PRIMARY_USER}" -H cilium install
fi

log "Step 13: Allow scheduling on the control-plane node (IMPORTANT for 1-node clusters)"
# Must happen BEFORE `cilium status --wait` if Hubble is enabled,
# otherwise hubble-ui/relay will remain Pending due to the taint.
sudo -u "${PRIMARY_USER}" -H kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
sudo -u "${PRIMARY_USER}" -H kubectl taint nodes --all node-role.kubernetes.io/master- 2>/dev/null || true

log "Step 14: Wait for Cilium to become ready"
sudo -u "${PRIMARY_USER}" -H cilium status --wait

if [[ "${INSTALL_PROMETHEUS_STACK}" == "true" ]]; then
  if [[ "${INSTALL_HELM}" != "true" ]]; then
    echo "WARN: INSTALL_PROMETHEUS_STACK is true but INSTALL_HELM is false. Skipping kube-prometheus-stack installation." >&2
  elif ! command -v helm &>/dev/null; then
    echo "WARN: Helm is not installed. Skipping kube-prometheus-stack installation." >&2
  else
    log "Step 15: Install kube-prometheus-stack (includes Prometheus Operator, Prometheus, Grafana)"
    echo "The kube-prometheus-stack Helm chart includes:"
    echo "  - Prometheus Operator: Manages Prometheus instances"
    echo "  - Prometheus: Metrics collection and storage"
    echo "  - Grafana: Visualization and dashboards (automatically included)"
    echo "  - Alertmanager: Alert handling"
    echo "  - Node Exporter: Node metrics"
    echo "  - Kube State Metrics: Kubernetes object metrics"
    echo ""
    echo "Custom resources provided:"
    echo "  - PodMonitor: Automatically discovers and scrapes metrics from pods based on label selectors"
    echo "  - ServiceMonitor: Similar to PodMonitor but works with Services"
    echo "  - PrometheusRule: Defines alerting and recording rules"
    
    sudo -u "${PRIMARY_USER}" -H helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    sudo -u "${PRIMARY_USER}" -H helm repo update
    
    # Values allow PodMonitors to be picked up that are outside of the kube-prometheus-stack helm release
    sudo -u "${PRIMARY_USER}" -H helm install prometheus -n monitoring --create-namespace \
      prometheus-community/kube-prometheus-stack \
      --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
      --set prometheus.prometheusSpec.podMonitorNamespaceSelector="{}" \
      --set prometheus.prometheusSpec.probeNamespaceSelector="{}" \
      --wait --timeout 10m || {
        echo "WARN: kube-prometheus-stack installation may have failed or is still in progress." >&2
        echo "Check status with: kubectl get pods -n monitoring" >&2
      }
    
    echo ""
    echo "kube-prometheus-stack installed in 'monitoring' namespace"
    echo "Grafana is included in the stack and available at:"
    echo "  kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
    echo "Default Grafana credentials: admin / prom-operator"
  fi
fi

log "Step 16: Show final cluster status"
sudo -u "${PRIMARY_USER}" -H kubectl get nodes -o wide
sudo -u "${PRIMARY_USER}" -H kubectl get pods -A

log "DONE ✅"
echo "kubectl is configured for: ${PRIMARY_USER}"
echo "Try: kubectl create deployment hello --image=nginx && kubectl get pods -o wide"
if [[ "${ENABLE_HUBBLE}" == "true" ]]; then
  echo "Hubble UI (optional): run 'cilium hubble ui' and open the printed local URL."
fi
if [[ "${INSTALL_HELM}" == "true" ]]; then
  echo "Helm installed: $(helm version 2>/dev/null | head -1 || true)"
fi
if [[ "${INSTALL_PROMETHEUS_STACK}" == "true" && "${INSTALL_HELM}" == "true" ]] && command -v helm &>/dev/null; then
  echo "kube-prometheus-stack installed in 'monitoring' namespace"
  echo "  - Prometheus Operator, Prometheus, Grafana, and monitoring components"
  echo "  - Access Grafana: kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
fi
