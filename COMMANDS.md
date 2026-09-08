# Commands

## Terraform

```bat
cd terraform
run-terraform.bat
destroy-terraform.bat
post-destroy-audit.bat
post-destroy-cleanup-plan.bat
post-destroy-cleanup-execute.bat
```

## Manual Terraform

```bash
cd terraform
terraform fmt -recursive
terraform init
terraform validate
terraform plan
terraform apply
terraform destroy
```

## AWS Identity And Audit

```bash
aws sts get-caller-identity
aws ec2 describe-addresses --region us-east-1
aws ec2 describe-nat-gateways --region us-east-1
aws logs describe-log-groups --region us-east-1 --log-group-name-prefix /terrapilot
```

## EC2 Instance Type Validation

```bash
aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true --query "InstanceTypes[*].[InstanceType]" --output text | sort
aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=<instance-type> --region us-east-1
aws ec2 describe-instance-types --instance-types <instance-type> --region us-east-1
```

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


## Post-Destroy Cleanup

```bat
cd terraform
post-destroy-audit.bat
post-destroy-cleanup-plan.bat
post-destroy-cleanup-execute.bat
```

`post-destroy-cleanup-plan.bat` is read-only. `post-destroy-cleanup-execute.bat` is destructive and requires the exact project name plus `DELETE TERRAPILOT LEFTOVERS`.

Cleanup commands belong in manual review first. `post-destroy-audit.bat` prints suggestions but does not execute destructive AWS commands.
