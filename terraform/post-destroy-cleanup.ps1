param(
  [ValidateSet("Plan", "Execute")]
  [string]$Mode = "Plan",
  [string]$AuditReportPath = $env:AUDIT_REPORT_PATH,
  [string]$CleanupPlanPath = $env:CLEANUP_PLAN_PATH
)

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

function Read-Value {
  param([string]$Prompt, [string]$Default)
  if ($Default) {
    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
  }
  return (Read-Host $Prompt).Trim()
}

$tfvars = Join-Path $Root "terraform.tfvars"
$mainTf = Join-Path $Root "main.tf"
$region = $env:AWS_REGION
$projectName = $env:PROJECT_NAME
$environment = $env:ENVIRONMENT

if (-not $region) { $region = Get-HclStringValue $tfvars "region" }
if (-not $projectName) { $projectName = Get-HclStringValue $tfvars "project_name" }
if (-not $environment) { $environment = Get-HclStringValue $tfvars "environment" }
if (-not $region) { $region = Get-HclStringValue $mainTf "region" }
if (-not $projectName) { $projectName = Get-HclStringValue $mainTf "Project" }
if (-not $environment) { $environment = Get-HclStringValue $mainTf "Environment" }
if (-not $region -and $env:AWS_DEFAULT_REGION) { $region = $env:AWS_DEFAULT_REGION }

$profileArgs = @()
if ($env:AWS_PROFILE) { $profileArgs = @("--profile", $env:AWS_PROFILE) }
if (-not $region) {
  $configuredRegion = (& aws configure get region @profileArgs 2>$null)
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($configuredRegion)) { $region = $configuredRegion.Trim() }
}
if (-not $region) { $region = "us-east-1" }
if (-not $projectName) { $projectName = "DeployWatch" }
if (-not $environment) { $environment = "dev" }

if (-not $env:PROJECT_NAME) { $projectName = Read-Value "Project name for TerraPilot cleanup scope" $projectName }
if (-not $env:AWS_REGION) { $region = Read-Value "AWS region for cleanup" $region }

function Find-LatestAuditReport {
  $auditDir = Join-Path $Root "post-destroy-audits"
  if (-not (Test-Path -LiteralPath $auditDir)) { return "" }
  $patterns = @("post-destroy-audit-report-*.txt", "aws-audit-*.txt")
  $reports = foreach ($pattern in $patterns) { Get-ChildItem -LiteralPath $auditDir -Filter $pattern -File -ErrorAction SilentlyContinue }
  $latest = $reports | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($latest) { return $latest.FullName }
  return ""
}

if (-not $AuditReportPath) { $AuditReportPath = Find-LatestAuditReport }
if (-not $AuditReportPath) {
  $AuditReportPath = Read-Host "No audit report found automatically. Enter an audit report path, or press Enter to continue with live AWS checks only"
}
$auditSummary = "No audit report supplied. Live AWS checks only."
if ($AuditReportPath -and (Test-Path -LiteralPath $AuditReportPath)) {
  $auditSummary = "Audit report: $AuditReportPath"
  $auditText = Get-Content -LiteralPath $AuditReportPath -Raw -ErrorAction SilentlyContinue
} elseif ($AuditReportPath) {
  Write-Host "[WARNING] Audit report path was not found: $AuditReportPath"
  $auditSummary = "Audit report path not found. Live AWS checks only."
}
if (-not $auditText) { $auditText = "" }

Write-Host "Checking AWS identity..."
$identityJson = & aws sts get-caller-identity @profileArgs --output json 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Host "[ERROR] Unable to read AWS identity. Check AWS credentials/profile."
  Write-Host $identityJson
  exit 1
}
$identity = $identityJson | ConvertFrom-Json
Write-Host "AWS account: $($identity.Account)"
Write-Host "AWS ARN: $($identity.Arn)"
Write-Host "AWS region: $region"
Write-Host "Project cleanup scope: $projectName"
if ($env:AWS_PROFILE) { Write-Host "AWS profile: $env:AWS_PROFILE" }
Write-Host $auditSummary
Write-Host ""

function Invoke-AwsJson {
  param([string[]]$Args, [switch]$Global)
  $fullArgs = @($Args)
  if (-not $Global) { $fullArgs += @("--region", $region) }
  $fullArgs += @("--output", "json")
  $output = & aws @profileArgs @fullArgs 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($output | Out-String))) { return $null }
  try { return ($output | Out-String | ConvertFrom-Json) } catch { return $null }
}

function Test-TerraPilotName {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  return ($Value -like "*$projectName*" -or $Value -like "/terrapilot/$projectName/*" -or $Value -like "/terrapilot/*/$projectName/*")
}

$items = New-Object System.Collections.Generic.List[object]
$auditHints = New-Object System.Collections.Generic.List[object]
function Add-CleanupItem {
  param(
    [string]$Type,
    [string]$Id,
    [string]$Billable,
    [bool]$AutoDelete,
    [string]$Command,
    [string]$Reason,
    [string[]]$DeleteArgs,
    [string[]]$VerifyArgs,
    [string]$SeparateConfirmation = "",
    [string]$Notes = ""
  )
  if ([string]::IsNullOrWhiteSpace($Id)) { return }
  $items.Add([pscustomobject]@{
    Type = $Type
    Id = $Id
    Region = $region
    Billable = $Billable
    AutoDelete = $AutoDelete
    Command = $Command
    Reason = $Reason
    DeleteArgs = $DeleteArgs
    VerifyArgs = $VerifyArgs
    SeparateConfirmation = $SeparateConfirmation
    Notes = $Notes
  }) | Out-Null
}

function Add-AuditHint {
  param([string]$Type, [string]$Id, [string]$Reason)
  if ([string]::IsNullOrWhiteSpace($Id)) { return }
  if (($auditHints | Where-Object { $_.Type -eq $Type -and $_.Id -eq $Id }).Count -gt 0) { return }
  $auditHints.Add([pscustomobject]@{ Type = $Type; Id = $Id; Reason = $Reason }) | Out-Null
}

function Add-AuditRegexHints {
  param([string]$Type, [string]$Pattern, [string]$Reason)
  if ([string]::IsNullOrWhiteSpace($auditText)) { return }
  foreach ($match in [regex]::Matches($auditText, $Pattern)) {
    Add-AuditHint $Type $match.Value $Reason
  }
}

if ($auditText) {
  Add-AuditRegexHints "Elastic IP" "eipalloc-[a-zA-Z0-9]+" "ID appeared in the audit report."
  Add-AuditRegexHints "NAT Gateway" "nat-[a-zA-Z0-9]+" "ID appeared in the audit report."
  Add-AuditRegexHints "EBS volume" "vol-[a-zA-Z0-9]+" "ID appeared in the audit report."
  Add-AuditRegexHints "EBS snapshot" "snap-[a-zA-Z0-9]+" "ID appeared in the audit report."
  Add-AuditRegexHints "Load balancer ARN" "arn:aws:elasticloadbalancing:[^\s|]+" "ARN appeared in the audit report."
  Add-AuditRegexHints "VPC endpoint" "vpce-[a-zA-Z0-9]+" "ID appeared in the audit report."
  Add-AuditRegexHints "Network interface" "eni-[a-zA-Z0-9]+" "ID appeared in the audit report."
  Add-AuditRegexHints "Internet Gateway" "igw-[a-zA-Z0-9]+" "ID appeared in the audit report."
  Add-AuditRegexHints "Security group" "sg-[a-zA-Z0-9]+" "ID appeared in the audit report."
  Add-AuditRegexHints "Route table" "rtb-[a-zA-Z0-9]+" "ID appeared in the audit report."
  Add-AuditRegexHints "Subnet" "subnet-[a-zA-Z0-9]+" "ID appeared in the audit report."
  Add-AuditRegexHints "VPC" "vpc-[a-zA-Z0-9]+" "ID appeared in the audit report."
  foreach ($match in [regex]::Matches($auditText, "/terrapilot/$([regex]::Escape($projectName))/[^\s|]+")) {
    Add-AuditHint "SSM parameter or TerraPilot path" $match.Value "TerraPilot project path appeared in the audit report."
  }
}

function Get-TerraPilotTagFilters {
  return @("Name=tag:ManagedBy,Values=TerraPilot", "Name=tag:Project,Values=$projectName")
}

$tagFilters = Get-TerraPilotTagFilters

$addresses = Invoke-AwsJson (@("ec2", "describe-addresses", "--filters") + $tagFilters)
if ($addresses -and $addresses.Addresses) {
  foreach ($a in @($addresses.Addresses)) {
    Add-CleanupItem "Elastic IP" $a.AllocationId "High cost risk" $true "aws ec2 release-address --allocation-id $($a.AllocationId) --region $region" "TerraPilot-tagged Elastic IP found after destroy." @("ec2", "release-address", "--allocation-id", $a.AllocationId) @("ec2", "describe-addresses", "--allocation-ids", $a.AllocationId)
  }
}

$nat = Invoke-AwsJson (@("ec2", "describe-nat-gateways", "--filter") + $tagFilters)
if ($nat -and $nat.NatGateways) {
  foreach ($n in @($nat.NatGateways)) {
    if (@("pending", "available", "failed") -contains $n.State) {
      Add-CleanupItem "NAT Gateway" $n.NatGatewayId "High cost risk" $true "aws ec2 delete-nat-gateway --nat-gateway-id $($n.NatGatewayId) --region $region" "TerraPilot-tagged NAT gateway is not deleted." @("ec2", "delete-nat-gateway", "--nat-gateway-id", $n.NatGatewayId) @("ec2", "describe-nat-gateways", "--nat-gateway-ids", $n.NatGatewayId)
    }
  }
}

$volumes = Invoke-AwsJson (@("ec2", "describe-volumes", "--filters", "Name=status,Values=available") + $tagFilters)
if ($volumes -and $volumes.Volumes) {
  foreach ($v in @($volumes.Volumes)) {
    Add-CleanupItem "Unattached EBS volume" $v.VolumeId "Cost risk" $true "aws ec2 delete-volume --volume-id $($v.VolumeId) --region $region" "Available TerraPilot-tagged volume is unattached." @("ec2", "delete-volume", "--volume-id", $v.VolumeId) @("ec2", "describe-volumes", "--volume-ids", $v.VolumeId)
  }
}

$snapshots = Invoke-AwsJson (@("ec2", "describe-snapshots", "--owner-ids", "self", "--filters") + $tagFilters)
if ($snapshots -and $snapshots.Snapshots) {
  foreach ($s in @($snapshots.Snapshots)) {
    Add-CleanupItem "EBS snapshot" $s.SnapshotId "Cost risk" $true "aws ec2 delete-snapshot --snapshot-id $($s.SnapshotId) --region $region" "TerraPilot-tagged snapshot remains." @("ec2", "delete-snapshot", "--snapshot-id", $s.SnapshotId) @("ec2", "describe-snapshots", "--snapshot-ids", $s.SnapshotId)
  }
}

$vpces = Invoke-AwsJson (@("ec2", "describe-vpc-endpoints", "--filters") + $tagFilters)
if ($vpces -and $vpces.VpcEndpoints) {
  foreach ($e in @($vpces.VpcEndpoints)) {
    Add-CleanupItem "VPC endpoint" $e.VpcEndpointId "Possible cost risk" $true "aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $($e.VpcEndpointId) --region $region" "TerraPilot-tagged VPC endpoint remains." @("ec2", "delete-vpc-endpoints", "--vpc-endpoint-ids", $e.VpcEndpointId) @("ec2", "describe-vpc-endpoints", "--vpc-endpoint-ids", $e.VpcEndpointId)
  }
}

$enis = Invoke-AwsJson (@("ec2", "describe-network-interfaces", "--filters") + $tagFilters)
if ($enis -and $enis.NetworkInterfaces) {
  foreach ($eni in @($enis.NetworkInterfaces)) {
    $attached = $null -ne $eni.Attachment
    Add-CleanupItem "Network interface" $eni.NetworkInterfaceId "No direct cost, dependency blocker" (-not $attached) "aws ec2 delete-network-interface --network-interface-id $($eni.NetworkInterfaceId) --region $region" "TerraPilot-tagged unattached ENI remains. Attached ENIs are manual only." @("ec2", "delete-network-interface", "--network-interface-id", $eni.NetworkInterfaceId) @("ec2", "describe-network-interfaces", "--network-interface-ids", $eni.NetworkInterfaceId) "" $(if ($attached) { "Attached ENI: manual review only." } else { "" })
  }
}

$vpcs = Invoke-AwsJson (@("ec2", "describe-vpcs", "--filters") + $tagFilters)
if ($vpcs -and $vpcs.Vpcs) {
  foreach ($vpc in @($vpcs.Vpcs)) {
    $vpcId = $vpc.VpcId
    $igws = Invoke-AwsJson @("ec2", "describe-internet-gateways", "--filters", "Name=attachment.vpc-id,Values=$vpcId")
    if ($igws -and $igws.InternetGateways) {
      foreach ($igw in @($igws.InternetGateways)) {
        Add-CleanupItem "Internet Gateway" $igw.InternetGatewayId "No direct cost, dependency blocker" $true "aws ec2 detach-internet-gateway --internet-gateway-id $($igw.InternetGatewayId) --vpc-id $vpcId --region $region && aws ec2 delete-internet-gateway --internet-gateway-id $($igw.InternetGatewayId) --region $region" "Internet gateway attached to TerraPilot VPC." @("ec2", "detach-internet-gateway", "--internet-gateway-id", $igw.InternetGatewayId, "--vpc-id", $vpcId, "&&", "ec2", "delete-internet-gateway", "--internet-gateway-id", $igw.InternetGatewayId) @("ec2", "describe-internet-gateways", "--internet-gateway-ids", $igw.InternetGatewayId)
      }
    }
    $routeTables = Invoke-AwsJson @("ec2", "describe-route-tables", "--filters", "Name=vpc-id,Values=$vpcId")
    if ($routeTables -and $routeTables.RouteTables) {
      foreach ($rt in @($routeTables.RouteTables)) {
        $isMain = @($rt.Associations) | Where-Object { $_.Main -eq $true }
        if (-not $isMain) {
          Add-CleanupItem "Route table" $rt.RouteTableId "No direct cost, dependency blocker" $true "aws ec2 delete-route-table --route-table-id $($rt.RouteTableId) --region $region" "Custom route table in TerraPilot VPC." @("ec2", "delete-route-table", "--route-table-id", $rt.RouteTableId) @("ec2", "describe-route-tables", "--route-table-ids", $rt.RouteTableId)
        }
      }
    }
    $sgs = Invoke-AwsJson @("ec2", "describe-security-groups", "--filters", "Name=vpc-id,Values=$vpcId")
    if ($sgs -and $sgs.SecurityGroups) {
      foreach ($sg in @($sgs.SecurityGroups)) {
        if ($sg.GroupName -ne "default" -and (Test-TerraPilotName $sg.GroupName)) {
          Add-CleanupItem "Security group" $sg.GroupId "No direct cost, dependency blocker" $true "aws ec2 delete-security-group --group-id $($sg.GroupId) --region $region" "Non-default TerraPilot-named security group in TerraPilot VPC." @("ec2", "delete-security-group", "--group-id", $sg.GroupId) @("ec2", "describe-security-groups", "--group-ids", $sg.GroupId)
        }
      }
    }
    $subnets = Invoke-AwsJson @("ec2", "describe-subnets", "--filters", "Name=vpc-id,Values=$vpcId")
    if ($subnets -and $subnets.Subnets) {
      foreach ($s in @($subnets.Subnets)) {
        Add-CleanupItem "Subnet" $s.SubnetId "No direct cost, dependency blocker" $true "aws ec2 delete-subnet --subnet-id $($s.SubnetId) --region $region" "Subnet belongs to TerraPilot-tagged VPC." @("ec2", "delete-subnet", "--subnet-id", $s.SubnetId) @("ec2", "describe-subnets", "--subnet-ids", $s.SubnetId)
      }
    }
    Add-CleanupItem "VPC" $vpcId "No direct cost, dependency blocker" $true "aws ec2 delete-vpc --vpc-id $vpcId --region $region" "TerraPilot-tagged VPC remains after dependencies." @("ec2", "delete-vpc", "--vpc-id", $vpcId) @("ec2", "describe-vpcs", "--vpc-ids", $vpcId)
  }
}

$ssm = Invoke-AwsJson @("ssm", "describe-parameters", "--parameter-filters", "Key=Name,Option=BeginsWith,Values=/terrapilot/$projectName/")
if ($ssm -and $ssm.Parameters) {
  foreach ($p in @($ssm.Parameters)) {
    Add-CleanupItem "SSM parameter" $p.Name "No direct cost, sensitive cleanup" $true "aws ssm delete-parameter --name $($p.Name) --region $region" "SSM parameter path starts with /terrapilot/$projectName/." @("ssm", "delete-parameter", "--name", $p.Name) @("ssm", "get-parameter", "--name", $p.Name)
  }
}

$logs = Invoke-AwsJson @("logs", "describe-log-groups", "--log-group-name-prefix", "/terrapilot/$projectName")
if ($logs -and $logs.logGroups) {
  foreach ($lg in @($logs.logGroups)) {
    Add-CleanupItem "CloudWatch log group" $lg.logGroupName "Possible cost risk" $true "aws logs delete-log-group --log-group-name $($lg.logGroupName) --region $region" "Log group starts with /terrapilot/$projectName." @("logs", "delete-log-group", "--log-group-name", $lg.logGroupName) @("logs", "describe-log-groups", "--log-group-name-prefix", $lg.logGroupName)
  }
}

$lbs = Invoke-AwsJson @("elbv2", "describe-load-balancers")
if ($lbs -and $lbs.LoadBalancers) {
  foreach ($lb in @($lbs.LoadBalancers)) {
    if (Test-TerraPilotName $lb.LoadBalancerName) {
      Add-CleanupItem "Load balancer" $lb.LoadBalancerArn "Cost risk" $true "aws elbv2 delete-load-balancer --load-balancer-arn $($lb.LoadBalancerArn) --region $region" "Load balancer name matches TerraPilot project." @("elbv2", "delete-load-balancer", "--load-balancer-arn", $lb.LoadBalancerArn) @("elbv2", "describe-load-balancers", "--load-balancer-arns", $lb.LoadBalancerArn)
    }
  }
}

$tgs = Invoke-AwsJson @("elbv2", "describe-target-groups")
if ($tgs -and $tgs.TargetGroups) {
  foreach ($tg in @($tgs.TargetGroups)) {
    if (Test-TerraPilotName $tg.TargetGroupName) {
      Add-CleanupItem "Target group" $tg.TargetGroupArn "No direct cost, dependency blocker" $true "aws elbv2 delete-target-group --target-group-arn $($tg.TargetGroupArn) --region $region" "Target group name matches TerraPilot project." @("elbv2", "delete-target-group", "--target-group-arn", $tg.TargetGroupArn) @("elbv2", "describe-target-groups", "--target-group-arns", $tg.TargetGroupArn)
    }
  }
}

$clusters = Invoke-AwsJson @("eks", "list-clusters")
if ($clusters -and $clusters.clusters) {
  foreach ($cluster in @($clusters.clusters)) {
    if (Test-TerraPilotName $cluster) {
      Add-CleanupItem "EKS cluster" $cluster "High cost risk" $false "aws eks delete-cluster --name $cluster --region $region" "EKS cluster name matches TerraPilot project. Manual confirmation required." @("eks", "delete-cluster", "--name", $cluster) @("eks", "describe-cluster", "--name", $cluster) "DELETE EKS CLUSTER $cluster"
    }
  }
}

$ecr = Invoke-AwsJson @("ecr", "describe-repositories")
if ($ecr -and $ecr.repositories) {
  foreach ($repo in @($ecr.repositories)) {
    if (Test-TerraPilotName $repo.repositoryName) {
      Add-CleanupItem "ECR repository" $repo.repositoryName "Manual high-risk" $false "aws ecr delete-repository --repository-name $($repo.repositoryName) --force --region $region" "Repository name matches TerraPilot project, but images may be important." @("ecr", "delete-repository", "--repository-name", $repo.repositoryName, "--force") @("ecr", "describe-repositories", "--repository-names", $repo.repositoryName) "DELETE ECR REPOSITORY $($repo.repositoryName)"
    }
  }
}

$buckets = Invoke-AwsJson @("s3api", "list-buckets") -Global
if ($buckets -and $buckets.Buckets) {
  foreach ($bucket in @($buckets.Buckets)) {
    if (Test-TerraPilotName $bucket.Name) {
      Add-CleanupItem "S3 bucket" $bucket.Name "Manual high-risk" $false "aws s3 rb s3://$($bucket.Name) --force" "Bucket name matches TerraPilot project, but buckets may contain important data." @("s3", "rb", "s3://$($bucket.Name)", "--force") @("s3api", "head-bucket", "--bucket", $bucket.Name) "DELETE S3 BUCKET $($bucket.Name)"
    }
  }
}

$roles = Invoke-AwsJson @("iam", "list-roles") -Global
if ($roles -and $roles.Roles) {
  foreach ($role in @($roles.Roles)) {
    if ($role.Path -like "/aws-service-role/*") { continue }
    if (Test-TerraPilotName $role.RoleName) {
      Add-CleanupItem "IAM role" $role.RoleName "Manual high-risk" $false "Manual IAM cleanup required: detach managed policies, delete inline policies, then delete role." "Role name matches TerraPilot project. AWS service-linked roles are excluded." @() @("iam", "get-role", "--role-name", $role.RoleName) "DELETE IAM ROLE $($role.RoleName)" "Plan-only by default because IAM cleanup can break other systems."
    }
  }
}

$profiles = Invoke-AwsJson @("iam", "list-instance-profiles") -Global
if ($profiles -and $profiles.InstanceProfiles) {
  foreach ($profile in @($profiles.InstanceProfiles)) {
    if (Test-TerraPilotName $profile.InstanceProfileName) {
      Add-CleanupItem "IAM instance profile" $profile.InstanceProfileName "Manual high-risk" $false "Manual IAM cleanup required: remove role from instance profile, then delete instance profile." "Instance profile name matches TerraPilot project." @() @("iam", "get-instance-profile", "--instance-profile-name", $profile.InstanceProfileName) "DELETE IAM INSTANCE PROFILE $($profile.InstanceProfileName)" "Plan-only by default because IAM cleanup can break other systems."
    }
  }
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$safeProjectName = $projectName -replace "[^A-Za-z0-9._-]", "-"
$planDir = Join-Path $Root "post-destroy-cleanup-plans"
New-Item -ItemType Directory -Force -Path $planDir | Out-Null
if (-not $CleanupPlanPath) { $CleanupPlanPath = Join-Path $planDir "post-destroy-cleanup-plan-$safeProjectName-$timestamp.txt" }

$planLines = New-Object System.Collections.Generic.List[string]
$planLines.Add("TerraPilot Post-Destroy Cleanup Plan")
$planLines.Add("Project: $projectName")
$planLines.Add("Region: $region")
$planLines.Add("Environment: $environment")
$planLines.Add("AWS account: $($identity.Account)")
$planLines.Add("AWS ARN: $($identity.Arn)")
$planLines.Add("Mode generated: $Mode")
$planLines.Add($auditSummary)
$planLines.Add("")
$planLines.Add("Safety rules:")
$planLines.Add("- Plan mode is read-only.")
$planLines.Add("- Execute mode re-checks live AWS state before each deletion.")
$planLines.Add("- Audit report IDs are parsed as hints only; live AWS checks decide deletion candidates.")
$planLines.Add("- Only TerraPilot-tagged or TerraPilot-named resources are candidates.")
$planLines.Add("- S3, ECR, EKS, and IAM are manual/high-risk unless separately confirmed.")
$planLines.Add("- AWS service-linked roles are never deleted.")
$planLines.Add("")

if ($auditHints.Count -gt 0) {
  $planLines.Add("Audit report hints parsed:")
  foreach ($hint in $auditHints) {
    $planLines.Add("- $($hint.Type): $($hint.Id) ($($hint.Reason))")
  }
  $planLines.Add("")
}

if ($items.Count -eq 0) {
  $planLines.Add("No TerraPilot cleanup candidates were found by live AWS checks.")
} else {
  $i = 1
  foreach ($item in $items) {
    $planLines.Add("[$i] $($item.Type)")
    $planLines.Add("  Resource: $($item.Id)")
    $planLines.Add("  Region: $($item.Region)")
    $planLines.Add("  Billable: $($item.Billable)")
    $planLines.Add("  Safe automatic delete: $($item.AutoDelete)")
    if ($item.SeparateConfirmation) { $planLines.Add("  Separate confirmation required: $($item.SeparateConfirmation)") }
    $planLines.Add("  Suggested command: $($item.Command)")
    $planLines.Add("  Reason: $($item.Reason)")
    if ($item.Notes) { $planLines.Add("  Notes: $($item.Notes)") }
    $planLines.Add("")
    $i++
  }
}
$planLines | Set-Content -LiteralPath $CleanupPlanPath -Encoding UTF8
Write-Host "Cleanup plan written to:"
Write-Host $CleanupPlanPath

if ($Mode -eq "Plan") {
  Write-Host ""
  Write-Host "Plan mode completed. No resources were deleted."
  exit 0
}

Write-Host ""
Write-Host "WARNING: Execute mode can delete TerraPilot leftovers listed as Safe automatic delete."
Write-Host "The cleanup plan will be displayed now."
Write-Host ""
Get-Content -LiteralPath $CleanupPlanPath | Write-Host
Write-Host ""
$confirmProject = Read-Host "Type the exact project name to continue"
if ($confirmProject -cne $projectName) {
  Write-Host "Cleanup cancelled. Project name did not match."
  exit 0
}
$confirmDelete = Read-Host "Type DELETE TERRAPILOT LEFTOVERS to confirm cleanup"
if ($confirmDelete -cne "DELETE TERRAPILOT LEFTOVERS") {
  Write-Host "Cleanup cancelled. Confirmation phrase did not match."
  exit 0
}

function Test-ResourceStillExists {
  param([object]$Item)
  if (-not $Item.VerifyArgs -or $Item.VerifyArgs.Count -eq 0) { return $false }
  $null = Invoke-AwsJson $Item.VerifyArgs
  return ($LASTEXITCODE -eq 0)
}

function Invoke-Delete {
  param([object]$Item)
  if (-not $Item.DeleteArgs -or $Item.DeleteArgs.Count -eq 0) {
    Write-Host "MANUAL: $($Item.Type) $($Item.Id) requires manual cleanup."
    return
  }
  if (-not $Item.AutoDelete) {
    Write-Host "SKIP: $($Item.Type) $($Item.Id) requires separate confirmation: $($Item.SeparateConfirmation)"
    return
  }
  Write-Host "Re-checking: $($Item.Type) $($Item.Id)"
  $exists = Test-ResourceStillExists $Item
  if (-not $exists) {
    Write-Host "SKIP: $($Item.Id) was not found during live re-check."
    return
  }
  Write-Host "Deleting: $($Item.Command)"
  if ($Item.Type -eq "Internet Gateway") {
    $parts = $Item.Command -split " && "
    foreach ($cmd in $parts) {
      $args = ($cmd -replace "^aws\s+", "") -split "\s+"
      & aws @profileArgs @args 2>&1 | Write-Host
    }
  } else {
    $args = @($Item.DeleteArgs)
    if ($Item.Type -notlike "IAM*") { $args += @("--region", $region) }
    & aws @profileArgs @args 2>&1 | Write-Host
  }
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Delete command failed for $($Item.Type) $($Item.Id). Review the message above."
  } else {
    Write-Host "Delete command completed for $($Item.Type) $($Item.Id). Re-check AWS Console if dependencies are still deleting."
  }
}

$order = @(
  "Load balancer", "Target group", "NAT Gateway", "VPC endpoint", "Network interface", "Elastic IP",
  "Unattached EBS volume", "EBS snapshot", "Internet Gateway", "Route table", "Security group", "Subnet", "VPC",
  "CloudWatch log group", "SSM parameter", "ECR repository", "S3 bucket", "IAM instance profile", "IAM role"
)
foreach ($type in $order) {
  foreach ($item in @($items | Where-Object { $_.Type -eq $type })) {
    Invoke-Delete $item
  }
}

Write-Host ""
$runAudit = Read-Host "Do you want to run post-destroy-audit.bat again to verify cleanup? Type Y or N"
if ($runAudit -match "(?i)^y$" -and (Test-Path -LiteralPath (Join-Path $Root "post-destroy-audit.bat"))) {
  & cmd.exe /c ""$Root\post-destroy-audit.bat""
} else {
  Write-Host "Recommended next step: run post-destroy-audit.bat to verify cleanup."
}
