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
