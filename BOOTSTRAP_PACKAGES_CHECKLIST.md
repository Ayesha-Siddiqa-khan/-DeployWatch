# Bootstrap Packages Checklist

This file lists the packages, tools, and services expected to be installed by your selected EC2 bootstrap scripts.
Use this checklist to verify that first-boot installation completed successfully.

> **Required** tools must be present. Missing required tools cause the verification script to exit with failure.
> **Optional** tools may be missing; they are shown as `[OPTIONAL MISSING]` without failing the check.

## One-Command Verification

After EC2 first boot completes, run this single command to verify all selected bootstrap packages:

```bash
sudo bash /opt/terrapilot/scripts/verify-bootstrap-packages.sh
```

This script is read-only. It checks installed packages, tool versions, service status, and TerraPilot status markers.
It does not install, delete, restart, stop, or modify anything.

## Actual Runtime Execution Order

The generated S3 bootstrap wrapper runs Kubernetes-critical scripts before optional software scripts.

For Kubernetes master/control-plane nodes:

1. `common-setup.sh`
2. `kubernetes-master-user-data.sh`
3. Optional S3 scripts through `s3-bootstrap-runner.sh`

For Kubernetes worker nodes:

1. `common-setup.sh`
2. `kubernetes-worker-user-data.sh`
3. Optional S3 scripts through `s3-bootstrap-runner.sh`

## Optional S3 Scripts Executed After Kubernetes Core Setup

These selected tools are installed by `s3-bootstrap-runner.sh` after `common-setup.sh` and role-specific Kubernetes bootstrap finish.

### kubernetes-master

- `base-packages.sh` (base-packages)
- `install-helm.sh` (install-helm)
- `install-kubectl-cli.sh` (kubectl-cli)
- `install-nginx.sh` (nginx)

### kubernetes-worker

- `base-packages.sh` (base-packages)
- `install-kubectl-cli.sh` (kubectl-cli)
- `install-nginx.sh` (nginx)

## Selected Scripts Inventory

This inventory reflects user selections. For Kubernetes S3 hybrid mode, optional software scripts are executed after the runtime order above.

| Order | Script | Template | Target | Required Tools | Optional Tools | Required Services |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | base-packages.sh | base-packages | All EC2 instances | curl, wget, unzip, git | gpg | - |
| 2 | common-setup.sh | kubernetes-common | All EC2 instances | containerd, kubelet, kubeadm, kubectl | - | containerd, kubelet |
| 3 | install-kubectl-cli.sh | kubectl-cli | All EC2 instances | kubectl | - | - |
| 4 | control-plane-setup.sh | kubernetes-control-plane | Kubernetes master / control plane only | kubeadm, kubectl | - | kubelet |
| 5 | worker-join-setup.sh | kubernetes-worker-join | Kubernetes worker nodes only | kubeadm, kubectl | - | kubelet |
| 6 | install-helm.sh | install-helm | Kubernetes master / control plane only | helm | - | - |
| 7 | install-nginx.sh | nginx | All EC2 instances | nginx | - | nginx |

## Expected Packages and Tools

### base-packages.sh (base-packages)

**Required Commands:** curl, wget, unzip, git
**Optional Commands:** gpg
**Required Packages:** curl, wget, unzip, git, ca-certificates, gnupg
**Notes:** Base packages are installed via apt

### common-setup.sh (kubernetes-common)

**Required Commands:** containerd, kubelet, kubeadm, kubectl
**Required Packages:** containerd.io, kubelet, kubeadm, kubectl
**Required Services:** containerd, kubelet
**Status Markers:** /opt/terrapilot/status/common.success
**Notes:** Kubernetes common setup installs containerd, kubelet, kubeadm, kubectl

### install-kubectl-cli.sh (kubectl-cli)

**Required Commands:** kubectl
**Required Packages:** kubectl
**Notes:** kubectl installed via official Kubernetes repo

### control-plane-setup.sh (kubernetes-control-plane)

**Required Commands:** kubeadm, kubectl
**Required Packages:** kubeadm, kubectl
**Required Services:** kubelet
**Status Markers:** /opt/terrapilot/status/master.success
**Expected Files:** /etc/kubernetes/admin.conf
**Notes:** Control-plane initializes the cluster and installs Calico

### worker-join-setup.sh (kubernetes-worker-join)

**Required Commands:** kubeadm, kubectl
**Required Packages:** kubeadm, kubectl
**Required Services:** kubelet
**Status Markers:** /opt/terrapilot/status/worker.success
**Notes:** Worker joins the cluster via kubeadm join

### install-helm.sh (install-helm)

**Required Commands:** helm
**Required Packages:** helm
**Notes:** Helm installed via official installer

### install-nginx.sh (nginx)

**Required Commands:** nginx
**Required Packages:** nginx
**Required Services:** nginx
**Notes:** Nginx may not start if port 80 is in use

## Manual All-in-One Checks

If you prefer to check manually, use these commands:

### Required command version checks

```bash
for cmd in curl wget unzip git containerd kubelet kubeadm kubectl helm nginx; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "[OK] $cmd -> $($cmd --version 2>&1 | head -n 1)"
  else
    echo "[MISSING] $cmd (required)"
  fi
done
```

### Optional command version checks

```bash
for cmd in gpg; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "[OK] $cmd -> $($cmd --version 2>&1 | head -n 1)"
  else
    echo "[OPTIONAL MISSING] $cmd (not required)"
  fi
done
```

### Required service status checks

```bash
for svc in containerd kubelet nginx; do
  if systemctl list-unit-files "$svc.service" >/dev/null 2>&1; then
    systemctl is-active "$svc" >/dev/null 2>&1 && echo "[OK] $svc active" || echo "[WARNING] $svc not active"
  else
    echo "[MISSING] $svc service not found (required)"
  fi
done
```

### Required package list check (Ubuntu/Debian)

```bash
dpkg -l | grep -E "curl|wget|unzip|git|ca-certificates|gnupg|containerd.io|kubelet|kubeadm|kubectl|helm|nginx" || echo "No matching packages found"
```

### Package list check (Amazon Linux / RHEL)

```bash
rpm -qa | grep -E "curl|wget|unzip|git|ca-certificates|gnupg|containerd.io|kubelet|kubeadm|kubectl|helm|nginx" || echo "No matching packages found"
```

### Status marker checks

```bash
for marker in /opt/terrapilot/status/common.success /opt/terrapilot/status/master.success /opt/terrapilot/status/worker.success; do
  if [ -f "$marker" ]; then
    echo "[OK] $marker found"
  else
    echo "[MISSING] $marker"
  fi
done
```

### Expected file checks

```bash
for f in /etc/kubernetes/admin.conf; do
  if [ -f "$f" ]; then
    echo "[OK] $f found"
  else
    echo "[MISSING] $f"
  fi
done
```

## Logs and Troubleshooting

If a package is missing, check these logs on the EC2 instance:

```bash
sudo tail -n 200 /var/log/cloud-init-output.log
sudo journalctl -u cloud-final --no-pager -n 200
ls -la /opt/terrapilot/status
cat /opt/terrapilot/status/userdata.success || echo "No success marker"
cat /opt/terrapilot/status/userdata.failed || echo "No failure marker"
```
