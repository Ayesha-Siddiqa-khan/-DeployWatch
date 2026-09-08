$ErrorActionPreference = "Continue"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:AWS_PAGER = ""

function Get-HclStringValue {
  param([string]$Path, [string]$Key)
  if (-not (Test-Path -LiteralPath $Path)) { return "" }
  $dq = [char]34
  $pattern = "^\s*$([regex]::Escape($Key))\s*=\s*$dq([^$dq]*)$dq"
  foreach ($line in [System.IO.File]::ReadLines($Path)) {
    $match = [regex]::Match($line, $pattern)
    if ($match.Success) { return $match.Groups[1].Value }
  }
  return ""
}

$tfvars = Join-Path $Root "terraform.tfvars"
$mainTf = Join-Path $Root "main.tf"

$region = $env:AWS_REGION
$regionSource = if ($region) { "environment or AWS_AUDIT_ENV.bat" } else { "" }
$projectName = $env:PROJECT_NAME
$projectSource = if ($projectName) { "environment or AWS_AUDIT_ENV.bat" } else { "" }
$environment = $env:ENVIRONMENT
$environmentSource = if ($environment) { "environment or AWS_AUDIT_ENV.bat" } else { "" }
$ecrRepository = $env:ECR_REPOSITORY
$ecrSource = if ($ecrRepository) { "environment or AWS_AUDIT_ENV.bat" } else { "" }

if (-not $region) { $region = Get-HclStringValue $tfvars "region"; if ($region) { $regionSource = "terraform.tfvars" } }
if (-not $projectName) { $projectName = Get-HclStringValue $tfvars "project_name"; if ($projectName) { $projectSource = "terraform.tfvars" } }
if (-not $environment) { $environment = Get-HclStringValue $tfvars "environment"; if ($environment) { $environmentSource = "terraform.tfvars" } }
if (-not $ecrRepository) { $ecrRepository = Get-HclStringValue $tfvars "ecr_repository_name"; if ($ecrRepository) { $ecrSource = "terraform.tfvars" } }
if (-not $region) { $region = Get-HclStringValue $mainTf "region"; if ($region) { $regionSource = "main.tf provider" } }
if (-not $projectName) { $projectName = Get-HclStringValue $mainTf "Project"; if ($projectName) { $projectSource = "main.tf default_tags" } }
if (-not $environment) { $environment = Get-HclStringValue $mainTf "Environment"; if ($environment) { $environmentSource = "main.tf default_tags" } }
if (-not $region -and $env:AWS_DEFAULT_REGION) { $region = $env:AWS_DEFAULT_REGION; $regionSource = "AWS_DEFAULT_REGION" }

$profileArgs = @()
if ($env:AWS_PROFILE) { $profileArgs = @("--profile", $env:AWS_PROFILE) }
if (-not $region) {
  $configuredRegion = (& aws configure get region @profileArgs 2>$null)
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($configuredRegion)) {
    $region = $configuredRegion.Trim()
    $regionSource = "AWS CLI profile config"
  }
}
if (-not $region) { $region = "us-east-1"; $regionSource = "generated default" }
if (-not $projectName) { $projectName = "DeployWatch"; $projectSource = "generated default" }
if (-not $environment) { $environment = "dev"; $environmentSource = "generated default" }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$safeProjectName = $projectName -replace "[^A-Za-z0-9._-]", "-"
$reportDir = Join-Path $Root "post-destroy-audits"
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$report = Join-Path $reportDir "aws-audit-$safeProjectName-$timestamp.txt"

Write-Host "Using AWS region: $region ($regionSource)"
Write-Host "Project filter: $projectName ($projectSource)"
Write-Host "Environment: $environment ($environmentSource)"
if ($env:AWS_PROFILE) { Write-Host "AWS profile: $env:AWS_PROFILE" }
if ($ecrRepository) { Write-Host "ECR repository from config: $ecrRepository ($ecrSource)" }
Write-Host ""

@(
  "TerraPilot Post-Destroy AWS Audit",
  "Project: $projectName",
  "Region: $region",
  "Region source: $regionSource",
  "Environment: $environment",
  "Environment source: $environmentSource",
  $(if ($env:AWS_PROFILE) { "AWS profile: $env:AWS_PROFILE" }),
  $(if ($ecrRepository) { "ECR repository from config: $ecrRepository ($ecrSource)" }),
  "Timestamp: $timestamp",
  ""
) | Where-Object { $_ -ne $null } | Set-Content -LiteralPath $report

function Run-Audit {
  param([string]$Label, [string[]]$AwsArgs)
  Write-Host "[$Label]"
  Add-Content -LiteralPath $report -Value "[$Label]"
  Add-Content -LiteralPath $report -Value ("Command: aws " + ($AwsArgs -join " "))
  $output = & aws @AwsArgs 2>&1
  $exitCode = $LASTEXITCODE
  if ($null -ne $output) { $output | Out-String | Add-Content -LiteralPath $report }
  if ($exitCode -ne 0) {
    Write-Host "WARNING: $Label check failed or requires additional permission."
    Add-Content -LiteralPath $report -Value "WARNING: $Label check failed or requires additional permission."
  } else {
    Write-Host "OK: $Label"
    Add-Content -LiteralPath $report -Value "OK: $Label"
  }
  Add-Content -LiteralPath $report -Value ""
}

$checks = @(
  @{ Label = "AWS identity"; Scope = "global"; Args = @("sts", "get-caller-identity") },
  @{ Label = "EC2 active instances in region manual check"; Scope = "region"; Args = @("ec2", "describe-instances", "--filters", "Name=instance-state-name,Values=pending,running,stopping,stopped", "--query", "Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType,PublicIp:PublicIpAddress,VpcId:VpcId}", "--output", "table") },
  @{ Label = "EC2 instances tagged by TerraPilot"; Scope = "region"; Args = @("ec2", "describe-instances", "--filters", "Name=tag:ManagedBy,Values=TerraPilot", "Name=tag:Project,Values=$projectName", "--query", "Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType,PublicIp:PublicIpAddress}", "--output", "table") },
  @{ Label = "Elastic IP allocations in region manual check"; Scope = "region"; Args = @("ec2", "describe-addresses", "--query", "Addresses[].{AllocationId:AllocationId,PublicIp:PublicIp,InstanceId:InstanceId,AssociationId:AssociationId}", "--output", "table") },
  @{ Label = "Elastic IP allocations tagged by TerraPilot"; Scope = "region"; Args = @("ec2", "describe-addresses", "--filters", "Name=tag:ManagedBy,Values=TerraPilot", "Name=tag:Project,Values=$projectName", "--query", "Addresses[].{AllocationId:AllocationId,PublicIp:PublicIp,InstanceId:InstanceId,AssociationId:AssociationId}", "--output", "table") },
  @{ Label = "NAT gateways active in region manual check"; Scope = "region"; Args = @("ec2", "describe-nat-gateways", "--filter", "Name=state,Values=pending,available", "--query", "NatGateways[].{Id:NatGatewayId,State:State,SubnetId:SubnetId,VpcId:VpcId}", "--output", "table") },
  @{ Label = "NAT gateways tagged by TerraPilot"; Scope = "region"; Args = @("ec2", "describe-nat-gateways", "--filter", "Name=tag:ManagedBy,Values=TerraPilot", "Name=tag:Project,Values=$projectName", "--query", "NatGateways[].{Id:NatGatewayId,State:State,SubnetId:SubnetId,VpcId:VpcId}", "--output", "table") },
  @{ Label = "Load balancers manual check"; Scope = "region"; Args = @("elbv2", "describe-load-balancers", "--query", "LoadBalancers[].{Name:LoadBalancerName,Arn:LoadBalancerArn,State:State.Code,Type:Type}", "--output", "table") },
  @{ Label = "EKS clusters manual check"; Scope = "region"; Args = @("eks", "list-clusters", "--output", "table") },
  @{ Label = "ECS clusters manual check"; Scope = "region"; Args = @("ecs", "list-clusters", "--output", "table") },
  @{ Label = "Lambda functions manual check"; Scope = "region"; Args = @("lambda", "list-functions", "--query", "Functions[].{Name:FunctionName,Runtime:Runtime,Modified:LastModified}", "--output", "table") },
  @{ Label = "EBS volumes in-use or available manual check"; Scope = "region"; Args = @("ec2", "describe-volumes", "--filters", "Name=status,Values=available,in-use", "--query", "Volumes[].{Id:VolumeId,State:State,Size:Size,Attachments:Attachments[].InstanceId}", "--output", "table") },
  @{ Label = "EBS volumes tagged by TerraPilot"; Scope = "region"; Args = @("ec2", "describe-volumes", "--filters", "Name=tag:ManagedBy,Values=TerraPilot", "Name=tag:Project,Values=$projectName", "--query", "Volumes[].{Id:VolumeId,State:State,Size:Size,Attachments:Attachments[].InstanceId}", "--output", "table") },
  @{ Label = "EBS snapshots tagged by TerraPilot"; Scope = "region"; Args = @("ec2", "describe-snapshots", "--owner-ids", "self", "--filters", "Name=tag:ManagedBy,Values=TerraPilot", "Name=tag:Project,Values=$projectName", "--query", "Snapshots[].{Id:SnapshotId,State:State,Size:VolumeSize,Started:StartTime}", "--output", "table") },
  @{ Label = "VPCs tagged by TerraPilot"; Scope = "region"; Args = @("ec2", "describe-vpcs", "--filters", "Name=tag:ManagedBy,Values=TerraPilot", "Name=tag:Project,Values=$projectName", "--query", "Vpcs[].{Id:VpcId,State:State,Cidr:CidrBlock}", "--output", "table") },
  @{ Label = "Subnets tagged by TerraPilot"; Scope = "region"; Args = @("ec2", "describe-subnets", "--filters", "Name=tag:ManagedBy,Values=TerraPilot", "Name=tag:Project,Values=$projectName", "--query", "Subnets[].{Id:SubnetId,VpcId:VpcId,Cidr:CidrBlock,AZ:AvailabilityZone}", "--output", "table") },
  @{ Label = "Route tables tagged by TerraPilot"; Scope = "region"; Args = @("ec2", "describe-route-tables", "--filters", "Name=tag:ManagedBy,Values=TerraPilot", "Name=tag:Project,Values=$projectName", "--query", "RouteTables[].{Id:RouteTableId,VpcId:VpcId,Routes:Routes[].GatewayId}", "--output", "table") },
  @{ Label = "Internet gateways tagged by TerraPilot"; Scope = "region"; Args = @("ec2", "describe-internet-gateways", "--filters", "Name=tag:ManagedBy,Values=TerraPilot", "Name=tag:Project,Values=$projectName", "--query", "InternetGateways[].{Id:InternetGatewayId,Attachments:Attachments[].VpcId}", "--output", "table") },
  @{ Label = "Security groups tagged by TerraPilot"; Scope = "region"; Args = @("ec2", "describe-security-groups", "--filters", "Name=tag:ManagedBy,Values=TerraPilot", "Name=tag:Project,Values=$projectName", "--query", "SecurityGroups[].{Id:GroupId,Name:GroupName,VpcId:VpcId}", "--output", "table") },
  @{ Label = "Network interfaces tagged by TerraPilot"; Scope = "region"; Args = @("ec2", "describe-network-interfaces", "--filters", "Name=tag:ManagedBy,Values=TerraPilot", "Name=tag:Project,Values=$projectName", "--query", "NetworkInterfaces[].{Id:NetworkInterfaceId,Status:Status,Attachment:Attachment.InstanceId,PrivateIp:PrivateIpAddress}", "--output", "table") },
  @{ Label = "VPC endpoints tagged by TerraPilot"; Scope = "region"; Args = @("ec2", "describe-vpc-endpoints", "--filters", "Name=tag:ManagedBy,Values=TerraPilot", "Name=tag:Project,Values=$projectName", "--query", "VpcEndpoints[].{Id:VpcEndpointId,State:State,Service:ServiceName,VpcId:VpcId}", "--output", "table") },
  @{ Label = "RDS DB instances manual check"; Scope = "region"; Args = @("rds", "describe-db-instances", "--query", "DBInstances[].{Id:DBInstanceIdentifier,Status:DBInstanceStatus,Class:DBInstanceClass,Engine:Engine}", "--output", "table") },
  @{ Label = "ECR repositories manual check"; Scope = "region"; Args = @("ecr", "describe-repositories", "--query", "repositories[].{Name:repositoryName,Uri:repositoryUri,Created:createdAt}", "--output", "table") },
  @{ Label = "S3 buckets account manual check"; Scope = "global"; Args = @("s3api", "list-buckets", "--query", "Buckets[].{Name:Name,Created:CreationDate}", "--output", "table") },
  @{ Label = "CloudFormation active stacks manual check"; Scope = "region"; Args = @("cloudformation", "list-stacks", "--stack-status-filter", "CREATE_COMPLETE", "UPDATE_COMPLETE", "UPDATE_ROLLBACK_COMPLETE", "ROLLBACK_COMPLETE", "IMPORT_COMPLETE", "--query", "StackSummaries[].{Name:StackName,Status:StackStatus,Updated:LastUpdatedTime}", "--output", "table") },
  @{ Label = "CloudWatch TerraPilot log groups"; Scope = "region"; Args = @("logs", "describe-log-groups", "--log-group-name-prefix", "/terrapilot", "--query", "logGroups[].{Name:logGroupName,Retention:retentionInDays,StoredBytes:storedBytes}", "--output", "table") },
  @{ Label = "SSM TerraPilot parameters"; Scope = "region"; Args = @("ssm", "describe-parameters", "--parameter-filters", "Key=Name,Option=Contains,Values=/terrapilot/", "--query", "Parameters[].{Name:Name,Type:Type,LastModified:LastModifiedDate}", "--output", "table") },
  @{ Label = "IAM roles manual check"; Scope = "global"; Args = @("iam", "list-roles", "--query", "Roles[].{Name:RoleName,Arn:Arn,Created:CreateDate}", "--output", "table") },
  @{ Label = "IAM instance profiles manual check"; Scope = "global"; Args = @("iam", "list-instance-profiles", "--query", "InstanceProfiles[].{Name:InstanceProfileName,Arn:Arn,Created:CreateDate}", "--output", "table") },
  @{ Label = "AWS Backup vaults manual check"; Scope = "region"; Args = @("backup", "list-backup-vaults", "--query", "BackupVaultList[].{Name:BackupVaultName,RecoveryPoints:NumberOfRecoveryPoints}", "--output", "table") }
)

foreach ($check in $checks) {
  $awsArgs = @($check.Args)
  if ($check.Scope -eq "region") { $awsArgs = @($awsArgs + @("--region", $region)) }
  $awsArgs = @($awsArgs + $profileArgs)
  Run-Audit $check.Label $awsArgs
}

Add-Content -LiteralPath $report -Value ""
Add-Content -LiteralPath $report -Value "COST RISK / MANUAL CHECK cleanup suggestions only - not executed:"
Add-Content -LiteralPath $report -Value "SUGGESTION ONLY: aws ec2 release-address --allocation-id <allocation-id> --region $region"
Add-Content -LiteralPath $report -Value "SUGGESTION ONLY: aws ec2 delete-volume --volume-id <volume-id> --region $region"
Add-Content -LiteralPath $report -Value "SUGGESTION ONLY: aws logs delete-log-group --log-group-name <log-group-name> --region $region"
Add-Content -LiteralPath $report -Value "SUGGESTION ONLY: aws ecr delete-repository --repository-name <repository-name> --force --region $region"
Add-Content -LiteralPath $report -Value "SUGGESTION ONLY: aws s3 rb s3://<bucket-name> --force"

Write-Host ""
Write-Host ('Audit complete. Report: "{0}"' -f $report)
Write-Host "Review WARNING, COST RISK, and MANUAL CHECK sections before assuming destroy is complete."
