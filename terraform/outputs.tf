output "project_name" {
  description = "The name of the project"
  value       = var.project_name
}

output "environment" {
  description = "The deployment environment"
  value       = var.environment
}

output "region" {
  description = "The AWS region"
  value       = var.region
}


output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = local.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = local.private_subnet_ids
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.main.id
}

output "public_route_table_id" {
  description = "Public route table ID"
  value       = aws_route_table.public.id
}


output "ec2_connection_notes" {
  description = "Connection notes for EC2"
  value       = "For public SSH/EC2 Instance Connect, EC2 must be in a public subnet with 0.0.0.0/0 route to an Internet Gateway and inbound TCP 22 allowed."
}

output "ec2_key_pair_name" {
  description = "EC2 key pair name used by instances"
  value       = local.ec2_key_name
}

output "created_security_group_ids" {
  description = "Security groups created by TerraPilot"
  value = {
    ec2_consolidated = try(aws_security_group.ec2_consolidated[0].id, null)
  }
}

output "ec2_attached_security_group_ids" {
  description = "Security groups attached to EC2 instances"
  value       = local.ec2_security_group_ids
}

output "ec2_attachment_mode" {
  description = "Security group attachment mode used for EC2"
  value       = var.ec2_security_group_attachment_mode
}

output "ec2_security_group_quota_usage" {
  description = "Security group attachment quota usage per EC2 network interface"
  value = {
    attached_count = local.ec2_security_group_count
    quota          = var.security_group_quota_per_network_interface
    rules_product  = local.ec2_security_group_rules_product
  }
}

output "kubernetes_master_instances" {
  description = "Kubernetes master/control-plane EC2 instances. Run kubernetes-check on these instances."
  value = {
    for key, instance in aws_instance.main : key => {
      id         = instance.id
      private_ip = instance.private_ip
      public_ip  = instance.public_ip
    } if local.ec2_instances_expanded[key].role == "kubernetes-master"
  }
}

output "kubernetes_worker_instances" {
  description = "Kubernetes worker EC2 instances"
  value = {
    for key, instance in aws_instance.main : key => {
      id         = instance.id
      private_ip = instance.private_ip
      public_ip  = instance.public_ip
    } if local.ec2_instances_expanded[key].role == "kubernetes-worker"
  }
}

output "kubernetes_check_target" {
  description = "Where to run the Kubernetes verification command"
  value       = "Run kubernetes-check on the Kubernetes master/control-plane instance."
}

output "bootstrap_bucket_name" {
  description = "S3 bucket containing bootstrap scripts for EC2 user-data"
  value       = aws_s3_bucket.bootstrap.id
}

output "user_data_verification_commands" {
  description = "Commands to verify EC2 user-data/startup script execution"
  value = [
    "cloud-init status --long",
    "sudo tail -n 200 /var/log/cloud-init-output.log",
    "sudo tail -n 200 /var/log/terrapilot-userdata.log",
    "ls -la /opt/terrapilot/status",
    "cat /opt/terrapilot/status/userdata.success",
    "cat /opt/terrapilot/status/userdata.failed",
    "kubernetes-check"
  ]
}

output "user_data_log_locations" {
  description = "Important log and status file locations for startup scripts"
  value = {
    cloud_init_output = "/var/log/cloud-init-output.log"
    terrapilot_log    = "/var/log/terrapilot-userdata.log"
    success_marker    = "/opt/terrapilot/status/userdata.success"
    failure_marker    = "/opt/terrapilot/status/userdata.failed"
    commands_file     = "/opt/terrapilot/COMMANDS.md"
  }
}

output "post_apply_next_steps" {
  description = "What to do after terraform apply"
  value = [
    "Wait 3-10 minutes for EC2 user-data scripts to finish.",
    "SSH into the instance.",
    "Run: cloud-init status --long",
    "Run: sudo tail -n 200 /var/log/terrapilot-userdata.log",
    "Run: kubernetes-check on the Kubernetes master/control-plane instance if Kubernetes scripts were enabled."
  ]
}

output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = local.ecr_repository_url
}

output "ecr_repository_arn" {
  description = "ECR repository ARN"
  value       = local.ecr_repository_arn
}

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions OIDC"
  value       = aws_iam_role.github_actions_oidc.arn
}

output "github_actions_variables" {
  description = "GitHub Actions variables for OIDC and ECR deployment"
  value = {
    AWS_REGION         = var.region
    AWS_ACCOUNT_ID     = data.aws_caller_identity.current.account_id
    AWS_ROLE_TO_ASSUME = aws_iam_role.github_actions_oidc.arn
    ECR_REPOSITORY     = var.ecr_repository_name
    ECR_REGISTRY       = split("/", local.ecr_repository_url)[0]
    GITHUB_REPOSITORY  = var.github_repository
    GITHUB_BRANCH      = var.github_branch
  }
}

output "worker_ec2_role_arn" {
  description = "IAM role ARN for worker EC2 ECR pull access"
  value       = aws_iam_role.worker_ec2_ecr_pull.arn
}

output "worker_instance_profile_name" {
  description = "Instance profile name for worker EC2 ECR pull access"
  value       = aws_iam_instance_profile.worker_ec2_ecr_pull.name
}


output "kubernetes_ingress_nlb_dns_name" {
  description = "DNS name of the optional public Network Load Balancer for ingress-nginx"
  value       = try(aws_lb.ingress_nginx[0].dns_name, null)
}

output "kubernetes_ingress_nlb_zone_id" {
  description = "Route53 hosted zone ID of the optional public Network Load Balancer"
  value       = try(aws_lb.ingress_nginx[0].zone_id, null)
}

output "postgres_backup_bucket_name" {
  description = "S3 bucket used by the PostgreSQL backup CronJob"
  value       = aws_s3_bucket.postgres_backups.id
}

output "postgres_backup_prefix" {
  description = "S3 prefix used by the PostgreSQL backup CronJob"
  value       = var.postgres_backup_prefix
}

output "kubestate_recovery_lab_next_steps" {
  description = "Post-bootstrap commands for the KubeState Recovery Lab application bundle"
  value = [
    "Install the AWS EBS CSI driver, then apply k8s/storage/gp3-storageclass.yaml.",
    "Install ingress-nginx and apply k8s/ingress-nginx/controller-nodeports.yaml.",
    "Install cert-manager and apply k8s/cert-manager/clusterissuer-letsencrypt.yaml after setting letsencrypt_email.",
    "Apply k8s/stateful-app/*.yaml after replacing image and secret placeholders."
  ]
}
