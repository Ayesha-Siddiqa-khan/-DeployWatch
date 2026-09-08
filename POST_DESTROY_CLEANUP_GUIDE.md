# Post-Destroy Cleanup Guide

This cleanup system helps you safely review and remove TerraPilot-created leftovers after `terraform destroy`.

Cleanup is dangerous because AWS resources may contain important data or may be shared with other systems. TerraPilot separates cleanup into two steps:

1. `terraform/post-destroy-cleanup-plan.bat` creates a read-only plan.
2. `terraform/post-destroy-cleanup-execute.bat` can delete only clearly TerraPilot leftovers after strong confirmation.

## Recommended Flow

```bat
cd terraform
destroy-terraform.bat
post-destroy-audit.bat
post-destroy-cleanup-plan.bat
post-destroy-cleanup-execute.bat
```

The planner reads the latest audit report from `terraform/post-destroy-audits/` when available. It also re-checks AWS live state so the plan is not based only on stale report text.

Default project: `DeployWatch`
Default region: `us-east-1`

## Safety Confirmations

Execute mode requires:

- the exact TerraPilot project name
- the exact phrase `DELETE TERRAPILOT LEFTOVERS`

If either value does not match, cleanup is cancelled and no resources are changed.

## Automatically Cleaned Candidates

Only TerraPilot-tagged or TerraPilot-named resources are candidates:

- Elastic IP allocations
- NAT Gateways
- unattached EBS volumes
- TerraPilot-tagged EBS snapshots
- Load Balancers and Target Groups matching the project
- VPC endpoints
- unattached TerraPilot ENIs
- Internet Gateways attached to TerraPilot VPCs
- custom route tables in TerraPilot VPCs
- non-default TerraPilot security groups
- subnets in TerraPilot VPCs
- TerraPilot VPCs after dependencies
- SSM parameters under `/terrapilot/<project>/`
- CloudWatch log groups under `/terrapilot/<project>`

## Manual / High-Risk Resources

These are listed in the plan but are not auto-deleted by default:

- EKS clusters
- ECR repositories
- S3 buckets
- IAM roles
- IAM instance profiles

These resources are manual/high-risk because they may contain application data, images, or permissions used by other systems.

AWS service-linked roles are never deleted.

## Optional Local Overrides

Copy `terraform/CLEANUP_ENV.example.bat` to `terraform/CLEANUP_ENV.bat` only if you need to override:

- `AWS_REGION`
- `AWS_PROFILE`
- `PROJECT_NAME`
- `ENVIRONMENT`
- `AUDIT_REPORT_PATH`
- `CLEANUP_PLAN_PATH`

Do not commit `CLEANUP_ENV.bat` if it contains local account/profile details.

## Verify After Cleanup

Run the audit again:

```bat
post-destroy-audit.bat
```

Also check the AWS Console for Elastic IPs, NAT Gateways, EBS volumes/snapshots, Load Balancers, S3 buckets, ECR repositories, IAM roles, and CloudWatch logs.
