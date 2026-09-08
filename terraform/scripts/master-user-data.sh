#!/bin/bash
set -Eeuo pipefail

export AWS_REGION="${aws_region}"
export TERRAPILOT_SSM_JOIN_PRIVATE_PATH="${ssm_join_private_path}"
export TERRAPILOT_SSM_JOIN_PUBLIC_PATH="${ssm_join_public_path}"

LOG_FILE="/var/log/terrapilot-userdata.log"
STATUS_DIR="/opt/terrapilot/status"
COMMAND_DIR="/opt/terrapilot/commands"
mkdir -p "$STATUS_DIR" "$COMMAND_DIR"

exec > >(tee -a "$LOG_FILE" | logger -t terrapilot-userdata -s 2>/dev/console) 2>&1

echo "========================================"
echo "TerraPilot user data started: $(date)"
echo "========================================"

log() {
  echo "[TerraPilot][master][$(date -Is)] $*"
}

fail() {
  rm -f "$STATUS_DIR/userdata.success"
  echo "$*" > "$STATUS_DIR/userdata.failed"
  log "FAILED: $*"
  exit 1
}

on_error() {
  local line="$1"
  local command="$2"
  local exit_code="$3"
  mkdir -p "$STATUS_DIR"
  rm -f "$STATUS_DIR/userdata.success"
  {
    echo "failed at line $line"
    echo "exit code: $exit_code"
    echo "command: $command"
  } | tee "$STATUS_DIR/userdata.failed"
  log "FAILED at line $line with exit code $exit_code: $command"
}

trap 'on_error "$LINENO" "$BASH_COMMAND" "$?"' ERR

success() {
  rm -f "$STATUS_DIR/userdata.failed"
  echo "success" > "$STATUS_DIR/userdata.success"
  echo "success" > /opt/terrapilot/status/master.success
  log "SUCCESS: $*"
}

get_metadata() {
  local path="$1"
  local token
  token="$(curl -fsS --max-time 3 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"
  if [ -n "$token" ]; then
    curl -fsS --max-time 3 -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$${path}" || true
  else
    curl -fsS --max-time 3 "http://169.254.169.254/latest/meta-data/$${path}" || true
  fi
}

install_aws_cli_v2() {
  if command -v aws >/dev/null 2>&1; then
    log "AWS CLI already installed: $(aws --version 2>&1)"
    return 0
  fi

  log "Installing AWS CLI v2 from the official AWS installer"
  apt-get update -y
  apt-get install -y curl unzip ca-certificates

  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
    aarch64|arm64) AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
    *) fail "Unsupported architecture for AWS CLI v2: $ARCH" ;;
  esac

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' RETURN
  curl -fsSL "$AWSCLI_URL" -o "$TMP_DIR/awscliv2.zip"
  unzip -q "$TMP_DIR/awscliv2.zip" -d "$TMP_DIR"
  "$TMP_DIR/aws/install" --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli
  aws --version || fail "AWS CLI missing; SSM automatic worker join cannot work."
  log "AWS CLI v2 installed successfully"
}

run_as_ubuntu() {
  sudo -H -u ubuntu KUBECONFIG=/home/ubuntu/.kube/config "$@"
}

retry_command() {
  local attempts="$1"
  local delay="$2"
  local description="$3"
  shift 3
  local attempt exit_code
  for attempt in $(seq 1 "$attempts"); do
    log "$description (attempt $attempt/$attempts)"
    if "$@"; then
      return 0
    fi
    exit_code=$?
    log "$description failed with exit code $exit_code"
    if [ "$attempt" -lt "$attempts" ]; then
      sleep "$delay"
    fi
  done
  return "$exit_code"
}

wait_for_api() {
  log "Waiting for Kubernetes API..."
  for i in {1..90}; do
    if run_as_ubuntu kubectl get nodes >/dev/null 2>&1; then
      log "Kubernetes API is ready."
      return 0
    fi
    sleep 5
  done
  fail "Kubernetes API did not become ready."
}

dump_calico_diagnostics() {
  log "Collecting Calico diagnostics."
  {
    echo "### Calico CRDs"
    run_as_ubuntu kubectl get crd | grep -E 'tigera|calico|projectcalico' || true
    echo
    echo "### Tigera operator resources"
    run_as_ubuntu kubectl get all -n tigera-operator -o wide || true
    echo
    echo "### Calico/Tigera resources"
    run_as_ubuntu kubectl get all -A -o wide | grep -Ei 'calico|tigera' || true
    echo
    echo "### Tigera status"
    run_as_ubuntu kubectl get tigerastatus -A -o wide || true
    echo
    echo "### Recent events"
    run_as_ubuntu kubectl get events -A --sort-by=.lastTimestamp | tail -n 80 || true
    echo
    echo "### Tigera operator logs"
    run_as_ubuntu kubectl -n tigera-operator logs deployment/tigera-operator --tail=120 || true
  } | tee "$STATUS_DIR/calico-diagnostics.log"
}

wait_for_crd() {
  local crd="$1"
  for i in {1..60}; do
    if run_as_ubuntu kubectl get crd "$crd" >/dev/null 2>&1; then
      run_as_ubuntu kubectl wait --for condition=Established --timeout=180s "crd/$crd"
      return 0
    fi
    sleep 5
  done
  dump_calico_diagnostics
  fail "Calico CRD $crd was not created."
}

install_calico() {
  log "Installing Calico CNI..."
  retry_command 12 10 "Apply Calico Tigera operator manifest" run_as_ubuntu kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.7/manifests/tigera-operator.yaml || fail "Calico Tigera operator manifest failed to apply."
  wait_for_crd installations.operator.tigera.io
  wait_for_crd apiservers.operator.tigera.io
  retry_command 30 10 "Wait for Tigera operator rollout" run_as_ubuntu kubectl -n tigera-operator rollout status deployment/tigera-operator --timeout=60s || {
    dump_calico_diagnostics
    fail "Tigera operator deployment did not roll out."
  }
  retry_command 12 10 "Apply Calico custom resources" run_as_ubuntu kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.7/manifests/custom-resources.yaml || {
    dump_calico_diagnostics
    fail "Calico custom resources failed to apply."
  }

  log "Waiting for Calico/Tigera pods to become Running and Ready..."
  for i in {1..120}; do
    pods="$(run_as_ubuntu kubectl get pods -A --no-headers 2>/dev/null | awk 'tolower($1 " " $2) ~ /calico|tigera/ {print}' || true)"
    calico_nodes="$(printf '%s\n' "$pods" | awk 'tolower($1 " " $2) ~ /calico-node/ {print}')"
    if [ -n "$pods" ] && [ -n "$calico_nodes" ]; then
      not_ready="$(printf '%s\n' "$pods" | awk '{ split($3, ready, "/"); if ($4 != "Running" || ready[1] != ready[2] || ready[2] == "0") print }')"
      if [ -z "$not_ready" ]; then
        log "Calico/Tigera pods are Running and Ready."
        return 0
      fi
      log "Calico/Tigera pods exist but are not ready yet:"
      printf '%s\n' "$not_ready"
    else
      log "Waiting for Calico node pods to be created..."
    fi
    if [ "$i" -eq 120 ]; then
      break
    fi
    sleep 5
  done

  run_as_ubuntu kubectl get pods -A || true
  dump_calico_diagnostics
  fail "Calico/Tigera pods did not become Running and Ready."
}

generate_kubeconfigs() {
  local private_ip="$1"
  local public_ip="$2"

  mkdir -p /home/ubuntu/.kube /root/.kube
  cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
  cp /etc/kubernetes/admin.conf /root/.kube/config
  chown -R ubuntu:ubuntu /home/ubuntu/.kube
  grep -q "KUBECONFIG=/home/ubuntu/.kube/config" /home/ubuntu/.bashrc 2>/dev/null || echo "export KUBECONFIG=/home/ubuntu/.kube/config" >> /home/ubuntu/.bashrc

  cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config-private
  kubectl --kubeconfig=/home/ubuntu/.kube/config-private config set-cluster kubernetes --server="https://$${private_ip}:6443"
  cp /home/ubuntu/.kube/config-private /home/ubuntu/kubeconfig-private

  if [ -n "$public_ip" ]; then
    cp /home/ubuntu/.kube/config-private /home/ubuntu/.kube/config-public
    kubectl --kubeconfig=/home/ubuntu/.kube/config-public config set-cluster kubernetes --server="https://$${public_ip}:6443"
    cp /home/ubuntu/.kube/config-public /home/ubuntu/kubeconfig-public
  else
    echo "No public IP detected. Public kubeconfig was not generated." > /home/ubuntu/PUBLIC_KUBECONFIG_WARNING.txt
    log "WARNING: No public IP detected. Public kubeconfig not generated."
  fi

  chown -R ubuntu:ubuntu /home/ubuntu/.kube /home/ubuntu/kubeconfig-* 2>/dev/null || true
}

generate_kubeconfig_base64_exports() {
  local private_ip="$1"
  local public_ip="$2"
  log "Generating base64 kubeconfig exports for GitHub Actions."

  if [ ! -f /home/ubuntu/kubeconfig-private ]; then
    fail "Private kubeconfig was not generated."
  fi

  if ! grep -q "server: https://$${private_ip}:6443" /home/ubuntu/kubeconfig-private; then
    grep "server:" /home/ubuntu/kubeconfig-private || true
    fail "Private kubeconfig does not contain private API endpoint $${private_ip}."
  fi

  base64 -w 0 /home/ubuntu/kubeconfig-private > /home/ubuntu/kubeconfig-private.b64
  chmod 600 /home/ubuntu/kubeconfig-private.b64
  chown ubuntu:ubuntu /home/ubuntu/kubeconfig-private.b64

  if ! base64 -d /home/ubuntu/kubeconfig-private.b64 2>/dev/null | grep -q "server: https://$${private_ip}:6443"; then
    base64 -d /home/ubuntu/kubeconfig-private.b64 2>/dev/null | grep "server:" || true
    fail "Private base64 kubeconfig does not decode to private API endpoint $${private_ip}."
  fi

  if [ -n "$public_ip" ]; then
    if [ ! -f /home/ubuntu/kubeconfig-public ]; then
      fail "Public IP exists but public kubeconfig was not generated."
    fi
    if ! grep -q "server: https://$${public_ip}:6443" /home/ubuntu/kubeconfig-public; then
      grep "server:" /home/ubuntu/kubeconfig-public || true
      fail "Public kubeconfig does not contain public API endpoint $${public_ip}."
    fi
    if grep -q "server: https://$${private_ip}:6443" /home/ubuntu/kubeconfig-public; then
      grep "server:" /home/ubuntu/kubeconfig-public || true
      fail "Public kubeconfig still contains private API endpoint $${private_ip}."
    fi

    base64 -w 0 /home/ubuntu/kubeconfig-public > /home/ubuntu/kubeconfig-public.b64
    chmod 600 /home/ubuntu/kubeconfig-public.b64
    chown ubuntu:ubuntu /home/ubuntu/kubeconfig-public.b64

    if ! base64 -d /home/ubuntu/kubeconfig-public.b64 2>/dev/null | grep -q "server: https://$${public_ip}:6443"; then
      base64 -d /home/ubuntu/kubeconfig-public.b64 2>/dev/null | grep "server:" || true
      fail "Public base64 kubeconfig does not decode to public API endpoint $${public_ip}."
    fi
    if base64 -d /home/ubuntu/kubeconfig-public.b64 2>/dev/null | grep -q "server: https://$${private_ip}:6443"; then
      base64 -d /home/ubuntu/kubeconfig-public.b64 2>/dev/null | grep "server:" || true
      fail "Public base64 kubeconfig still decodes to private API endpoint $${private_ip}."
    fi
    cat > /home/ubuntu/KUBE_CONFIG_DATA_INSTRUCTIONS.txt <<EOF
Public kubeconfig base64:
/home/ubuntu/kubeconfig-public.b64
Purpose: GitHub Actions, local laptop, or external kubectl access. It contains public API endpoint https://$${public_ip}:6443.

For GitHub Actions Secret KUBE_CONFIG_DATA, copy this value:
cat /home/ubuntu/kubeconfig-public.b64

Private kubeconfig base64:
/home/ubuntu/kubeconfig-private.b64
Purpose: inside-VPC/internal use only. It contains private API endpoint https://$${private_ip}:6443.

Do not use /home/ubuntu/kubeconfig-private.b64 for GitHub Actions unless the runner is inside the same private network/VPC.
If your KUBE_CONFIG_DATA contains a private IP like 10.x.x.x, GitHub Actions and external laptops will not be able to reach the Kubernetes API server.

Troubleshooting:
base64 -d /home/ubuntu/kubeconfig-public.b64 | grep "server:"
base64 -d /home/ubuntu/kubeconfig-private.b64 | grep "server:"

The kubeconfig contains cluster-admin credentials. Store it only in GitHub Secrets or another encrypted secret manager.
Do not paste raw kubeconfig YAML. Do not paste /etc/kubernetes/admin.conf as a path. Paste the full base64 output.
EOF
  else
    cat > /home/ubuntu/KUBE_CONFIG_DATA_INSTRUCTIONS.txt <<EOF
Private kubeconfig base64:
/home/ubuntu/kubeconfig-private.b64
Purpose: inside-VPC/internal use only. It contains private API endpoint https://$${private_ip}:6443.

Public kubeconfig base64:
Not generated because no public IP was detected.

GitHub-hosted runners and external laptops cannot use the private kubeconfig unless they can route into this VPC.
Do not use /home/ubuntu/kubeconfig-private.b64 for GitHub Actions unless the runner is inside the same private network/VPC.
If your KUBE_CONFIG_DATA contains a private IP like 10.x.x.x, GitHub Actions and external laptops will not be able to reach the Kubernetes API server.

Troubleshooting:
base64 -d /home/ubuntu/kubeconfig-private.b64 | grep "server:"
EOF
  fi

  chmod 600 /home/ubuntu/KUBE_CONFIG_DATA_INSTRUCTIONS.txt
  chown ubuntu:ubuntu /home/ubuntu/KUBE_CONFIG_DATA_INSTRUCTIONS.txt
}

put_ssm_parameter_with_retry() {
  local path="$1"
  local value="$2"
  local label="$3"
  retry_command 24 5 "Publish $label join command to SSM Parameter Store"     aws ssm put-parameter --name "$path" --type "SecureString" --value "$value" --overwrite --region "$${AWS_REGION}"     || fail "Unable to publish $label join command to SSM Parameter Store. Check the EC2 instance profile has ssm:PutParameter for $path."
}

write_join_command_to_ssm() {
  local private_ip="$1"
  local public_ip="$2"
  local ssm_private_path="$${TERRAPILOT_SSM_JOIN_PRIVATE_PATH}"
  local ssm_public_path="$${TERRAPILOT_SSM_JOIN_PUBLIC_PATH}"

  log "Generating worker join command..."
  JOIN_COMMAND="$(kubeadm token create --print-join-command)"
  case "$JOIN_COMMAND" in
    *"--cri-socket"*) JOIN_PRIVATE="$JOIN_COMMAND" ;;
    *) JOIN_PRIVATE="$JOIN_COMMAND --cri-socket=unix:///run/containerd/containerd.sock" ;;
  esac

  echo "#!/bin/bash" > /home/ubuntu/join-worker-private.sh
  echo "$JOIN_PRIVATE" >> /home/ubuntu/join-worker-private.sh

  put_ssm_parameter_with_retry "$ssm_private_path" "$JOIN_PRIVATE" "private"

  if [ -n "$public_ip" ]; then
    JOIN_PUBLIC="$(echo "$JOIN_PRIVATE" | sed "s/$${private_ip}/$${public_ip}/g")"
    echo "#!/bin/bash" > /home/ubuntu/join-worker-public.sh
    echo "$JOIN_PUBLIC" >> /home/ubuntu/join-worker-public.sh
    put_ssm_parameter_with_retry "$ssm_public_path" "$JOIN_PUBLIC" "public"
  else
    cp /home/ubuntu/join-worker-private.sh /home/ubuntu/join-worker-public.sh
  fi

  cp /home/ubuntu/join-worker-private.sh "$COMMAND_DIR/join-worker-private.sh"
  cp /home/ubuntu/join-worker-public.sh "$COMMAND_DIR/join-worker-public.sh"

  chown ubuntu:ubuntu /home/ubuntu/join-worker-private.sh /home/ubuntu/join-worker-public.sh
  chmod +x /home/ubuntu/join-worker-private.sh /home/ubuntu/join-worker-public.sh
  chmod +x "$COMMAND_DIR/join-worker-private.sh" "$COMMAND_DIR/join-worker-public.sh"
  log "Join command stored in SSM Parameter Store."
}

switch_default_kubeconfig_to_public() {
  if [ -z "$${PUBLIC_IP:-}" ]; then
    log "No public IP detected. Keeping default kubeconfig on the private API endpoint."
    return 0
  fi

  log "Switching default kubeconfig to public API endpoint: $PUBLIC_IP"
  kubectl --kubeconfig=/home/ubuntu/.kube/config config set-cluster kubernetes --server="https://$${PUBLIC_IP}:6443"
  kubectl --kubeconfig=/root/.kube/config config set-cluster kubernetes --server="https://$${PUBLIC_IP}:6443"
  chown -R ubuntu:ubuntu /home/ubuntu/.kube
}



main() {
  log "Starting Kubernetes master bootstrap."
  echo "kubernetes-master" > /opt/terrapilot/instance-role
  echo "kubernetes-master" > /opt/terrapilot/role
  echo "master-user-data.sh" >> "$STATUS_DIR/scripts-ran.log"
  mkdir -p /opt/terrapilot/scripts /opt/terrapilot/bin /opt/terrapilot/commands /opt/terrapilot/status
cat > /opt/terrapilot/scripts/common-setup.sh <<'TERRAPILOT_COMMON_SETUP'
#!/bin/bash
set -euo pipefail
log() {
  echo "[TerraPilot][common][$(date -Is)] $*"
}
install_aws_cli_v2() {
  if command -v aws >/dev/null 2>&1; then
    log "AWS CLI already installed: $(aws --version 2>&1)"
    return 0
  fi
  log "Installing AWS CLI v2 from the official AWS installer"
  apt-get update -y
  apt-get install -y curl unzip ca-certificates
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
    aarch64|arm64) AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
    *) echo "Unsupported architecture for AWS CLI v2: $ARCH" >&2; return 1 ;;
  esac
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' RETURN
  curl -fsSL "$AWSCLI_URL" -o "$TMP_DIR/awscliv2.zip"
  unzip -q "$TMP_DIR/awscliv2.zip" -d "$TMP_DIR"
  "$TMP_DIR/aws/install" --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli
  aws --version
}
echo "[TerraPilot] Step 1/5: Updating packages"
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab || true
modprobe overlay
modprobe br_netfilter
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system
echo "[TerraPilot] Step 2/5: Installing containerd"
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl unzip gpg
apt-get install -y unzip
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable containerd
systemctl restart containerd
echo "[TerraPilot] Step 3/5: Installing Kubernetes tools"
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet
echo "[TerraPilot] Step 4/5: Preparing verification directories"
mkdir -p /opt/terrapilot/status /opt/terrapilot/commands /opt/terrapilot/bin
if [ "$${TERRAPILOT_REQUIRE_AWS_CLI:-false}" = "true" ]; then
  echo "[TerraPilot] Step 5/5: Installing AWS CLI v2 for SSM worker auto-join"
  install_aws_cli_v2 || {
    echo "AWS CLI missing; SSM automatic worker join cannot work." >&2
    exit 1
  }
else
  echo "[TerraPilot] Step 5/5: AWS CLI not required for manual worker join mode"
fi
echo "[TerraPilot] Step 5/5: Common Kubernetes setup complete"


mkdir -p /opt/terrapilot/status
echo "success" > /opt/terrapilot/status/common.success

TERRAPILOT_COMMON_SETUP
chmod +x /opt/terrapilot/scripts/common-setup.sh
cat > /opt/terrapilot/bin/verify-kubernetes-infra.sh <<'TERRAPILOT_VERIFY'
#!/bin/bash
set +e

PASSED=0
WARNED=0
FAILED=0
CONTROL_PLANE_READY=FAIL
CALICO_READY=FAIL
NODES_READY=FAIL
COREDNS_READY=FAIL
WORKER_AUTO_JOIN=DISABLED
PUBLIC_KUBECONFIG=WARN
INSTANCE_ROLE="unknown"
AWS_REGION="${aws_region}"
TERRAPILOT_SSM_JOIN_PRIVATE_PATH="${ssm_join_private_path}"
TERRAPILOT_SSM_AUTO_JOIN="${ssm_auto_join_enabled}"
TMP_STATUS="$(mktemp)"
trap 'rm -f "$TMP_STATUS"' EXIT

pass() { echo "[PASS] $1"; PASSED=$((PASSED + 1)); }
warn() { echo "[WARN] $1"; WARNED=$((WARNED + 1)); }
fail() { echo "[FAIL] $1"; FAILED=$((FAILED + 1)); }
check_cmd() { command -v "$1" >/dev/null 2>&1 && pass "$1 is installed" || fail "$1 is not installed"; }
check_file() { [ -f "$1" ] && pass "$1 found" || fail "$1 not found"; }
check_optional_file() { [ -f "$1" ] && pass "$1 found" || warn "$1 not found"; }
as_kubectl() { KUBECONFIG=/etc/kubernetes/admin.conf kubectl "$@"; }
calico_ready() {
  local pods
  local not_ready
  pods="$(as_kubectl get pods -A --no-headers 2>/dev/null | awk 'tolower($1 " " $2) ~ /calico|tigera/ {print}' || true)"
  if [ -z "$pods" ]; then
    return 1
  fi
  not_ready="$(printf '%s\n' "$pods" | awk '{ split($3, ready, "/"); if ($4 != "Running" || ready[1] != ready[2] || ready[2] == "0") print }')"
  if [ -n "$not_ready" ]; then
    echo "$not_ready"
    return 1
  fi
  return 0
}
get_metadata() {
  local path="$1"
  local token
  token="$(curl -fsS --max-time 3 -X PUT     "http://169.254.169.254/latest/api/token"     -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"

  if [ -n "$token" ]; then
    curl -fsS --max-time 3       -H "X-aws-ec2-metadata-token: $token"       "http://169.254.169.254/latest/meta-data/$${path}" || true
  else
    echo ""
  fi
}

echo "TerraPilot Kubernetes Verification"
echo "=================================="
if [ -f /opt/terrapilot/instance-role ]; then
  INSTANCE_ROLE="$(cat /opt/terrapilot/instance-role)"
  echo "Instance role: $INSTANCE_ROLE"
elif [ -f /opt/terrapilot/role ]; then
  INSTANCE_ROLE="$(cat /opt/terrapilot/role)"
  echo "Instance role: $INSTANCE_ROLE"
else
  warn "instance role marker missing from /opt/terrapilot/instance-role"
fi
if [ -f /opt/terrapilot/status/scripts-ran.log ]; then
  echo "Scripts ran:"
  cat /opt/terrapilot/status/scripts-ran.log
else
  warn "scripts-ran log missing"
fi

cloud-init status --long >"$TMP_STATUS" 2>&1 && pass "cloud-init status command works" || warn "cloud-init status unavailable"
cat "$TMP_STATUS" || true
[ -f /opt/terrapilot/status/common.success ] && pass "common setup marker exists" || warn "common setup marker missing"
[ -f /var/log/terrapilot-userdata.log ] && pass "TerraPilot user-data log exists" || warn "TerraPilot user-data log missing"
[ -f /opt/terrapilot/status/userdata.success ] && pass "user-data success marker exists" || warn "user-data success marker missing"
[ -f /opt/terrapilot/status/userdata.failed ] && fail "user-data failure marker exists" || pass "no user-data failure marker"

echo
echo "System"
cat /etc/os-release 2>/dev/null || true
hostname
hostname -I || true
ip route || true
curl -fsSI --max-time 5 https://pkgs.k8s.io >/dev/null && pass "internet access test passed" || warn "internet access test failed"

echo
echo "Container runtime"
systemctl is-active --quiet containerd && pass "containerd is active" || fail "containerd is not active"
containerd --version >/dev/null 2>&1 && pass "containerd version available" || warn "containerd version unavailable"
runc --version >/dev/null 2>&1 && pass "runc version available" || warn "runc version unavailable"
[ -d /etc/cni/net.d ] && pass "CNI directory exists" || warn "CNI directory missing"
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock info >/dev/null 2>&1 && pass "crictl info works with containerd endpoint" || warn "crictl info failed with containerd endpoint"

echo
echo "Kernel and Kubernetes prerequisites"
lsmod | grep -q overlay && pass "overlay module loaded" || warn "overlay module not loaded"
lsmod | grep -q br_netfilter && pass "br_netfilter module loaded" || warn "br_netfilter module not loaded"
[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ] && pass "net.ipv4.ip_forward is enabled" || warn "net.ipv4.ip_forward is not enabled"
[ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)" = "1" ] && pass "bridge-nf-call-iptables is enabled" || warn "bridge-nf-call-iptables is not enabled"
swapon --summary | grep -q . && fail "swap is enabled" || pass "swap is disabled"

echo
echo "Kubernetes tools"
if ! command -v kubeadm >/dev/null 2>&1 || ! command -v kubectl >/dev/null 2>&1 || ! command -v kubelet >/dev/null 2>&1; then
  fail "Kubernetes tools were never installed. Check common-setup.sh and /var/log/terrapilot-userdata.log before debugging kubeadm init."
else
  pass "kubeadm, kubelet, and kubectl are installed"
fi
if [ "$INSTANCE_ROLE" != "kubernetes-worker" ] && command -v kubeadm >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1 && [ ! -f /etc/kubernetes/admin.conf ]; then
  fail "Common setup completed, but control-plane was not initialized. This instance likely ran common-setup.sh only."
fi
if [ "$TERRAPILOT_SSM_AUTO_JOIN" = "true" ]; then
  if command -v aws >/dev/null 2>&1; then
    aws --version && pass "AWS CLI is installed for SSM automatic worker join" || fail "AWS CLI exists but aws --version failed"
  else
    fail "AWS CLI missing; SSM automatic worker join cannot work."
  fi
fi
systemctl status kubelet --no-pager || true

echo
echo "Kubeconfig"
check_optional_file /etc/kubernetes/admin.conf
check_optional_file /home/ubuntu/.kube/config
check_optional_file /home/ubuntu/.kube/config-private
check_optional_file /home/ubuntu/.kube/config-public
check_optional_file /home/ubuntu/kubeconfig-private
check_optional_file /home/ubuntu/kubeconfig-public
check_optional_file /home/ubuntu/kubeconfig-private.b64
check_optional_file /home/ubuntu/kubeconfig-public.b64
check_optional_file /home/ubuntu/KUBE_CONFIG_DATA_INSTRUCTIONS.txt
check_optional_file /opt/terrapilot/bin/generate-kubeconfig-github.sh
command -v generate-kubeconfig-github >/dev/null 2>&1 && pass "generate-kubeconfig-github command is installed" || warn "generate-kubeconfig-github command is not installed"

PRIVATE_IP="$(hostname -I | awk '{print $1}')"
PUBLIC_IP="$(get_metadata public-ipv4)"
if [ -f /home/ubuntu/kubeconfig-private ] && grep -q "$PRIVATE_IP" /home/ubuntu/kubeconfig-private; then
  pass "private kubeconfig contains private IP $PRIVATE_IP"
else
  warn "private kubeconfig does not contain detected private IP $PRIVATE_IP"
fi
if [ -f /home/ubuntu/kubeconfig-private.b64 ]; then
  if base64 -d /home/ubuntu/kubeconfig-private.b64 2>/dev/null | grep -q "server: https://$PRIVATE_IP:6443"; then
    pass "private base64 kubeconfig decodes and contains private API endpoint"
  else
    fail "private base64 kubeconfig is invalid or does not contain private API endpoint"
  fi
else
  warn "private base64 kubeconfig file is missing"
fi
if [ -n "$PUBLIC_IP" ]; then
  if [ -f /home/ubuntu/kubeconfig-public ] && grep -q "$PUBLIC_IP" /home/ubuntu/kubeconfig-public; then
    pass "public kubeconfig contains public IP $PUBLIC_IP"
  else
    fail "public IP exists but public kubeconfig does not contain $PUBLIC_IP"
  fi
  if [ -f /home/ubuntu/kubeconfig-public.b64 ]; then
    if base64 -d /home/ubuntu/kubeconfig-public.b64 2>/dev/null | grep -q "server: https://$PUBLIC_IP:6443"; then
      pass "public base64 kubeconfig decodes and contains public API endpoint"
    else
      fail "public base64 kubeconfig is invalid or does not contain public API endpoint"
    fi
    if base64 -d /home/ubuntu/kubeconfig-public.b64 2>/dev/null | grep -q "server: https://$PRIVATE_IP:6443"; then
      fail "public base64 kubeconfig still contains private API endpoint $PRIVATE_IP"
    else
      pass "public base64 kubeconfig does not contain private API endpoint"
    fi
  else
    fail "public IP exists but public base64 kubeconfig is missing"
  fi
else
  warn "no public IP detected from instance metadata"
fi

echo
echo "Control plane checks"
if [ -f /etc/kubernetes/admin.conf ]; then
  CONTROL_PLANE_READY=PASS
  as_kubectl get nodes -o wide && pass "kubectl get nodes works" || warn "kubectl get nodes failed"
  as_kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -q "Ready" && NODES_READY=PASS
  as_kubectl get pods -A -o wide || true
  as_kubectl cluster-info || true
  kubeadm token list || true
  if calico_ready; then
    pass "Calico/Tigera pods are Running and Ready"
    CALICO_READY=PASS
  else
    fail "Calico/Tigera pods are not Running and Ready"
  fi
  as_kubectl -n kube-system get pods -l k8s-app=kube-dns 2>/dev/null | grep -q "Running" && COREDNS_READY=PASS
  check_optional_file /home/ubuntu/join-worker-private.sh
  check_optional_file /home/ubuntu/join-worker-public.sh
  check_optional_file /opt/terrapilot/commands/join-worker-private.sh
  check_optional_file /opt/terrapilot/commands/join-worker-public.sh
  if [ "$TERRAPILOT_SSM_AUTO_JOIN" = "true" ]; then
    WORKER_AUTO_JOIN=FAIL
    if command -v aws >/dev/null 2>&1; then
      aws ssm get-parameter --name "$TERRAPILOT_SSM_JOIN_PRIVATE_PATH" --with-decryption --region "$AWS_REGION" --query Parameter.Value --output text >/dev/null 2>&1 && WORKER_AUTO_JOIN=PASS
    fi
  else
    WORKER_AUTO_JOIN=SKIPPED/DISABLED
  fi
else
  warn "not a control-plane node or admin.conf missing"
fi

echo
echo "Worker checks"
check_optional_file /etc/kubernetes/kubelet.conf
systemctl status kubelet --no-pager || true
systemctl is-active --quiet kubelet && pass "kubelet is active" || warn "kubelet is not active"
journalctl -u kubelet -n 100 --no-pager || true
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps || true

if [ -f /home/ubuntu/kubeconfig-public ]; then
  PUBLIC_KUBECONFIG=PASS
elif [ -f /home/ubuntu/PUBLIC_KUBECONFIG_WARNING.txt ]; then
  PUBLIC_KUBECONFIG=WARN
fi


echo
echo "kagent is disabled for this deployment. No kagent pods are expected."


echo
echo "TerraPilot Kubernetes Verification Summary"
echo "Passed: $PASSED"
echo "Warnings: $WARNED"
echo "Failed: $FAILED"
echo "PASS/FAIL: Control plane initialized = $CONTROL_PLANE_READY"
echo "PASS/FAIL: Calico installed = $CALICO_READY"
echo "PASS/FAIL: Nodes Ready = $NODES_READY"
echo "PASS/FAIL: CoreDNS Running = $COREDNS_READY"
echo "PASS/FAIL/SKIPPED: Worker auto-join configured = $WORKER_AUTO_JOIN"
echo "PASS/WARN: Public kubeconfig generated = $PUBLIC_KUBECONFIG"

[ "$FAILED" -eq 0 ]

TERRAPILOT_VERIFY
chmod +x /opt/terrapilot/bin/verify-kubernetes-infra.sh
ln -sf /opt/terrapilot/bin/verify-kubernetes-infra.sh /usr/local/bin/kubernetes-check
cat > /opt/terrapilot/bin/generate-kubeconfig-github.sh <<'TERRAPILOT_GITHUB_KUBECONFIG_HELPER'
#!/bin/bash
set -Eeuo pipefail

PUBLIC_ENDPOINT=""
PRIVATE_ENDPOINT=""
INPUT_KUBECONFIG="/etc/kubernetes/admin.conf"
PRIVATE_KUBECONFIG="/home/ubuntu/kubeconfig-private"
PRIVATE_B64="/home/ubuntu/kubeconfig-private.b64"
OUTPUT_KUBECONFIG="/home/ubuntu/kubeconfig-public"
OUTPUT_B64="/home/ubuntu/kubeconfig-public.b64"
INSTRUCTIONS="/home/ubuntu/KUBE_CONFIG_DATA_INSTRUCTIONS.txt"

usage() {
  cat <<'EOF'
Usage:
  generate-kubeconfig-github [--public-ip PUBLIC_IP_OR_DNS] [--public-dns PUBLIC_DNS] [--input INPUT_KUBECONFIG]

Examples:
  generate-kubeconfig-github
  generate-kubeconfig-github --public-ip 54.236.40.32
  generate-kubeconfig-github --public-dns ec2-54-236-40-32.compute-1.amazonaws.com
  generate-kubeconfig-github --input /etc/kubernetes/admin.conf --public-ip 54.236.40.32
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --public-ip)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: --public-ip requires a value."
        usage
        exit 1
      fi
      PUBLIC_ENDPOINT="$2"
      shift 2
      ;;
    --public-dns|--public-endpoint)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: $1 requires a value."
        usage
        exit 1
      fi
      PUBLIC_ENDPOINT="$2"
      shift 2
      ;;
    --input)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: --input requires a value."
        usage
        exit 1
      fi
      INPUT_KUBECONFIG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

get_public_ip() {
  local token
  token="$(curl -fsS --max-time 3 -X PUT "http://169.254.169.254/latest/api/token"     -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"

  if [ -n "$token" ]; then
    curl -fsS --max-time 3       -H "X-aws-ec2-metadata-token: $token"       "http://169.254.169.254/latest/meta-data/public-ipv4" || true
  else
    curl -fsS --max-time 3       "http://169.254.169.254/latest/meta-data/public-ipv4" || true
  fi
}

get_private_ip() {
  hostname -I | awk '{print $1}'
}

if [ -z "$PUBLIC_ENDPOINT" ]; then
  PUBLIC_ENDPOINT="$(get_public_ip)"
fi

if [ -z "$PRIVATE_ENDPOINT" ]; then
  PRIVATE_ENDPOINT="$(get_private_ip)"
fi

if [ -z "$PUBLIC_ENDPOINT" ]; then
  echo "ERROR: Could not detect public IP. Provide it manually:"
  echo "generate-kubeconfig-github --public-ip <PUBLIC_IP_OR_DNS>"
  exit 1
fi

if [ -z "$PRIVATE_ENDPOINT" ]; then
  echo "ERROR: Could not detect private IP."
  exit 1
fi

if [ ! -f "$INPUT_KUBECONFIG" ]; then
  if [ -f /etc/kubernetes/admin.conf ]; then
    INPUT_KUBECONFIG="/etc/kubernetes/admin.conf"
  else
    echo "ERROR: Input kubeconfig not found."
    echo "Checked: $INPUT_KUBECONFIG and /etc/kubernetes/admin.conf"
    exit 1
  fi
fi

if [ "$INPUT_KUBECONFIG" != "$PRIVATE_KUBECONFIG" ]; then
  cp "$INPUT_KUBECONFIG" "$PRIVATE_KUBECONFIG"
fi

sed -i -E "s#server: https://[^[:space:]]+:6443#server: https://$PRIVATE_ENDPOINT:6443#g" "$PRIVATE_KUBECONFIG"

if ! grep -q "server: https://$PRIVATE_ENDPOINT:6443" "$PRIVATE_KUBECONFIG"; then
  echo "ERROR: Private endpoint was not written into private kubeconfig."
  grep "server:" "$PRIVATE_KUBECONFIG" || true
  exit 1
fi

base64 -w 0 "$PRIVATE_KUBECONFIG" > "$PRIVATE_B64"

if ! base64 -d "$PRIVATE_B64" >/dev/null 2>&1; then
  echo "ERROR: Generated private base64 file is invalid."
  exit 1
fi

if ! base64 -d "$PRIVATE_B64" 2>/dev/null | grep -q "server: https://$PRIVATE_ENDPOINT:6443"; then
  echo "ERROR: Private base64 kubeconfig does not decode to the private endpoint."
  base64 -d "$PRIVATE_B64" 2>/dev/null | grep "server:" || true
  exit 1
fi

cp "$PRIVATE_KUBECONFIG" "$OUTPUT_KUBECONFIG"

sed -i -E "s#server: https://[^[:space:]]+:6443#server: https://$PUBLIC_ENDPOINT:6443#g" "$OUTPUT_KUBECONFIG"

if ! grep -q "server: https://$PUBLIC_ENDPOINT:6443" "$OUTPUT_KUBECONFIG"; then
  echo "ERROR: Public endpoint was not written into kubeconfig."
  grep "server:" "$OUTPUT_KUBECONFIG" || true
  exit 1
fi

if grep -q "server: https://$PRIVATE_ENDPOINT:6443" "$OUTPUT_KUBECONFIG"; then
  echo "ERROR: Public kubeconfig still contains private API endpoint $PRIVATE_ENDPOINT."
  grep "server:" "$OUTPUT_KUBECONFIG" || true
  exit 1
fi

base64 -w 0 "$OUTPUT_KUBECONFIG" > "$OUTPUT_B64"

if ! base64 -d "$OUTPUT_B64" >/dev/null 2>&1; then
  echo "ERROR: Generated base64 file is invalid."
  exit 1
fi

if ! base64 -d "$OUTPUT_B64" 2>/dev/null | grep -q "server: https://$PUBLIC_ENDPOINT:6443"; then
  echo "ERROR: Public base64 kubeconfig does not decode to the public endpoint."
  base64 -d "$OUTPUT_B64" 2>/dev/null | grep "server:" || true
  exit 1
fi

if base64 -d "$OUTPUT_B64" 2>/dev/null | grep -q "server: https://$PRIVATE_ENDPOINT:6443"; then
  echo "ERROR: Public base64 kubeconfig still decodes to the private endpoint."
  base64 -d "$OUTPUT_B64" 2>/dev/null | grep "server:" || true
  exit 1
fi

cat > "$INSTRUCTIONS" <<EOF
TerraPilot GitHub Actions KUBE_CONFIG_DATA setup

Public kubeconfig base64:
$OUTPUT_B64
Purpose: GitHub Actions, local laptop, or external kubectl access. Contains the public API server endpoint.

For GitHub Actions Secret KUBE_CONFIG_DATA, copy this value:
cat $OUTPUT_B64

Generated public kubeconfig:
$OUTPUT_KUBECONFIG

Verified public server endpoint:
https://$PUBLIC_ENDPOINT:6443

Private kubeconfig base64:
$PRIVATE_B64
Purpose: inside-VPC/internal use only. Contains the private API server endpoint.

Generated private kubeconfig:
$PRIVATE_KUBECONFIG

Verified private server endpoint:
https://$PRIVATE_ENDPOINT:6443

Troubleshooting:
base64 -d $OUTPUT_B64 | grep "server:"
base64 -d $PRIVATE_B64 | grep "server:"

Important:
- Do not paste raw kubeconfig YAML.
- Do not paste the file path.
- Do not paste only part of the value.
- This value is sensitive.
- For GitHub Actions KUBE_CONFIG_DATA, copy the public base64 kubeconfig with: cat $OUTPUT_B64
- Do not use /home/ubuntu/kubeconfig-private.b64 for GitHub Actions unless the runner is inside the same private VPC.
- If KUBE_CONFIG_DATA contains a private IP like 10.x.x.x, GitHub Actions and external laptops will not be able to reach the Kubernetes API server.
- Your AWS Security Group must allow Kubernetes API port 6443 from the GitHub runner or trusted source.
- For production, prefer a self-hosted GitHub runner inside the VPC instead of exposing 6443 publicly.
EOF

chmod 600 "$PRIVATE_KUBECONFIG" "$PRIVATE_B64" "$OUTPUT_KUBECONFIG" "$OUTPUT_B64" "$INSTRUCTIONS"
chown ubuntu:ubuntu "$PRIVATE_KUBECONFIG" "$PRIVATE_B64" "$OUTPUT_KUBECONFIG" "$OUTPUT_B64" "$INSTRUCTIONS" 2>/dev/null || true

echo "SUCCESS: GitHub Actions kubeconfig helper files generated."
echo "GitHub Actions KUBE_CONFIG_DATA source:"
echo "cat $OUTPUT_B64"
echo "Public API endpoint for GitHub Actions and external kubectl:"
base64 -d "$OUTPUT_B64" | grep "server:"
echo "Private API endpoint for inside-VPC/internal use only:"
base64 -d "$PRIVATE_B64" | grep "server:"
echo
echo "Copy this public base64 value into GitHub Secret KUBE_CONFIG_DATA:"
echo "cat $OUTPUT_B64"

TERRAPILOT_GITHUB_KUBECONFIG_HELPER
chmod +x /opt/terrapilot/bin/generate-kubeconfig-github.sh
ln -sf /opt/terrapilot/bin/generate-kubeconfig-github.sh /usr/local/bin/generate-kubeconfig-github
cat > /opt/terrapilot/COMMANDS.md <<'TERRAPILOT_COMMANDS'
# TerraPilot Command Reference

Kubernetes bootstrap is automatic. Terraform creates the EC2 instances, then EC2 user_data runs common setup, initializes the control plane, writes the worker join command to SSM Parameter Store, installs Calico, and joins workers automatically.

Do not manually run `kubeadm init` unless you are recovering a failed node. Use the checks below after Terraform apply.

## General logs

```bash
cloud-init status --long
sudo tail -n 200 /var/log/cloud-init-output.log
sudo tail -n 200 /var/log/terrapilot-userdata.log
cat /opt/terrapilot/status/userdata.success
cat /opt/terrapilot/status/userdata.failed
```

## Main verification

```bash
kubernetes-check
sudo /opt/terrapilot/bin/verify-kubernetes-infra.sh
```

## Container runtime

```bash
systemctl status containerd --no-pager
crictl info
containerd --version
runc --version
```

## Kubernetes

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get ns
kubectl get pods -n calico-system
kubectl get pods -n kube-system
kubectl cluster-info
sudo kubeadm token list
```

If `kubectl get pods -A` works, kubectl is installed and kubeconfig is working. If you see `command not found: kubectl`, install kubectl or copy `/etc/kubernetes/admin.conf` to `~/.kube/config` on the control-plane node.

> **Note:** The correct command is `kubectl`, not `kubeclt`. A common typo is `kubeclt` which will produce a "command not found" error.

## Kubeconfig files

```bash
ls -la /home/ubuntu/.kube
grep "server:" /home/ubuntu/kubeconfig-public
grep "server:" /home/ubuntu/kubeconfig-private
```

## GitHub Actions KUBE_CONFIG_DATA secret

The kubeconfig contains cluster-admin credentials. Store the base64 value only in GitHub Secrets or another encrypted secret manager. Do not paste raw kubeconfig YAML, do not paste `/etc/kubernetes/admin.conf` as a file path, and do not paste only part of the base64 output.

```bash
# On the control-plane node, generate public kubeconfig base64 for GitHub Actions
generate-kubeconfig-github

# Or manually provide public IP
generate-kubeconfig-github --public-ip <PUBLIC_IP>

# Verify generated public endpoint
base64 -d /home/ubuntu/kubeconfig-public.b64 | grep "server:"
base64 -d /home/ubuntu/kubeconfig-private.b64 | grep "server:"

# Copy value for GitHub Secret KUBE_CONFIG_DATA
cat /home/ubuntu/kubeconfig-public.b64

# Use private kubeconfig only for a self-hosted GitHub runner inside the same VPC
cat /home/ubuntu/kubeconfig-private.b64
```

Paste the full public kubeconfig base64 output into GitHub Secret `KUBE_CONFIG_DATA`.

Use public kubeconfig for GitHub-hosted runners. Use private kubeconfig only for self-hosted runners inside the VPC.
If your `KUBE_CONFIG_DATA` contains a private IP like 10.x.x.x, GitHub Actions and external laptops will not be able to reach the Kubernetes API server.

Do not expose Kubernetes API port 6443 to 0.0.0.0/0 in production. Use a self-hosted GitHub runner inside the VPC or restrict access to trusted IPs.

## Worker auto-join

```bash
cat ~/join-worker-private.sh
cat ~/join-worker-public.sh
aws ssm get-parameter --name "/terrapilot/DeployWatch/dev/kubernetes/join-command/private" --with-decryption --region "us-east-1" --query Parameter.Value --output text
aws ssm get-parameter --name "/terrapilot/DeployWatch/dev/kubernetes/join-command/public" --with-decryption --region "us-east-1" --query Parameter.Value --output text
```

The join command is a temporary secret. Rotate or delete it after workers have joined:

```bash
sudo kubeadm token create --print-join-command
aws ssm get-parameter --name "/terrapilot/DeployWatch/dev/kubernetes/join-command/private" --with-decryption --region "us-east-1" --query Parameter.Value --output text
aws ssm delete-parameter --name "/terrapilot/DeployWatch/dev/kubernetes/join-command/private" --region "us-east-1"
```

## Calico troubleshooting

```bash
kubectl get pods -A | grep -Ei 'calico|tigera'
kubectl describe pods -n calico-system
kubectl describe pods -n tigera-operator
sudo journalctl -u kubelet -n 100 --no-pager
sudo journalctl -u containerd -n 100 --no-pager
ip route
ss -tulpn
```

## kagent

kagent is disabled for this deployment. No kagent pods are expected.

To enable kagent, re-run the wizard with the kagent toggle enabled in the Kubernetes step. kagent requires a self-managed Kubernetes cluster (not EKS).


TERRAPILOT_COMMANDS

  log "Common Kubernetes setup is executed by bootstrap-user-data.sh before master-user-data.sh."
  command -v aws >/dev/null 2>&1 || install_aws_cli_v2 || fail "AWS CLI missing; SSM automatic worker join cannot work."

  PRIVATE_IP="$(hostname -I | awk '{print $1}')"
  PUBLIC_IP="$(get_metadata public-ipv4)"
  INSTANCE_ID="$(get_metadata instance-id)"

  log "Instance ID: $${INSTANCE_ID:-unknown}"
  log "Private IP: $PRIVATE_IP"
  log "Public IP: $${PUBLIC_IP:-not-detected}"

  echo "[TerraPilot] Step 2/5: Initializing control plane"
  systemctl start containerd
  systemctl start kubelet || true
  APISERVER_CERT_SANS="$PRIVATE_IP"
  if [ -n "$PUBLIC_IP" ]; then
    APISERVER_CERT_SANS="$APISERVER_CERT_SANS,$PUBLIC_IP"
  fi
  kubeadm init --apiserver-advertise-address="$PRIVATE_IP" --apiserver-cert-extra-sans="$APISERVER_CERT_SANS" --pod-network-cidr=192.168.0.0/16 --cri-socket=unix:///run/containerd/containerd.sock || fail "kubeadm init failed"
  [ -f /etc/kubernetes/admin.conf ] || fail "kubeadm init did not create /etc/kubernetes/admin.conf"

  echo "[TerraPilot] Step 3/5: Generating kubeconfigs"
  generate_kubeconfigs "$PRIVATE_IP" "$PUBLIC_IP"
  generate_kubeconfig_base64_exports "$PRIVATE_IP" "$PUBLIC_IP"
  generate-kubeconfig-github || log "WARNING: GitHub kubeconfig helper generation failed. User can run it manually later."
  [ -f /home/ubuntu/.kube/config ] || fail "master kubeconfig missing at /home/ubuntu/.kube/config"
  wait_for_api
  sudo -H -u ubuntu KUBECONFIG=/home/ubuntu/.kube/config kubectl get nodes || fail "kubectl get nodes failed with generated kubeconfig"

  echo "[TerraPilot] Step 4/5: Writing worker join command"
  write_join_command_to_ssm "$PRIVATE_IP" "$PUBLIC_IP"

  echo "[TerraPilot] Step 5/5: Installing Calico"
  install_calico

  echo "[TerraPilot] Optional: Installing kagent Bedrock Kubernetes agent"
  log "kagent installation is disabled."

  run_as_ubuntu kubectl get nodes -o wide || true
  run_as_ubuntu kubectl get pods -A -o wide || true
  /opt/terrapilot/bin/verify-kubernetes-infra.sh || log "WARNING: final Kubernetes verification reported issues. Run kubernetes-check after bootstrap for details."
  switch_default_kubeconfig_to_public

  echo "========================================"
  echo "TerraPilot user data completed: $(date)"
  echo "========================================"
  success "Kubernetes master bootstrap completed."
}

main "$@"
