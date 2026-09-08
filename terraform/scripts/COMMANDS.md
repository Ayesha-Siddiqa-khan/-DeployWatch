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

