#!/usr/bin/env bash
# verify-bootstrap-packages.sh - TerraPilot Bootstrap Package Verification
# This script is read-only. It checks installed packages, tool versions,
# service status, and TerraPilot status markers.
# Required tools: must be present or the script exits with failure.
# Optional tools: may be missing; shown as [OPTIONAL MISSING] without failing.
# It does NOT install, delete, restart, stop, or modify anything.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

OK=0
MISSING=0
WARN=0
OPTIONAL_MISSING=0

export PATH="/usr/local/go/bin:/usr/local/bin:$PATH"

declare -A REQ_CMD_SET=()
declare -A OPT_CMD_SET=()
declare -A OPT_PKG_SET=()
declare -A REQ_SVC_SET=()
declare -A OPT_SVC_SET=()
declare -A MARKER_SET=()
declare -A FILE_SET=()
declare -A OPT_MARKER_SET=()
declare -A OPT_FILE_SET=()

add_required_cmd() { REQ_CMD_SET["$1"]=1; unset "OPT_CMD_SET[$1]" 2>/dev/null || true; }
add_optional_cmd() { [ -n "${REQ_CMD_SET[$1]:-}" ] || OPT_CMD_SET["$1"]=1; }
add_optional_pkg() { OPT_PKG_SET["$1"]=1; }
add_required_svc() { REQ_SVC_SET["$1"]=1; unset "OPT_SVC_SET[$1]" 2>/dev/null || true; }
add_optional_svc() { [ -n "${REQ_SVC_SET[$1]:-}" ] || OPT_SVC_SET["$1"]=1; }
add_marker() { MARKER_SET["$1"]=1; }
add_file() { FILE_SET["$1"]=1; }
add_optional_marker() { [ -n "${MARKER_SET[$1]:-}" ] || OPT_MARKER_SET["$1"]=1; }
add_optional_file() { [ -n "${FILE_SET[$1]:-}" ] || OPT_FILE_SET["$1"]=1; }

add_metadata_for_script() {
  local script_key="$1"
  case "$script_key" in
    'scripts/kubernetes-master/base-packages.sh')
      add_required_cmd 'curl'
      add_required_cmd 'wget'
      add_required_cmd 'unzip'
      add_required_cmd 'git'
      add_optional_cmd 'gpg'
      add_optional_pkg 'curl'
      add_optional_pkg 'wget'
      add_optional_pkg 'unzip'
      add_optional_pkg 'git'
      add_optional_pkg 'ca-certificates'
      add_optional_pkg 'gnupg'
      ;;
    'scripts/kubernetes-master/install-helm.sh')
      add_required_cmd 'helm'
      add_optional_pkg 'helm'
      ;;
    'scripts/kubernetes-master/install-kubectl-cli.sh')
      add_required_cmd 'kubectl'
      add_optional_pkg 'kubectl'
      ;;
    'scripts/kubernetes-master/install-nginx.sh')
      add_required_cmd 'nginx'
      add_optional_pkg 'nginx'
      add_required_svc 'nginx'
      ;;
    'scripts/common-setup.sh')
      add_required_cmd 'containerd'
      add_required_cmd 'kubelet'
      add_required_cmd 'kubeadm'
      add_required_cmd 'kubectl'
      add_optional_pkg 'containerd.io'
      add_optional_pkg 'kubelet'
      add_optional_pkg 'kubeadm'
      add_optional_pkg 'kubectl'
      add_required_svc 'containerd'
      add_required_svc 'kubelet'
      add_marker '/opt/terrapilot/status/common.success'
      ;;
    'scripts/kubernetes-master/kubernetes-master-user-data.sh')
      add_required_cmd 'kubeadm'
      add_required_cmd 'kubectl'
      add_optional_pkg 'kubeadm'
      add_optional_pkg 'kubectl'
      add_required_svc 'kubelet'
      add_marker '/opt/terrapilot/status/master.success'
      add_file '/etc/kubernetes/admin.conf'
      ;;
    'scripts/kubernetes-worker/base-packages.sh')
      add_required_cmd 'curl'
      add_required_cmd 'wget'
      add_required_cmd 'unzip'
      add_required_cmd 'git'
      add_optional_cmd 'gpg'
      add_optional_pkg 'curl'
      add_optional_pkg 'wget'
      add_optional_pkg 'unzip'
      add_optional_pkg 'git'
      add_optional_pkg 'ca-certificates'
      add_optional_pkg 'gnupg'
      ;;
    'scripts/kubernetes-worker/install-kubectl-cli.sh')
      add_required_cmd 'kubectl'
      add_optional_pkg 'kubectl'
      ;;
    'scripts/kubernetes-worker/install-nginx.sh')
      add_required_cmd 'nginx'
      add_optional_pkg 'nginx'
      add_required_svc 'nginx'
      ;;
    'scripts/kubernetes-worker/kubernetes-worker-user-data.sh')
      add_required_cmd 'kubeadm'
      add_required_cmd 'kubectl'
      add_optional_pkg 'kubeadm'
      add_optional_pkg 'kubectl'
      add_required_svc 'kubelet'
      add_marker '/opt/terrapilot/status/worker.success'
      ;;
    *)
      echo -e "  ${YELLOW}[WARNING]${NC} No verification metadata for selected script: $script_key"
      WARN=$((WARN+1))
      ;;
  esac
}

add_optional_metadata_for_script() {
  local script_key="$1"
  case "$script_key" in
    'scripts/kubernetes-master/base-packages.sh')
      add_optional_cmd 'curl'
      add_optional_cmd 'wget'
      add_optional_cmd 'unzip'
      add_optional_cmd 'git'
      add_optional_cmd 'gpg'
      add_optional_pkg 'curl'
      add_optional_pkg 'wget'
      add_optional_pkg 'unzip'
      add_optional_pkg 'git'
      add_optional_pkg 'ca-certificates'
      add_optional_pkg 'gnupg'
      ;;
    'scripts/kubernetes-master/install-helm.sh')
      add_optional_cmd 'helm'
      add_optional_pkg 'helm'
      ;;
    'scripts/kubernetes-master/install-kubectl-cli.sh')
      add_optional_cmd 'kubectl'
      add_optional_pkg 'kubectl'
      ;;
    'scripts/kubernetes-master/install-nginx.sh')
      add_optional_cmd 'nginx'
      add_optional_pkg 'nginx'
      add_optional_svc 'nginx'
      ;;
    'scripts/common-setup.sh')
      add_optional_cmd 'containerd'
      add_optional_cmd 'kubelet'
      add_optional_cmd 'kubeadm'
      add_optional_cmd 'kubectl'
      add_optional_pkg 'containerd.io'
      add_optional_pkg 'kubelet'
      add_optional_pkg 'kubeadm'
      add_optional_pkg 'kubectl'
      add_optional_svc 'containerd'
      add_optional_svc 'kubelet'
      add_optional_marker '/opt/terrapilot/status/common.success'
      ;;
    'scripts/kubernetes-master/kubernetes-master-user-data.sh')
      add_optional_cmd 'kubeadm'
      add_optional_cmd 'kubectl'
      add_optional_pkg 'kubeadm'
      add_optional_pkg 'kubectl'
      add_optional_svc 'kubelet'
      add_optional_marker '/opt/terrapilot/status/master.success'
      add_optional_file '/etc/kubernetes/admin.conf'
      ;;
    'scripts/kubernetes-worker/base-packages.sh')
      add_optional_cmd 'curl'
      add_optional_cmd 'wget'
      add_optional_cmd 'unzip'
      add_optional_cmd 'git'
      add_optional_cmd 'gpg'
      add_optional_pkg 'curl'
      add_optional_pkg 'wget'
      add_optional_pkg 'unzip'
      add_optional_pkg 'git'
      add_optional_pkg 'ca-certificates'
      add_optional_pkg 'gnupg'
      ;;
    'scripts/kubernetes-worker/install-kubectl-cli.sh')
      add_optional_cmd 'kubectl'
      add_optional_pkg 'kubectl'
      ;;
    'scripts/kubernetes-worker/install-nginx.sh')
      add_optional_cmd 'nginx'
      add_optional_pkg 'nginx'
      add_optional_svc 'nginx'
      ;;
    'scripts/kubernetes-worker/kubernetes-worker-user-data.sh')
      add_optional_cmd 'kubeadm'
      add_optional_cmd 'kubectl'
      add_optional_pkg 'kubeadm'
      add_optional_pkg 'kubectl'
      add_optional_svc 'kubelet'
      add_optional_marker '/opt/terrapilot/status/worker.success'
      ;;
    *)
      echo -e "  ${YELLOW}[WARNING]${NC} No optional verification metadata for selected S3 script: $script_key"
      WARN=$((WARN+1))
      ;;
  esac
}

add_role_fallback_metadata() {
  local role="$1"
  case "$role" in
    'kubernetes-master')
      add_required_cmd 'curl'
      add_required_cmd 'wget'
      add_required_cmd 'unzip'
      add_required_cmd 'git'
      add_required_cmd 'helm'
      add_required_cmd 'kubectl'
      add_required_cmd 'nginx'
      add_required_cmd 'containerd'
      add_required_cmd 'kubelet'
      add_required_cmd 'kubeadm'
      add_optional_cmd 'gpg'
      add_optional_pkg 'curl'
      add_optional_pkg 'wget'
      add_optional_pkg 'unzip'
      add_optional_pkg 'git'
      add_optional_pkg 'ca-certificates'
      add_optional_pkg 'gnupg'
      add_optional_pkg 'helm'
      add_optional_pkg 'kubectl'
      add_optional_pkg 'nginx'
      add_optional_pkg 'containerd.io'
      add_optional_pkg 'kubelet'
      add_optional_pkg 'kubeadm'
      add_required_svc 'nginx'
      add_required_svc 'containerd'
      add_required_svc 'kubelet'
      add_marker '/opt/terrapilot/status/common.success'
      add_marker '/opt/terrapilot/status/master.success'
      add_file '/etc/kubernetes/admin.conf'
      ;;
    'kubernetes-worker')
      add_required_cmd 'curl'
      add_required_cmd 'wget'
      add_required_cmd 'unzip'
      add_required_cmd 'git'
      add_required_cmd 'kubectl'
      add_required_cmd 'nginx'
      add_required_cmd 'containerd'
      add_required_cmd 'kubelet'
      add_required_cmd 'kubeadm'
      add_optional_cmd 'gpg'
      add_optional_pkg 'curl'
      add_optional_pkg 'wget'
      add_optional_pkg 'unzip'
      add_optional_pkg 'git'
      add_optional_pkg 'ca-certificates'
      add_optional_pkg 'gnupg'
      add_optional_pkg 'kubectl'
      add_optional_pkg 'nginx'
      add_optional_pkg 'containerd.io'
      add_optional_pkg 'kubelet'
      add_optional_pkg 'kubeadm'
      add_required_svc 'nginx'
      add_required_svc 'containerd'
      add_required_svc 'kubelet'
      add_marker '/opt/terrapilot/status/common.success'
      add_marker '/opt/terrapilot/status/worker.success'
      ;;
    *)
      echo -e "  ${YELLOW}[WARNING]${NC} Unknown instance role for verification fallback: ${role:-unset}"
      WARN=$((WARN+1))
      ;;
  esac
}

add_all_known_optional_metadata() {
  add_optional_cmd 'curl'
  add_optional_cmd 'wget'
  add_optional_cmd 'unzip'
  add_optional_cmd 'git'
  add_optional_cmd 'helm'
  add_optional_cmd 'kubectl'
  add_optional_cmd 'nginx'
  add_optional_cmd 'containerd'
  add_optional_cmd 'kubelet'
  add_optional_cmd 'kubeadm'
  add_optional_cmd 'gpg'
  add_optional_pkg 'curl'
  add_optional_pkg 'wget'
  add_optional_pkg 'unzip'
  add_optional_pkg 'git'
  add_optional_pkg 'ca-certificates'
  add_optional_pkg 'gnupg'
  add_optional_pkg 'helm'
  add_optional_pkg 'kubectl'
  add_optional_pkg 'nginx'
  add_optional_pkg 'containerd.io'
  add_optional_pkg 'kubelet'
  add_optional_pkg 'kubeadm'
  add_optional_svc 'nginx'
  add_optional_svc 'containerd'
  add_optional_svc 'kubelet'
}

command_exists() {
  local cmd="$1"
  case "$cmd" in
    "docker compose") command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 ;;
    buildx) command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1 ;;
    *) command -v "$cmd" >/dev/null 2>&1 ;;
  esac
}

version_for_cmd() {
  local cmd="$1"
  case "$cmd" in
    curl) curl --version 2>&1 | head -n 1 ;;
    wget) wget --version 2>&1 | head -n 1 ;;
    unzip) unzip -v 2>&1 | head -n 1 ;;
    git) git --version 2>&1 | head -n 1 ;;
    node) node --version 2>&1 | head -n 1 ;;
    npm) npm --version 2>&1 | head -n 1 ;;
    python3) python3 --version 2>&1 | head -n 1 ;;
    pip3) pip3 --version 2>&1 | head -n 1 ;;
    java) java -version 2>&1 | head -n 1 ;;
    javac) javac -version 2>&1 | head -n 1 ;;
    go) go version 2>&1 | head -n 1 ;;
    ansible) ansible --version 2>&1 | head -n 1 ;;
    ansible-playbook) ansible-playbook --version 2>&1 | head -n 1 ;;
    helm) helm version --short 2>&1 | head -n 1 ;;
    containerd) containerd --version 2>&1 | head -n 1 ;;
    kubelet) kubelet --version 2>&1 | head -n 1 ;;
    kubeadm) kubeadm version -o short 2>&1 | head -n 1 ;;
    kubectl) kubectl version --client=true 2>&1 | head -n 1 ;;
    docker) docker --version 2>&1 | head -n 1 ;;
    "docker compose") docker compose version 2>&1 | head -n 1 ;;
    buildx) docker buildx version 2>&1 | head -n 1 ;;
    terraform) terraform version 2>&1 | head -n 1 ;;
    aws) aws --version 2>&1 | head -n 1 ;;
    az) az version 2>&1 | head -n 1 ;;
    gcloud) gcloud --version 2>&1 | head -n 1 ;;
    trivy) trivy --version 2>&1 | head -n 1 ;;
    psql) psql --version 2>&1 | head -n 1 ;;
    redis-cli) redis-cli --version 2>&1 | head -n 1 ;;
    *) "$cmd" --version 2>&1 | head -n 1 || true ;;
  esac
}

check_cmd() {
  local cmd="$1"
  if command_exists "$cmd"; then
    local ver
    ver="$(version_for_cmd "$cmd" || true)"
    echo -e "  ${GREEN}[OK]${NC}    command found: ${BOLD}$cmd${NC}${ver:+ -> $ver}"
    OK=$((OK+1))
  else
    echo -e "  ${RED}[MISSING]${NC} $cmd command not found"
    MISSING=$((MISSING+1))
  fi
}

check_cmd_optional() {
  local cmd="$1"
  if command_exists "$cmd"; then
    local ver
    ver="$(version_for_cmd "$cmd" || true)"
    echo -e "  ${GREEN}[OK]${NC}    command found: ${BOLD}$cmd${NC}${ver:+ -> $ver}"
    OK=$((OK+1))
  else
    echo -e "  ${YELLOW}[OPTIONAL MISSING]${NC} $cmd (not required)"
    OPTIONAL_MISSING=$((OPTIONAL_MISSING+1))
  fi
}

check_service() {
  local svc="$1"
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo -e "  ${GREEN}[OK]${NC}    ${BOLD}$svc${NC} service is active"
    OK=$((OK+1))
  elif systemctl list-unit-files "$svc.service" >/dev/null 2>&1; then
    echo -e "  ${YELLOW}[WARNING]${NC} $svc service is installed but not running"
    WARN=$((WARN+1))
  else
    echo -e "  ${RED}[MISSING]${NC} $svc service not found"
    MISSING=$((MISSING+1))
  fi
}

check_service_optional() {
  local svc="$1"
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo -e "  ${GREEN}[OK]${NC}    ${BOLD}$svc${NC} service is active"
    OK=$((OK+1))
  elif systemctl list-unit-files "$svc.service" >/dev/null 2>&1; then
    echo -e "  ${YELLOW}[WARNING]${NC} $svc service is installed but not running"
    WARN=$((WARN+1))
  else
    echo -e "  ${YELLOW}[OPTIONAL MISSING]${NC} $svc service not found (not required)"
    OPTIONAL_MISSING=$((OPTIONAL_MISSING+1))
  fi
}

apt_pkg_installed() {
  local pkg="$1"
  dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null | grep -q '^ii'
}

rpm_pkg_installed() {
  local pkg="$1"
  rpm -q "$pkg" >/dev/null 2>&1
}

pkg_installed() {
  local pkg="$1"
  case "$PKG_MGR:$pkg" in
    apt:containerd.io|apt:containerd) apt_pkg_installed containerd.io || apt_pkg_installed containerd || command_exists containerd ;;
    apt:helm) apt_pkg_installed helm || command_exists helm ;;
    apt:ansible|apt:ansible-core) apt_pkg_installed ansible || apt_pkg_installed ansible-core || { command_exists ansible && command_exists ansible-playbook; } ;;
    apt:awscli) apt_pkg_installed awscli || command_exists aws ;;
    apt:google-cloud-cli) apt_pkg_installed google-cloud-cli || command_exists gcloud ;;
    apt:azure-cli) apt_pkg_installed azure-cli || command_exists az ;;
    apt:terraform) apt_pkg_installed terraform || command_exists terraform ;;
    apt:trivy) apt_pkg_installed trivy || command_exists trivy ;;
    apt:*) apt_pkg_installed "$pkg" ;;
    yum:containerd.io|yum:containerd|dnf:containerd.io|dnf:containerd|rpm:containerd.io|rpm:containerd) rpm_pkg_installed containerd.io || rpm_pkg_installed containerd || command_exists containerd ;;
    yum:helm|dnf:helm|rpm:helm) rpm_pkg_installed helm || command_exists helm ;;
    yum:ansible|yum:ansible-core|dnf:ansible|dnf:ansible-core|rpm:ansible|rpm:ansible-core) rpm_pkg_installed ansible || rpm_pkg_installed ansible-core || { command_exists ansible && command_exists ansible-playbook; } ;;
    yum:*|dnf:*|rpm:*) rpm_pkg_installed "$pkg" ;;
    *) return 1 ;;
  esac
}

check_pkg_optional() {
  local pkg="$1"
  if pkg_installed "$pkg"; then
    echo -e "  ${GREEN}[OK]${NC}    package/installer evidence found: $pkg"
    OK=$((OK+1))
  else
    echo -e "  ${YELLOW}[OPTIONAL MISSING]${NC} $pkg package evidence not found (command checks are authoritative)"
    OPTIONAL_MISSING=$((OPTIONAL_MISSING+1))
  fi
}

check_marker() {
  local marker="$1"
  if [ -f "$marker" ]; then
    echo -e "  ${GREEN}[OK]${NC}    status marker found: $marker"
    OK=$((OK+1))
  else
    echo -e "  ${YELLOW}[WARNING]${NC} status marker missing: $marker"
    WARN=$((WARN+1))
  fi
}

check_file() {
  local filepath="$1"
  if [ -f "$filepath" ]; then
    echo -e "  ${GREEN}[OK]${NC}    file found: $filepath"
    OK=$((OK+1))
  else
    echo -e "  ${YELLOW}[WARNING]${NC} file missing: $filepath"
    WARN=$((WARN+1))
  fi
}

check_marker_optional() {
  local marker="$1"
  if [ -f "$marker" ]; then
    echo -e "  ${GREEN}[OK]${NC}    optional status marker found: $marker"
    OK=$((OK+1))
  else
    echo -e "  ${YELLOW}[OPTIONAL MISSING]${NC} optional status marker missing: $marker"
    OPTIONAL_MISSING=$((OPTIONAL_MISSING+1))
  fi
}

check_file_optional() {
  local filepath="$1"
  if [ -f "$filepath" ]; then
    echo -e "  ${GREEN}[OK]${NC}    optional file found: $filepath"
    OK=$((OK+1))
  else
    echo -e "  ${YELLOW}[OPTIONAL MISSING]${NC} optional file missing: $filepath"
    OPTIONAL_MISSING=$((OPTIONAL_MISSING+1))
  fi
}

echo ""
echo -e "${BOLD}========================================"
echo -e " TerraPilot Bootstrap Package Verification"
echo -e "========================================${NC}"
echo ""

# Detect OS family
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_FAMILY="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"
else
  OS_FAMILY="unknown"
  OS_VERSION="unknown"
fi
echo -e "${CYAN}Detected OS:${NC} $OS_FAMILY $OS_VERSION"

# Detect package manager
if command -v apt-get >/dev/null 2>&1; then
  PKG_MGR="apt"
elif command -v yum >/dev/null 2>&1; then
  PKG_MGR="yum"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MGR="dnf"
elif command -v rpm >/dev/null 2>&1; then
  PKG_MGR="rpm"
else
  PKG_MGR="unknown"
fi
echo -e "${CYAN}Package manager:${NC} $PKG_MGR"
echo ""

INSTANCE_ROLE="${INSTANCE_ROLE:-}"
if [ -z "$INSTANCE_ROLE" ] && [ -f /opt/terrapilot/instance-role ]; then
  INSTANCE_ROLE="$(tr -d '[:space:]' < /opt/terrapilot/instance-role)"
fi
if [ -z "$INSTANCE_ROLE" ]; then
  INSTANCE_ROLE="default"
fi
echo -e "${CYAN}Instance role:${NC} $INSTANCE_ROLE"

PLAN_FILE=""
for candidate in /opt/terrapilot/status/bootstrap-plan.txt /tmp/bootstrap-plan.json; do
  if [ -f "$candidate" ]; then
    PLAN_FILE="$candidate"
    break
  fi
done
if [ -n "$PLAN_FILE" ]; then
  echo -e "${CYAN}Bootstrap plan:${NC} $PLAN_FILE"
else
  echo -e "${YELLOW}[WARNING]${NC} No bootstrap plan found; using generated fallback metadata for role $INSTANCE_ROLE"
  WARN=$((WARN+1))
fi

SELECTED_SCRIPT_COUNT=0
OPTIONAL_SCRIPT_COUNT=0
if [ -n "$PLAN_FILE" ] && command -v jq >/dev/null 2>&1; then
  echo -e "${CYAN}Reading bootstrap plan entries:${NC} selected_scripts and optional_s3_scripts"
  while IFS= read -r script_key; do
    [ -n "$script_key" ] || continue
    SELECTED_SCRIPT_COUNT=$((SELECTED_SCRIPT_COUNT+1))
    add_metadata_for_script "$script_key"
  done < <(jq -r --arg role "$INSTANCE_ROLE" '.roles[$role].selected_scripts[]?' "$PLAN_FILE" 2>/dev/null || true)
  while IFS= read -r script_key; do
    [ -n "$script_key" ] || continue
    OPTIONAL_SCRIPT_COUNT=$((OPTIONAL_SCRIPT_COUNT+1))
    add_optional_metadata_for_script "$script_key"
  done < <(jq -r --arg role "$INSTANCE_ROLE" '.roles[$role].optional_s3_scripts[]?' "$PLAN_FILE" 2>/dev/null || true)
elif [ -n "$PLAN_FILE" ]; then
  echo -e "${YELLOW}[WARNING]${NC} jq is unavailable; using generated fallback metadata for role $INSTANCE_ROLE"
  WARN=$((WARN+1))
fi

if [ "$SELECTED_SCRIPT_COUNT" -eq 0 ]; then
  add_role_fallback_metadata "$INSTANCE_ROLE"
else
  echo -e "${CYAN}Selected scripts for role:${NC} $SELECTED_SCRIPT_COUNT"
fi
if [ "$OPTIONAL_SCRIPT_COUNT" -gt 0 ]; then
  echo -e "${CYAN}Optional S3 scripts for role:${NC} $OPTIONAL_SCRIPT_COUNT"
fi
add_all_known_optional_metadata
echo ""

if [ ${#REQ_CMD_SET[@]} -gt 0 ]; then
  echo -e "${BOLD}--- Required Tool Version Checks For $INSTANCE_ROLE ---${NC}"
  for cmd in "${!REQ_CMD_SET[@]}"; do
    check_cmd "$cmd"
  done
  echo ""
fi

if [ ${#OPT_CMD_SET[@]} -gt 0 ]; then
  echo -e "${BOLD}--- Optional / Not Selected Tool Version Checks ---${NC}"
  for cmd in "${!OPT_CMD_SET[@]}"; do
    check_cmd_optional "$cmd"
  done
  echo ""
fi

if [ ${#OPT_PKG_SET[@]} -gt 0 ]; then
  echo -e "${BOLD}--- Optional Package Evidence Cross-Checks ---${NC}"
  for pkg in "${!OPT_PKG_SET[@]}"; do
    check_pkg_optional "$pkg"
  done
  echo ""
fi

if [ ${#REQ_SVC_SET[@]} -gt 0 ]; then
  echo -e "${BOLD}--- Required Service Status For $INSTANCE_ROLE ---${NC}"
  for svc in "${!REQ_SVC_SET[@]}"; do
    check_service "$svc"
  done
  echo ""
fi

if [ ${#OPT_SVC_SET[@]} -gt 0 ]; then
  echo -e "${BOLD}--- Optional Service Status ---${NC}"
  for svc in "${!OPT_SVC_SET[@]}"; do
    check_service_optional "$svc"
  done
  echo ""
fi

echo -e "${BOLD}--- TerraPilot Status ---${NC}"
if [ -d /opt/terrapilot/status ]; then
  echo -e "  ${GREEN}[OK]${NC}    /opt/terrapilot/status directory found"
  ls -la /opt/terrapilot/status/ 2>/dev/null || true
else
  echo -e "  ${YELLOW}[WARNING]${NC} /opt/terrapilot/status directory not found"
  WARN=$((WARN+1))
fi

for marker in "${!MARKER_SET[@]}"; do
  check_marker "$marker"
done
for marker in "${!OPT_MARKER_SET[@]}"; do
  check_marker_optional "$marker"
done
if [ -f /opt/terrapilot/status/userdata.failed ]; then
  echo -e "  ${RED}[WARNING]${NC} userdata.failed found - bootstrap had errors"
  WARN=$((WARN+1))
fi

for filepath in "${!FILE_SET[@]}"; do
  check_file "$filepath"
done
for filepath in "${!OPT_FILE_SET[@]}"; do
  check_file_optional "$filepath"
done
echo ""
echo -e "${BOLD}========================================"
echo -e " Summary"
echo -e "========================================${NC}"
echo -e "  ${GREEN}OK:${NC}                $OK"
echo -e "  ${RED}Missing (required):${NC}  $MISSING"
echo -e "  ${YELLOW}Warnings:${NC}           $WARN"
echo -e "  ${CYAN}Optional missing:${NC}    $OPTIONAL_MISSING"
echo ""
if [ -f /opt/terrapilot/status/scripts-ran.log ]; then
  echo -e "${CYAN}--- Scripts Run Log ---${NC}"
  cat /opt/terrapilot/status/scripts-ran.log
  echo ""
fi
if [ $MISSING -gt 0 ]; then
  echo -e "${RED}Some required tools are missing. Check /var/log/cloud-init-output.log for details.${NC}"
  exit 1
elif [ $WARN -gt 0 ]; then
  echo -e "${YELLOW}Verification completed with warnings. All required tools are present.${NC}"
  exit 0
else
  echo -e "${GREEN}All required packages and services are present.${NC}"
  exit 0
fi