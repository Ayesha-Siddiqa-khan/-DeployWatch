#!/bin/bash
set -Eeuo pipefail

export AWS_REGION="${aws_region}"
export TERRAPILOT_SSM_JOIN_PRIVATE_PATH="${ssm_join_private_path}"

LOG_FILE="/var/log/terrapilot-userdata.log"
STATUS_DIR="/opt/terrapilot/status"
mkdir -p "$STATUS_DIR"

exec > >(tee -a "$LOG_FILE" | logger -t terrapilot-userdata -s 2>/dev/console) 2>&1

trap 'echo "TerraPilot user data failed at line $LINENO"; mkdir -p /opt/terrapilot/status; rm -f /opt/terrapilot/status/userdata.success; echo "failed at line $LINENO" | tee /opt/terrapilot/status/userdata.failed' ERR

echo "========================================"
echo "TerraPilot user data started: $(date)"
echo "========================================"

log() {
  echo "[TerraPilot][worker][$(date -Is)] $*" >&2
}

fail() {
  rm -f "$STATUS_DIR/userdata.success"
  echo "$*" > "$STATUS_DIR/userdata.failed"
  log "FAILED: $*"
  exit 1
}

success() {
  rm -f "$STATUS_DIR/userdata.failed"
  echo "success" > "$STATUS_DIR/userdata.success"
  echo "success" > /opt/terrapilot/status/worker.success
  log "SUCCESS: $*"
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

wait_for_kubelet_active() {
  log "Waiting for kubelet to become active..."
  for i in {1..30}; do
    if systemctl is-active kubelet >/dev/null 2>&1; then
      log "Kubelet is active."
      return 0
    fi
    systemctl status kubelet --no-pager || true
    sleep 5
  done
  fail "kubelet is not active after kubeadm join"
}

wait_for_join_command() {
  local ssm_path="$${TERRAPILOT_SSM_JOIN_PRIVATE_PATH}"
  local join_command=""
  log "Waiting for join command in SSM: $ssm_path"

  for i in {1..120}; do
    join_command="$(aws ssm get-parameter --name "$ssm_path" --with-decryption --query "Parameter.Value" --output text --region "$${AWS_REGION}" 2>/dev/null || true)"
    if [ -n "$join_command" ] && echo "$join_command" | grep -q "kubeadm join"; then
      log "Join command received."
      printf '%s\n' "$join_command"
      return 0
    fi
    sleep 10
  done

  fail "Timed out waiting for worker join command in SSM."
}

main() {
  log "Starting Kubernetes worker bootstrap."
  echo "kubernetes-worker" > /opt/terrapilot/instance-role
  echo "kubernetes-worker" > /opt/terrapilot/role
  echo "worker-user-data.sh" >> "$STATUS_DIR/scripts-ran.log"
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

  log "Common Kubernetes setup is executed by bootstrap-user-data.sh before worker-user-data.sh."
  command -v aws >/dev/null 2>&1 || install_aws_cli_v2 || fail "AWS CLI missing; SSM automatic worker join cannot work."

  echo "[TerraPilot] Step 2/3: Waiting for control-plane join command"
  systemctl start containerd
  systemctl start kubelet || true
  JOIN_COMMAND="$(wait_for_join_command)"

  echo "[TerraPilot] Step 3/3: Running kubeadm join"
  bash -c "$JOIN_COMMAND" || fail "kubeadm join failed"
  [ -f /etc/kubernetes/kubelet.conf ] || fail "kubeadm join did not create /etc/kubernetes/kubelet.conf"

  log "Worker joined cluster. Waiting for kubelet..."
  wait_for_kubelet_active

  echo "========================================"
  echo "TerraPilot user data completed: $(date)"
  echo "========================================"
  success "Kubernetes worker bootstrap completed."
}

main "$@"
