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

K8S_REPO_MINOR="${K8S_REPO_MINOR:-v1.36}"
# Used only when the selected Kubernetes repo does not yet publish dependency
# packages required by kubeadm/kubelet, such as cri-tools and kubernetes-cni.
K8S_DEP_REPO_MINOR="${K8S_DEP_REPO_MINOR:-v1.35}"
CLUSTER_NAME="${CLUSTER_NAME:-k8s-single}"
POD_CIDR="${POD_CIDR:-10.0.0.0/16}"
ENABLE_HUBBLE="${ENABLE_HUBBLE:-true}"

# Helm install (Helm 4 example; override if you want something else)
HELM_VERSION="${HELM_VERSION:-v4.1.0}"   # e.g. v4.1.0, v4.0.5, v3.20.0, ...
INSTALL_HELM="${INSTALL_HELM:-true}"     # true/false

# kube-prometheus-stack install (requires Helm)
INSTALL_PROMETHEUS_STACK="${INSTALL_PROMETHEUS_STACK:-true}"  # true/false

# Resume support. Completed step markers are stored under K8S_INSTALL_STATE_DIR
# so reruns can continue after the last successfully completed step.
RESUME_INSTALL="${RESUME_INSTALL:-true}"
RESET_RESUME_STATE="${RESET_RESUME_STATE:-false}"
K8S_INSTALL_STATE_ROOT="${K8S_INSTALL_STATE_ROOT:-/var/lib/dynamo-k8s-llm-inference}"
K8S_INSTALL_STATE_DIR="${K8S_INSTALL_STATE_DIR:-}"
K8S_STEP_DIR=""

#------------------------------#
# Helpers                      #
#------------------------------#

log() { echo -e "\n==> $*\n"; }

validate_bool() {
  local name="$1"
  local value="$2"

  case "${value}" in
    true|false) ;;
    *)
      echo "ERROR: ${name} must be true or false; got '${value}'." >&2
      exit 1
      ;;
  esac
}

resume_fingerprint_input() {
  cat <<EOF
K8S_REPO_MINOR=${K8S_REPO_MINOR}
K8S_DEP_REPO_MINOR=${K8S_DEP_REPO_MINOR}
CLUSTER_NAME=${CLUSTER_NAME}
POD_CIDR=${POD_CIDR}
ENABLE_HUBBLE=${ENABLE_HUBBLE}
HELM_VERSION=${HELM_VERSION}
INSTALL_HELM=${INSTALL_HELM}
INSTALL_PROMETHEUS_STACK=${INSTALL_PROMETHEUS_STACK}
EOF
}

configure_resume_state() {
  local fingerprint

  fingerprint="$(resume_fingerprint_input | cksum | awk '{print $1}')"

  if [[ -z "${K8S_INSTALL_STATE_DIR}" ]]; then
    K8S_INSTALL_STATE_DIR="${K8S_INSTALL_STATE_ROOT}/k8s-single-node-cilium-${fingerprint}"
  fi
  K8S_STEP_DIR="${K8S_INSTALL_STATE_DIR}/steps"

  if [[ "${RESET_RESUME_STATE}" == "true" ]]; then
    echo "RESET_RESUME_STATE=true -> clearing ${K8S_INSTALL_STATE_DIR}"
    rm -rf "${K8S_INSTALL_STATE_DIR}"
  fi

  mkdir -p "${K8S_STEP_DIR}"
  resume_fingerprint_input >"${K8S_INSTALL_STATE_DIR}/config.txt"
}

step_marker() {
  local step_name="$1"
  printf '%s/%s.done' "${K8S_STEP_DIR}" "${step_name}"
}

step_done() {
  local step_name="$1"

  [[ "${RESUME_INSTALL}" == "true" && -f "$(step_marker "${step_name}")" ]]
}

mark_step_done() {
  local step_name="$1"

  if [[ "${RESUME_INSTALL}" != "true" ]]; then
    return 0
  fi

  date -u +"%Y-%m-%dT%H:%M:%SZ" >"$(step_marker "${step_name}")"
}

run_step() {
  local step_name="$1"
  shift

  if step_done "${step_name}"; then
    echo "Resume: skipping completed step '${step_name}'."
    return 0
  fi

  "$@"
  mark_step_done "${step_name}"
}

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

apt_has_candidate() {
  local pkg="$1"
  local candidate
  candidate="$(apt-cache policy "${pkg}" | awk '/Candidate:/ {print $2; exit}')"
  [[ -n "${candidate}" && "${candidate}" != "(none)" ]]
}

write_kubernetes_apt_source() {
  local minor="$1"
  local list_file="$2"

  cat >"${list_file}" <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${minor}/deb/ /
EOF
}

ensure_kubernetes_package_dependencies_available() {
  local missing=()
  local pkg

  for pkg in cri-tools kubernetes-cni; do
    if ! apt_has_candidate "${pkg}"; then
      missing+=("${pkg}")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return 0
  fi

  if [[ -z "${K8S_DEP_REPO_MINOR}" ]]; then
    echo "ERROR: Kubernetes repo ${K8S_REPO_MINOR} does not expose required package(s): ${missing[*]}" >&2
    echo "Set K8S_DEP_REPO_MINOR to a Kubernetes repo minor that provides them." >&2
    exit 1
  fi

  if [[ "${K8S_DEP_REPO_MINOR}" == "${K8S_REPO_MINOR}" ]]; then
    echo "ERROR: Kubernetes repo ${K8S_REPO_MINOR} does not expose required package(s): ${missing[*]}" >&2
    echo "K8S_DEP_REPO_MINOR is also ${K8S_DEP_REPO_MINOR}, so no fallback repo is available." >&2
    exit 1
  fi

  log "Kubernetes ${K8S_REPO_MINOR} repo is missing dependency package(s): ${missing[*]}"
  echo "Adding Kubernetes ${K8S_DEP_REPO_MINOR} as a dependency fallback repo."
  write_kubernetes_apt_source "${K8S_DEP_REPO_MINOR}" /etc/apt/sources.list.d/kubernetes-dependencies.list
  apt-get update -y

  missing=()
  for pkg in cri-tools kubernetes-cni; do
    if ! apt_has_candidate "${pkg}"; then
      missing+=("${pkg}")
    fi
  done

  if [[ "${#missing[@]}" -ne 0 ]]; then
    echo "ERROR: Still missing Kubernetes dependency package(s): ${missing[*]}" >&2
    exit 1
  fi
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
  rm -rf "${tmp}"

  helm version || true
}

update_os_packages() {
  log "Step 1: Update OS packages"
  apt-get update -y
  apt-get upgrade -y
}

install_base_dependencies() {
  log "Step 2: Install base dependencies"
  apt-get install -y \
    curl wget gnupg ca-certificates apt-transport-https lsb-release
}

disable_swap() {
  log "Step 3: Disable swap"
  swapoff -a
  sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
}

load_kernel_modules() {
  log "Step 4: Load kernel modules"
  cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter
}

configure_sysctl_params() {
  log "Step 5: Set sysctl params"
  cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system
}

install_containerd_step() {
  log "Step 6: Install containerd"
  apt-get install -y containerd
}

configure_containerd_step() {
  log "Step 7: Configure containerd (systemd cgroups)"
  mkdir -p /etc/containerd
  containerd config default >/etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

  systemctl enable containerd
  systemctl restart containerd
}

install_kubernetes_packages() {
  log "Step 8: Install kubeadm/kubelet/kubectl from pkgs.k8s.io"
  if already_initialized && command -v kubeadm >/dev/null 2>&1 && command -v kubelet >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1; then
    echo "Kubernetes packages are already installed on an initialized control-plane; skipping package install."
  else
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/deb/Release.key" \
      | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    rm -f /etc/apt/sources.list.d/kubernetes-dependencies.list
    write_kubernetes_apt_source "${K8S_REPO_MINOR}" /etc/apt/sources.list.d/kubernetes.list

    apt-get update -y
    ensure_kubernetes_package_dependencies_available
    apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
    apt-get install -y cri-tools kubernetes-cni kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl
    systemctl enable kubelet
  fi
}

install_helm_step() {
  if [[ "${INSTALL_HELM}" != "true" ]]; then
    echo "INSTALL_HELM=${INSTALL_HELM}; skipping Helm installation."
    return 0
  fi

  arch="$(detect_arch)"
  install_helm_from_get_helm_sh "${arch}" "${HELM_VERSION}"
}

initialize_control_plane() {
  log "Step 9: Initialize Kubernetes control plane with kubeadm (single-node cluster)"
  if already_initialized; then
    echo "Kubernetes control-plane already initialized; skipping kubeadm init."
  else
    kubeadm init \
      --pod-network-cidr="${POD_CIDR}" \
      --node-name="$(hostname -s)"
  fi
}

configure_kubectl_step() {
  log "Step 10: Configure kubectl for ${PRIMARY_USER}"
  install -d -m 0755 "${PRIMARY_HOME}/.kube"
  cp -f /etc/kubernetes/admin.conf "${PRIMARY_HOME}/.kube/config"
  chown -R "${PRIMARY_USER}:${PRIMARY_USER}" "${PRIMARY_HOME}/.kube"

  sudo -u "${PRIMARY_USER}" -H bash <<'EOF'
set -euo pipefail

RC_FILE="${HOME}/.bashrc"
{
  grep -Fqx "alias k=kubectl" "${RC_FILE}" || echo "alias k=kubectl"
  grep -Fqx "source <(kubectl completion bash)" "${RC_FILE}" || echo "source <(kubectl completion bash)"
  grep -Fqx "complete -F __start_kubectl k" "${RC_FILE}" || echo "complete -F __start_kubectl k"
} >> "${RC_FILE}"
EOF
}

install_cilium_cli_step() {
  local cilium_cli_version
  local cli_arch
  local tmpdir

  log "Step 11: Install Cilium CLI"
  cilium_cli_version="$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)"
  cli_arch="$(detect_arch)"

  tmpdir="$(mktemp -d)"

  (
    cd "${tmpdir}"
    curl -L --fail --remote-name-all \
      "https://github.com/cilium/cilium-cli/releases/download/${cilium_cli_version}/cilium-linux-${cli_arch}.tar.gz" \
      "https://github.com/cilium/cilium-cli/releases/download/${cilium_cli_version}/cilium-linux-${cli_arch}.tar.gz.sha256sum"
    sha256sum --check "cilium-linux-${cli_arch}.tar.gz.sha256sum"
    tar xzvf "cilium-linux-${cli_arch}.tar.gz" -C /usr/local/bin
  )
  rm -rf "${tmpdir}"
}

install_cilium_cni_step() {
  log "Step 12: Install Cilium CNI"
  if sudo -u "${PRIMARY_USER}" -H kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
    echo "Cilium already appears to be installed; skipping cilium install."
    if [[ "${ENABLE_HUBBLE}" == "true" ]]; then
      sudo -u "${PRIMARY_USER}" -H cilium hubble enable --ui || true
    fi
  else
    if [[ "${ENABLE_HUBBLE}" == "true" ]]; then
      sudo -u "${PRIMARY_USER}" -H cilium install \
        --set hubble.enabled=true \
        --set hubble.relay.enabled=true \
        --set hubble.ui.enabled=true
    else
      sudo -u "${PRIMARY_USER}" -H cilium install
    fi
  fi
}

allow_control_plane_scheduling() {
  log "Step 13: Allow scheduling on the control-plane node (IMPORTANT for 1-node clusters)"
  # Must happen BEFORE `cilium status --wait` if Hubble is enabled,
  # otherwise hubble-ui/relay will remain Pending due to the taint.
  sudo -u "${PRIMARY_USER}" -H kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
  sudo -u "${PRIMARY_USER}" -H kubectl taint nodes --all node-role.kubernetes.io/master- 2>/dev/null || true
}

wait_for_cilium_ready() {
  log "Step 14: Wait for Cilium to become ready"
  sudo -u "${PRIMARY_USER}" -H cilium status --wait
}

install_prometheus_stack_step() {
  local prometheus_values_file

  if [[ "${INSTALL_PROMETHEUS_STACK}" != "true" ]]; then
    echo "INSTALL_PROMETHEUS_STACK=${INSTALL_PROMETHEUS_STACK}; skipping kube-prometheus-stack installation."
    return 0
  fi

  if [[ "${INSTALL_HELM}" != "true" ]]; then
    echo "WARN: INSTALL_PROMETHEUS_STACK is true but INSTALL_HELM is false. Skipping kube-prometheus-stack installation." >&2
    return 0
  fi

  if ! command -v helm &>/dev/null; then
    echo "WARN: Helm is not installed. Skipping kube-prometheus-stack installation." >&2
    return 0
  fi

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

  sudo -u "${PRIMARY_USER}" -H helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  sudo -u "${PRIMARY_USER}" -H helm repo update

  prometheus_values_file="${PRIMARY_HOME}/.prometheus-values-$$.yaml"
  sudo -u "${PRIMARY_USER}" -H bash <<EOF
cat > "${prometheus_values_file}" <<'INNER_EOF'
prometheus:
  prometheusSpec:
    podMonitorSelectorNilUsesHelmValues: false
    podMonitorNamespaceSelector: {}
    probeNamespaceSelector: {}
INNER_EOF
EOF

  sudo -u "${PRIMARY_USER}" -H helm upgrade --install prometheus -n monitoring --create-namespace \
    prometheus-community/kube-prometheus-stack \
    --values "${prometheus_values_file}" \
    --wait --timeout 10m || {
      echo "WARN: kube-prometheus-stack installation may have failed or is still in progress." >&2
      echo "Check status with: kubectl get pods -n monitoring" >&2
    }

  sudo -u "${PRIMARY_USER}" -H rm -f "${prometheus_values_file}"

  echo ""
  echo "kube-prometheus-stack installed in 'monitoring' namespace"
  echo "Grafana is included in the stack and available at:"
  echo "  kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"

  log "Waiting for Grafana secret to be available..."
  for i in {1..60}; do
    if sudo -u "${PRIMARY_USER}" -H kubectl get secret -n monitoring prometheus-grafana >/dev/null 2>&1; then
      break
    fi
    if [[ $i -eq 60 ]]; then
      echo "WARN: Grafana secret not found after waiting. Using default credentials." >&2
      echo "Default Grafana credentials: admin / prom-operator"
      break
    fi
    sleep 2
  done

  if sudo -u "${PRIMARY_USER}" -H kubectl get secret -n monitoring prometheus-grafana >/dev/null 2>&1; then
    echo "Fetching Grafana admin credentials..."
    GRAFANA_USER="$(sudo -u "${PRIMARY_USER}" -H kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-user}" 2>/dev/null | base64 -d 2>/dev/null || echo "admin")"
    export GRAFANA_USER
    GRAFANA_PASSWORD="$(sudo -u "${PRIMARY_USER}" -H kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d 2>/dev/null || echo "prom-operator")"
    export GRAFANA_PASSWORD
    echo "Grafana credentials exported:"
    echo "  GRAFANA_USER=${GRAFANA_USER}"
    echo "  GRAFANA_PASSWORD=${GRAFANA_PASSWORD}"
  else
    echo "Default Grafana credentials: admin / prom-operator"
    export GRAFANA_USER="admin"
    export GRAFANA_PASSWORD="prom-operator"
  fi
}

show_final_cluster_status() {
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
}

#------------------------------#
# Main                         #
#------------------------------#

require_root
detect_primary_user
validate_bool ENABLE_HUBBLE "${ENABLE_HUBBLE}"
validate_bool INSTALL_HELM "${INSTALL_HELM}"
validate_bool INSTALL_PROMETHEUS_STACK "${INSTALL_PROMETHEUS_STACK}"
validate_bool RESUME_INSTALL "${RESUME_INSTALL}"
validate_bool RESET_RESUME_STATE "${RESET_RESUME_STATE}"
configure_resume_state

log "Sanity checks"
# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID}" != "ubuntu" ]]; then
  echo "ERROR: This script expects Ubuntu. Detected: ${ID}" >&2
  exit 1
fi

if already_initialized; then
  echo "A Kubernetes control-plane already seems initialized on this machine."
  echo "Found: /etc/kubernetes/admin.conf"
  echo "Continuing in resume mode: kubeadm init will be skipped."
fi

echo "Resume state directory: ${K8S_INSTALL_STATE_DIR}"

run_step "01_os_packages" update_os_packages
run_step "02_base_dependencies" install_base_dependencies
run_step "03_disable_swap" disable_swap
run_step "04_kernel_modules" load_kernel_modules
run_step "05_sysctl" configure_sysctl_params
run_step "06_containerd_install" install_containerd_step
run_step "07_containerd_config" configure_containerd_step
run_step "08_kubernetes_packages" install_kubernetes_packages
run_step "09_helm" install_helm_step
run_step "10_kubeadm_init" initialize_control_plane
run_step "11_kubectl_config" configure_kubectl_step
run_step "12_cilium_cli" install_cilium_cli_step
run_step "13_cilium_cni" install_cilium_cni_step
run_step "14_control_plane_scheduling" allow_control_plane_scheduling
run_step "15_cilium_ready" wait_for_cilium_ready
run_step "16_prometheus_stack" install_prometheus_stack_step

show_final_cluster_status
