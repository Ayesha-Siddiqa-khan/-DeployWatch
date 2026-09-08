# Post-Destroy AWS Audit Guide

The audit helper is read-only. It runs AWS CLI describe/list/get commands and writes a timestamped report under `terraform/post-destroy-audits/`.

## Setup

Run `terraform/post-destroy-audit.bat` after `terraform destroy`.

The script is non-interactive by default. It auto-detects:

1. Values already set in the shell or optional `terraform/AWS_AUDIT_ENV.bat`.
2. `region`, `project_name`, `environment`, and `ecr_repository_name` from `terraform/terraform.tfvars`.
3. Provider/default tag values from `terraform/main.tf`.
4. `AWS_DEFAULT_REGION` or `aws configure get region`.
5. Generated defaults only if none of the above exists.

Copy `terraform/AWS_AUDIT_ENV.example.bat` to `terraform/AWS_AUDIT_ENV.bat` only when you want to override detection, for example to force an `AWS_PROFILE`.

Default region: `us-east-1`
Project name: `DeployWatch`

## Checks

The report checks EC2, Elastic IPs, NAT gateways, load balancers, EKS, ECS, Lambda, EBS volumes and snapshots, VPCs, subnets, route tables, Internet Gateways, security groups, ENIs, VPC endpoints, RDS, ECR, S3 buckets, CloudFormation stacks, CloudWatch Logs, SSM parameters, IAM roles and instance profiles, and AWS Backup vaults.

Statuses:

- OK: read-only check completed.
- WARNING: the AWS CLI call failed or needs extra permission.
- COST RISK: review possible billable leftovers.
- MANUAL CHECK: resource type may need human verification or tag filtering.

Cleanup commands are printed as suggestions only. The audit script never executes destructive cleanup.
