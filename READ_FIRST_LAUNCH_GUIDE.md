# Read First Launch Guide

## Project Overview

- Project name: DeployWatch
- Environment: dev
- Cloud provider: AWS
- Selected services: VPC networking, EC2, S3, ECR, Self-managed kubeadm Kubernetes, IAM
- Generated date/time: 2026-09-08T10:58:57.733Z

Important: Infrastructure and CI/CD are separated. Terraform creates infrastructure. CI/CD deploys the application.

## Before You Start

- [ ] Terraform installed locally
- [ ] AWS CLI installed
- [ ] Git installed if pushing generated files to GitHub
- [ ] kubectl installed if Kubernetes/EKS is selected
- [ ] Correct AWS account selected
- [ ] AWS region confirmed: `us-east-1`

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


## Local AWS Credentials Setup

Actual credentials are never stored in generated files.

Safe local options:

```bash
aws configure
aws sts get-caller-identity
AWS_PROFILE=<profile-name> terraform plan
export AWS_ACCESS_KEY_ID=<your-access-key-id>
export AWS_SECRET_ACCESS_KEY=<your-secret-access-key>
aws sso login --profile <profile-name>
```

Never commit AWS access keys into GitHub.

## Terraform Infrastructure Setup

Helper files:

- `terraform/run-terraform.bat`
- `terraform/destroy-terraform.bat`

`run-terraform.bat` runs:

- `terraform fmt -recursive`
- `terraform init`
- `terraform validate`
- `terraform plan`
- optional `terraform apply` after confirmation

`destroy-terraform.bat` asks for confirmation and runs `terraform destroy` only after you type `DESTROY`.
After a successful destroy it can run `terraform/post-destroy-audit.bat`, a read-only AWS CLI audit that reports possible leftovers.
After the audit, run `terraform/post-destroy-cleanup-plan.bat` to create a read-only cleanup plan. Run `terraform/post-destroy-cleanup-execute.bat` only after reviewing the plan and typing the exact safety confirmations.

Cost guardrail docs:

- `COST_GUARDRAILS.md`
- `POST_DESTROY_AUDIT_GUIDE.md`
- `POST_DESTROY_CLEANUP_GUIDE.md`
- `terraform/AWS_AUDIT_ENV.example.bat`
- `terraform/CLEANUP_ENV.example.bat`

Manual commands:

```bash
cd terraform
terraform fmt -recursive
terraform init
terraform validate
terraform plan
terraform apply
```

## Kubernetes Access

Self-managed kubeadm Kubernetes is selected. The kubeconfig must come from the control-plane node.

```bash
ssh ubuntu@<master-public-ip>
generate-kubeconfig-github
cat /home/ubuntu/kubeconfig-public.b64
```

If the helper cannot detect the public IP, provide it manually:

```bash
generate-kubeconfig-github --public-ip <PUBLIC_IP>
base64 -d /home/ubuntu/kubeconfig-public.b64 | grep "server:"
base64 -d /home/ubuntu/kubeconfig-private.b64 | grep "server:"
cat /home/ubuntu/kubeconfig-public.b64
```

Copy the full `kubeconfig-public.b64` output and save it as the GitHub Secret `KUBE_CONFIG_DATA` only if you later create a self-managed Kubernetes CI/CD deployment.

`KUBE_NAMESPACE` is a GitHub Variable, not a secret.
Use `KUBE_CONFIG_DATA` only for self-managed Kubernetes CI/CD. Do not use it for EKS.
Use public kubeconfig for GitHub-hosted runners. Use private kubeconfig only for self-hosted runners inside the VPC.
If your `KUBE_CONFIG_DATA` contains a private IP like 10.x.x.x, GitHub Actions and external laptops will not be able to reach the Kubernetes API server.
Do not expose Kubernetes API port 6443 to 0.0.0.0/0 in production.

## Verification Commands

```bash
terraform output
ssh ubuntu@<public-ip>
systemctl status <service>
kubernetes-check
kubectl get nodes -o wide
kubectl get pods -A
kubectl get ns
kubectl get pods -n calico-system
kubectl get pods -n kube-system
aws ecr describe-repositories --repository-names deploywatch
```

If `kubectl get pods -A` works, kubectl is installed and kubeconfig is working. If you see `command not found: kubectl`, install kubectl or copy `/etc/kubernetes/admin.conf` to `~/.kube/config` on the control-plane node.

> **Note:** The correct command is `kubectl`, not `kubeclt`. A common typo is `kubeclt` which will produce a "command not found" error.

### kagent

kagent is disabled for this deployment. No kagent pods are expected.

To enable kagent, re-run the wizard with the kagent toggle enabled in the Kubernetes step. kagent requires a self-managed Kubernetes cluster (not EKS).


## Troubleshooting

| Problem | Fix |
| --- | --- |
| Terraform not found | Install Terraform and ensure it is available in PATH. |
| AWS credentials not configured | Run `aws configure`, set `AWS_PROFILE`, or use AWS CLI SSO. |
| Access denied | Check the active AWS identity with `aws sts get-caller-identity` and verify IAM permissions. |
| kubectl connects to localhost:8080 | Configure kubeconfig before running kubectl commands. |
| kubeconfig missing | For self-managed Kubernetes, get it from the control-plane node. |
| EKS update-kubeconfig fails | Check region, cluster name, and IAM access. |
| Docker/ECR login fails | Check AWS credentials and ECR permissions. |
| kubeclt: command not found | The correct command is `kubectl`, not `kubeclt`. |
| kubectl: connection refused | Kubeconfig is missing or points to wrong endpoint. Check `~/.kube/config`. |

## Cleanup / Destroy

Destroy can delete real cloud resources.

Windows helper:

```bat
terraform\destroy-terraform.bat
```

Manual destroy:

```bash
cd terraform
terraform destroy
```

Use destroy only when you no longer need the generated resources.
Run the post-destroy audit afterward to check for retained EIPs, NAT gateways, EBS volumes/snapshots, load balancers, logs, buckets, repositories, and other billable leftovers.
Then run the read-only cleanup planner:

```bat
terraform\post-destroy-cleanup-plan.bat
```

Only run `terraform\post-destroy-cleanup-execute.bat` after reviewing the generated plan. Execute mode asks for the exact project name and `DELETE TERRAPILOT LEFTOVERS` before deleting clearly TerraPilot-tagged leftovers.
