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
