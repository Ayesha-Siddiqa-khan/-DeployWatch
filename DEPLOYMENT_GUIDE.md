# Deployment Guide

## Terraform Files

Terraform files are generated for the `terraform/` folder. Startup scripts are generated under `terraform/scripts/`.

## Terraform Batch Helpers

- `terraform/run-terraform.bat` runs `terraform fmt -recursive`, `terraform init`, `terraform validate`, `terraform plan`, and then asks whether to run `terraform apply`.
- `terraform/destroy-terraform.bat` destroys infrastructure only after you type `DESTROY`.

Destroy can permanently delete real cloud resources. Use it only when you no longer need the resources.

## EC2 Instance Selection

TerraPilot uses exact AWS EC2 instance type names in Terraform. Do not rename or simplify instance types. Examples: `t3.micro`, `t3.small`, `t4g.micro`, `m6i.large`, `m7i-flex.large`, `c7i-flex.large`, `c7g.medium`, and `r6i.large`.

Selected instance types:

- `c7i-flex.large` (1 selected for c7i-flex-large)
- `t3.micro` (1 selected for t3-micro)

For beginner testing, start with Free Tier or low-cost instances such as `t3.micro`, `t3.small`, `t4g.micro`, or `t4g.small` when the selected AMI architecture matches. `c7i-flex.large` and `m7i-flex.large` can be Free Tier eligible for newer AWS account plans, but you must confirm account, Region, AMI, operating system, and monthly usage eligibility in AWS Billing or the EC2 console.

Free Tier eligibility can depend on account plan, account age, Region, AMI, operating system, and usage. A type marked Free Tier Eligible is not a guarantee that a long-running workload will be free.

Region availability matters. EC2 instance type offerings vary by Region and Availability Zone. Validate before apply:

```bash
aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=<instance-type> --region us-east-1
```

List currently Free Tier eligible EC2 instance types:

```bash
aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true --query "InstanceTypes[*].[InstanceType]" --output text | sort
```

Describe a specific instance type:

```bash
aws ec2 describe-instance-types --instance-types <instance-type> --region us-east-1
```

AMI architecture must match the instance type. Use x86_64 AMIs with x86 instance families such as `t3`, `m6i`, `m7i`, `c7i`, `c7i-flex`, and `m7i-flex`. Use arm64 AMIs with Graviton families such as `t4g`, `m7g`, `c7g`, and `r7g`.

Avoid high-cost mistakes: do not select GPU, Trainium, Inferentia, very large memory, or multi-instance quantities unless the workload requires them and the account quota/cost is understood.


## EC2 Startup Script Execution

Terraform apply confirms the EC2 instance was created. It does not mean startup scripts finished. EC2 user-data runs after instance launch, so wait a few minutes for boot and cloud-init.

## EC2 Bootstrap Builder

EC2 Bootstrap Builder creates startup scripts that run once when your EC2 instance launches. These are EC2 user-data scripts executed by cloud-init during first boot.

Use Bootstrap Builder for simple first-boot software installation such as base packages, language runtimes, Docker, Nginx, Terraform, cloud CLIs, CI runner prerequisites, security scanners, monitoring tools, database clients, Helm, or kubeadm node bootstrap. Use New Ansible Automation when you need reusable configuration management across many servers or repeated day-2 operations.

Profiles choose a sensible set of scripts for common targets such as Minimal Linux Bootstrap, App Runtime Stack, Docker Host, Web Server, Cloud CLI Toolbox, IaC Toolbox, CI Build Agent, DevOps Toolbox, Kubernetes Control Plane, and Kubernetes Worker. Custom Manual Selection starts empty and lets you choose the exact script blocks.

Dependencies are normalized before export. Kubernetes Control Plane Setup and Kubernetes Worker Join Setup require Kubernetes Common Setup. Helm requires internet access. Docker-based app setup should include Install Docker. No Startup Script conflicts with every other script and disables user_data.

## Bootstrap Ordering Logic

TerraPilot sorts scripts by phase and dependency to create a deterministic execution order. User click order does not decide system script order. The ordering engine uses:

1. **Phase priority** - Scripts are grouped into DevOps phases (Package Management → Base Utilities → Cloud CLI → Language Runtime → IaC → Containers → Automation → Web Server → Kubernetes Prerequisites → Kubernetes Role Setup → Observability → Custom → Verification)
2. **Dependency graph** - Topological sorting ensures dependencies run before dependents
3. **Default order within phase** - Scripts within the same phase run in a safe default order
4. **Locked order** - Critical Kubernetes scripts have locked ordering
5. **Custom reorder** - Only custom scripts can be reordered by the user

Phase order:

1. Package Management (priority 200) - apt/yum update, package repository setup
2. Base Utilities (priority 300) - curl, wget, unzip, gpg, ca-certificates
3. Cloud CLI (priority 400) - AWS CLI, Azure CLI, Google Cloud CLI
4. Language Runtime (priority 500) - Node.js, Python, Java, Go
5. Infrastructure as Code (priority 600) - Terraform, OpenTofu
6. Containers (priority 700) - Docker, containerd
7. Automation (priority 800) - Ansible, kubectl CLI, Helm
8. Web Server (priority 900) - Nginx, Apache
9. Kubernetes Prerequisites (priority 1000) - swap, kernel modules, sysctl, containerd, kubelet, kubeadm, kubectl
10. Kubernetes Role Setup (priority 1100) - control-plane, worker join
11. Observability (priority 1200) - monitoring tools, CloudWatch
12. Custom (priority 1300) - user custom scripts
13. Verification (priority 1400) - success markers, service checks

Dependencies override phase order. If a script depends on Docker, Docker must run before it even if the user clicked the dependent script first.

Generated script files are under `terraform/scripts/`. Terraform references role-specific entrypoints such as `terraform/scripts/web-user-data.sh`, `terraform/scripts/master-user-data.sh`, `terraform/scripts/worker-user-data.sh`, `terraform/scripts/database-user-data.sh`, and `terraform/scripts/custom-user-data.sh`.




| Order | Script | Template | Target |
| --- | --- | --- | --- |
| 1 | base-packages.sh | base-packages | All EC2 instances |
| 2 | common-setup.sh | kubernetes-common | All EC2 instances |
| 3 | install-kubectl-cli.sh | kubectl-cli | All EC2 instances |
| 4 | control-plane-setup.sh | kubernetes-control-plane | Kubernetes master / control plane only |
| 5 | worker-join-setup.sh | kubernetes-worker-join | Kubernetes worker nodes only |
| 6 | install-helm.sh | install-helm | Kubernetes master / control plane only |
| 7 | install-nginx.sh | nginx | All EC2 instances |

Troubleshooting first boot:

```bash
cloud-init status --long
sudo tail -n 200 /var/log/cloud-init-output.log
sudo tail -n 200 /var/log/terrapilot-userdata.log
ls -la /opt/terrapilot/status
cat /opt/terrapilot/status/userdata.success
cat /opt/terrapilot/status/userdata.failed
kubernetes-check
```

The success marker means the TerraPilot user-data wrapper completed. The failure marker means one of the bootstrap scripts failed; inspect `/var/log/terrapilot-userdata.log` first, then cloud-init output.

## Verify Bootstrap Packages

After EC2 first boot completes, verify all selected packages and tools with a single command:

```bash
sudo bash /opt/terrapilot/scripts/verify-bootstrap-packages.sh
```

### Manual Fallback

If the verification script is not available, check packages manually:

```bash
for cmd in curl wget unzip git node npm python3 pip3 java javac go ansible ansible-playbook helm containerd kubelet kubeadm kubectl; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "[OK] $cmd -> $($cmd --version 2>&1 | head -n 1)"
  else
    echo "[MISSING] $cmd"
  fi
done
```

### Reading the Output

- `[OK]` - Tool is installed and available
- `[MISSING]` - Required tool is not installed (script exits with failure)
- `[OPTIONAL MISSING]` - Optional tool is not installed (does not fail the script)
- `[WARNING]` - Service is installed but not running

### Troubleshooting

If packages are missing, check these logs on the EC2 instance:

```bash
sudo tail -n 200 /var/log/cloud-init-output.log
sudo tail -n 200 /var/log/terrapilot-userdata.log
ls -la /opt/terrapilot/status
cat /opt/terrapilot/status/userdata.success || echo "No success marker"
cat /opt/terrapilot/status/userdata.failed || echo "No failure marker"
```

See `BOOTSTRAP_PACKAGES_CHECKLIST.md` for the full list of expected packages, manual verification commands, and troubleshooting steps.

### Docker on Kubernetes Nodes

On Kubernetes nodes, Docker Engine installation is treated as **soft_optional**. The installer:

1. Detects if Kubernetes containerd is already managing the container runtime
2. Backs up existing `/etc/containerd/config.toml` before any changes
3. Installs Docker Engine without forcing `containerd.io` overwrite
4. Restores original containerd config if overwritten
5. Falls back gracefully with a warning if Docker install fails

If Docker fails on a Kubernetes node, core Kubernetes setup remains healthy. Use Docker CLI/buildx only or containerd-native workflows as alternatives.

### S3 Bootstrap Script Failure Policies

| Policy | Description |
| --- | --- |
| `required_optional` | Script failure stops optional bootstrap |
| `soft_optional` | Script failure logs warning, continues next scripts |

Docker on Kubernetes nodes defaults to `soft_optional`. All other optional tools default to `required_optional`.


TerraPilot wraps each EC2 user-data entrypoint with logging and status reporting:

- Log file: `/var/log/terrapilot-userdata.log`
- Success marker: `/opt/terrapilot/status/userdata.success`
- Failure marker: `/opt/terrapilot/status/userdata.failed`

Scripts run in the order configured in the Compute step. Role-specific entrypoints are:

- `terraform/scripts/web-user-data.sh`
- `terraform/scripts/master-user-data.sh`
- `terraform/scripts/worker-user-data.sh`
- `terraform/scripts/database-user-data.sh`
- `terraform/scripts/custom-user-data.sh`

## Verification

```bash
cloud-init status --long
sudo tail -n 200 /var/log/cloud-init-output.log
sudo tail -n 200 /var/log/terrapilot-userdata.log
ls -la /opt/terrapilot/status
cat /opt/terrapilot/status/userdata.success
cat /opt/terrapilot/status/userdata.failed
kubernetes-check
```

For Kubernetes projects, run `kubernetes-check` on the Kubernetes master/control-plane instance.

The success marker means TerraPilot user-data completed. The failure marker means a script failed and the TerraPilot log should be checked.



## Kubernetes Control Plane

Bootstrap is automatic. Do not manually run `kubeadm init` unless recovery is needed.

### Kubernetes cluster verification

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get ns
kubectl get pods -n calico-system
kubectl get pods -n kube-system
kubectl cluster-info
sudo kubeadm token list
cat ~/join-worker-private.sh
cat ~/join-worker-public.sh
```

If `kubectl get pods -A` works, kubectl is installed and kubeconfig is working. If you see `command not found: kubectl`, install kubectl or copy `/etc/kubernetes/admin.conf` to `~/.kube/config` on the control-plane node.

> **Note:** The correct command is `kubectl`, not `kubeclt`. A common typo is `kubeclt` which will produce a "command not found" error.

### kagent

kagent is disabled for this deployment. No kagent pods are expected.

To enable kagent, re-run the wizard with the kagent toggle enabled in the Kubernetes step. kagent requires a self-managed Kubernetes cluster (not EKS).


Kubeconfigs are stored in `/home/ubuntu/.kube/config`, `/home/ubuntu/.kube/config-private`, `/home/ubuntu/.kube/config-public`, `/home/ubuntu/kubeconfig-private`, and `/home/ubuntu/kubeconfig-public`.

For GitHub-hosted runners, run this on the control-plane node and paste the public base64 output into GitHub Secret `KUBE_CONFIG_DATA`:

```bash
generate-kubeconfig-github
generate-kubeconfig-github --public-ip <PUBLIC_IP>
base64 -d /home/ubuntu/kubeconfig-public.b64 | grep "server:"
base64 -d /home/ubuntu/kubeconfig-private.b64 | grep "server:"
cat /home/ubuntu/kubeconfig-public.b64
```

Use `cat /home/ubuntu/kubeconfig-private.b64` only for a self-hosted runner inside the same VPC. The kubeconfig contains cluster-admin credentials; do not paste raw kubeconfig YAML or `/etc/kubernetes/admin.conf` as a path. If your `KUBE_CONFIG_DATA` contains a private IP like 10.x.x.x, GitHub Actions and external laptops will not be able to reach the Kubernetes API server. Do not expose Kubernetes API port 6443 to `0.0.0.0/0` in production.

## Worker Nodes

Workers automatically read the join command from AWS SSM Parameter Store and run `kubeadm join`. To inspect or regenerate the join command:

```bash
sudo kubeadm token create --print-join-command
aws ssm get-parameter --name "/terrapilot/DeployWatch/dev/kubernetes/join-command/private" --with-decryption --region "us-east-1" --query Parameter.Value --output text
aws ssm delete-parameter --name "/terrapilot/DeployWatch/dev/kubernetes/join-command/private" --region "us-east-1"
```

The SSM join token is temporary and should be rotated or deleted after nodes have joined.

## Calico Troubleshooting

```bash
kubectl get pods -A | grep -Ei 'calico|tigera'
kubectl describe pods -n calico-system
kubectl describe pods -n tigera-operator
sudo journalctl -u kubelet -n 100 --no-pager
```

## Troubleshooting

If cloud-init is still running, wait a few minutes. Kubernetes installation can take several minutes. If it fails, inspect `/var/log/cloud-init-output.log`, `/var/log/terrapilot-userdata.log`, and `/opt/terrapilot/status/userdata.failed`.
