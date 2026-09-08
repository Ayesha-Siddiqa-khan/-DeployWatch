# Cost Guardrails

Generated: 2026-09-08T10:58:57.733Z

TerraPilot uses cost-safe defaults for Infrastructure/Terraform exports:

- Elastic IP disabled unless Static Public IP / Elastic IP is explicitly enabled and confirmed.
- NAT Gateway disabled by default. Supported modes are none, single, and per-AZ.
- EC2 public IPv4 disabled by default.
- Internet Gateway and public routes are generated only when public internet access is selected or required by public EC2/NAT/EIP choices.
- CloudWatch user-data log retention defaults to 7 days.
- EC2 root EBS volumes use `delete_on_termination = true`.
- S3 `force_destroy` is disabled unless explicitly enabled and confirmed.

## Current Risk

Overall risk: **Medium**

| Resource | Status | Risk | Confirmation |
| --- | --- | --- | --- |
| Elastic IP / static public IP | disabled | Low | No confirmation required |
| EC2 public IPv4 | enabled | Medium | Confirmed |
| NAT Gateway | enabled | Medium | Confirmed |
| Load balancer | disabled | Low | No confirmation required |
| Amazon EKS | disabled | Low | No confirmation required |
| Large EC2 instances | disabled | Low | No confirmation required |
| EBS volumes | warning | Medium | No confirmation required |
| S3 force_destroy | disabled | Low | No confirmation required |
| CloudWatch logs | disabled | Low | No confirmation required |
| Endpoints and backups | warning | Medium | No confirmation required |

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


## Required Tags

Cost-sensitive resources include:

- `Project`
- `ManagedBy = TerraPilot`
- `TerraPilotProject`
- `TerraPilotResourceType`
- `Environment`
- `CostSensitive = true`

## Destroy Reminder

`terraform destroy` can leave resources that Terraform does not own or cannot delete because of dependencies, retained data, or Kubernetes-created resources. Run `terraform/post-destroy-audit.bat` after destroy and review COST RISK / MANUAL CHECK entries.

## Post-Destroy Cleanup

Run `terraform/post-destroy-cleanup-plan.bat` after the audit to create a read-only cleanup plan. The planner uses TerraPilot tags and project naming to avoid account-wide deletion.

`terraform/post-destroy-cleanup-execute.bat` is destructive. It requires the exact project name and the phrase `DELETE TERRAPILOT LEFTOVERS`. S3 buckets, ECR repositories, EKS clusters, IAM roles, and IAM instance profiles remain manual/high-risk by default unless separately confirmed.
