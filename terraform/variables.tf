variable "project_name" {
  description = "Name of the project"
  type        = string
  default     = "DeployWatch"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "ami_source" {
  description = "AMI source: amazon-linux-ssm, ubuntu-ami, debian-ami, rhel-ami, or custom"
  type        = string
  default     = "ubuntu-ami"

  validation {
    condition     = contains(["amazon-linux-ssm", "ubuntu-ami", "debian-ami", "rhel-ami", "custom"], var.ami_source)
    error_message = "ami_source must be amazon-linux-ssm, ubuntu-ami, debian-ami, rhel-ami, or custom."
  }
}

variable "ami_architecture" {
  description = "AMI architecture"
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.ami_architecture)
    error_message = "ami_architecture must be x86_64 or arm64."
  }
}

variable "custom_ami_id" {
  description = "Custom AMI ID to use for EC2 instances"
  type        = string
  default     = ""

  validation {
    condition     = var.custom_ami_id == "" || startswith(var.custom_ami_id, "ami-")
    error_message = "custom_ami_id must be empty or start with ami-."
  }
}

variable "ubuntu_ami_name_pattern" {
  description = "Ubuntu AMI name filter pattern"
  type        = string
  default     = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
}

variable "debian_ami_name_pattern" {
  description = "Debian AMI name filter pattern"
  type        = string
  default     = "debian-12-amd64-daily"
}

variable "rhel_ami_name_pattern" {
  description = "RHEL / CentOS / Rocky AMI name filter pattern"
  type        = string
  default     = "RHEL-9.*-x86_64-Hourly"
}

variable "ami_ssm_parameter_name" {
  description = "SSM parameter name for Amazon Linux AMI"
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

variable "ec2_security_group_attachment_mode" {
  description = "Security group attachment mode for EC2: generated, existing, mixed, default, or none"
  type        = string
  default     = "generated"

  validation {
    condition     = contains(["generated", "existing", "mixed", "default", "none"], var.ec2_security_group_attachment_mode)
    error_message = "ec2_security_group_attachment_mode must be generated, existing, mixed, default, or none."
  }
}

variable "attach_http_security_group_to_ec2" {
  description = "Attach generated HTTP security group to EC2 instances"
  type        = bool
  default     = true
}

variable "attach_https_security_group_to_ec2" {
  description = "Attach generated HTTPS security group to EC2 instances"
  type        = bool
  default     = true
}

variable "attach_ssh_security_group_to_ec2" {
  description = "Attach generated SSH security group to EC2 instances"
  type        = bool
  default     = true
}

variable "security_group_quota_per_network_interface" {
  description = "AWS security group quota per network interface. Default AWS quota is 5 and adjustable up to 16."
  type        = number
  default     = 5

  validation {
    condition     = var.security_group_quota_per_network_interface >= 1 && var.security_group_quota_per_network_interface <= 16
    error_message = "security_group_quota_per_network_interface must be between 1 and 16."
  }
}

variable "existing_security_group_ids" {
  description = "Existing security group IDs to attach to EC2 instances"
  type        = list(string)
  default     = []
}

variable "use_default_security_group_for_ec2" {
  description = "Use the VPC default security group for EC2 instances"
  type        = bool
  default     = false
}

variable "enable_ssh_security_group" {
  description = "Create generated SSH security group"
  type        = bool
  default     = true
}

variable "enable_k8s_api_security_group" {
  description = "Create generated Kubernetes API Server security group"
  type        = bool
  default     = true
}

variable "enable_etcd_security_group" {
  description = "Create generated etcd security group"
  type        = bool
  default     = true
}

variable "enable_kubelet_security_group" {
  description = "Create generated Kubelet API security group"
  type        = bool
  default     = true
}

variable "enable_k8s_scheduler_security_group" {
  description = "Create generated Kube Scheduler security group"
  type        = bool
  default     = true
}

variable "enable_k8s_ctrl_mgr_security_group" {
  description = "Create generated Kube Controller Manager security group"
  type        = bool
  default     = true
}

variable "enable_nodeport_security_group" {
  description = "Create generated NodePort Services security group"
  type        = bool
  default     = true
}

variable "enable_dns_tcp_security_group" {
  description = "Create generated DNS (TCP) security group"
  type        = bool
  default     = true
}

variable "enable_dns_udp_security_group" {
  description = "Create generated DNS (UDP) security group"
  type        = bool
  default     = true
}

variable "enable_http_security_group" {
  description = "Create generated HTTP security group"
  type        = bool
  default     = true
}

variable "enable_https_security_group" {
  description = "Create generated HTTPS security group"
  type        = bool
  default     = true
}

variable "key_pair_mode" {
  description = "EC2 key pair mode: none, existing, or create"
  type        = string
  default     = "existing"

  validation {
    condition     = contains(["none", "existing", "create"], var.key_pair_mode)
    error_message = "key_pair_mode must be one of: none, existing, create."
  }
}

variable "existing_key_pair_name" {
  description = "Existing EC2 key pair name"
  type        = string
  default     = "my-key"
}

variable "key_pair_name" {
  description = "New EC2 key pair name"
  type        = string
  default     = "my-key"
}

variable "public_key" {
  description = "Public SSH key content for creating a new EC2 key pair"
  type        = string
  default     = ""
  sensitive   = true
}

variable "kagent_enabled" {
  description = "Install kagent and create the Bedrock Kubernetes agent on the self-managed control plane"
  type        = bool
  default     = false
}

variable "bedrock_region" {
  description = "AWS Bedrock region for kagent"
  type        = string
  default     = "us-east-1"
}

variable "bedrock_model_id" {
  description = "AWS Bedrock model ID for kagent"
  type        = string
  default     = "amazon.nova-micro-v1:0"
}

variable "kagent_provider" {
  description = "AI provider for kagent (aws_bedrock, openai, anthropic, gemini)"
  type        = string
  default     = "aws_bedrock"
}

variable "kagent_aws_credential_mode" {
  description = "AWS credential mode for kagent Bedrock access (ec2_instance_role or kubernetes_secret)"
  type        = string
  default     = "ec2_instance_role"
}

variable "enable_kagent_bedrock_iam_policy" {
  description = "Attach inline Bedrock invoke permissions for kagent when using EC2 instance role credentials"
  type        = bool
  default     = false
}

variable "model_id" {
  description = "Model ID for non-Bedrock providers"
  type        = string
  default     = "amazon.nova-micro-v1:0"
}

variable "openai_api_key" {
  description = "OpenAI API key"
  type        = string
  sensitive   = true
  default     = ""
}

variable "anthropic_api_key" {
  description = "Anthropic API key"
  type        = string
  sensitive   = true
  default     = ""
}

variable "gemini_api_key" {
  description = "Google Gemini API key"
  type        = string
  sensitive   = true
  default     = ""
}

variable "ollama_endpoint" {
  description = "Ollama API endpoint for kagent"
  type        = string
  default     = "http://localhost:11434"
}

variable "custom_provider_name" {
  description = "Custom kagent provider name"
  type        = string
  default     = "custom"
}

variable "custom_provider_endpoint" {
  description = "Custom kagent provider endpoint"
  type        = string
  default     = ""
}

variable "custom_provider_api_key" {
  description = "Custom kagent provider API key"
  type        = string
  sensitive   = true
  default     = ""
}

variable "ecr_repository_name" {
  description = "ECR repository name"
  type        = string
  default     = "deploywatch"
}

variable "ecr_image_tag_mutability" {
  description = "ECR image tag mutability"
  type        = string
  default     = "IMMUTABLE"
}

variable "ecr_scan_on_push" {
  description = "Whether ECR scans container images after push"
  type        = bool
  default     = false
}

variable "ecr_lifecycle_policy_enabled" {
  description = "Whether to create an ECR lifecycle policy"
  type        = bool
  default     = false
}

variable "github_repository" {
  description = "GitHub repository allowed to assume the generated OIDC role, in OWNER/REPO format"
  type        = string
  default     = "Ayesha-Siddiqa-khan/-DeployWatch"
}

variable "github_branch" {
  description = "GitHub branch allowed to assume the generated OIDC role"
  type        = string
  default     = "main"
}

variable "github_oidc_audience" {
  description = "GitHub Actions OIDC audience for AWS STS"
  type        = string
  default     = "sts.amazonaws.com"
}

variable "github_oidc_thumbprint_list" {
  description = "GitHub Actions OIDC provider thumbprints"
  type        = list(string)
  default     = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a2a8515a675928b3113541ce2307594cbe32", "06d927fecd0a84aeba28aad1d808139470fe95c3"]
}

variable "s3_bucket_name" {
  description = "S3 bucket name for TerraPilot"
  type        = string
  default     = "deploywatch-dev-app-assets-zqjhbvuj"
}

variable "enable_control_plane_s3_access" {
  description = "Attach S3 read/write policy to the control-plane EC2 role"
  type        = bool
  default     = false
}

variable "enable_control_plane_s3_read_only" {
  description = "Attach S3 read-only policy to the control-plane EC2 role"
  type        = bool
  default     = false
}

variable "ec2_instances" {
  description = "List of EC2 instance configurations"
  type = list(object({
    name                = string
    instance_type       = string
    quantity            = number
    subnet_type         = string
    associate_public_ip = bool
    root_volume_size    = number
    root_volume_type    = string
    encrypt_root_volume = bool
    role                = string
  }))
  default = [
    {
      "name" : "c7i-flex-large",
      "instance_type" : "c7i-flex.large",
      "quantity" : 1,
      "subnet_type" : "public",
      "associate_public_ip" : true,
      "root_volume_size" : 20,
      "root_volume_type" : "gp3",
      "encrypt_root_volume" : false,
      "role" : "kubernetes-master"
    },
    {
      "name" : "t3-micro",
      "instance_type" : "t3.micro",
      "quantity" : 1,
      "subnet_type" : "public",
      "associate_public_ip" : true,
      "root_volume_size" : 14,
      "root_volume_type" : "gp3",
      "encrypt_root_volume" : false,
      "role" : "kubernetes-worker"
    }
  ]
}

variable "iam_users" {
  description = "IAM users to create"
  type = list(object({
    username             = string
    console_access       = bool
    programmatic_access  = bool
    force_password_reset = bool
    mfa_recommended      = bool
    groups               = list(string)
    attached_policies    = list(string)
    tags                 = map(string)
  }))
  default = []
}

variable "iam_groups" {
  description = "IAM groups to create"
  type = list(object({
    name              = string
    description       = optional(string)
    attached_policies = list(string)
    users             = list(string)
  }))
  default = []
}

variable "iam_roles" {
  description = "IAM roles to create"
  type = list(object({
    name              = string
    type              = string
    trusted_entity    = string
    attached_policies = list(string)
    inline_policies   = list(string)
    tags              = map(string)
  }))
  default = []
}


variable "enable_kubernetes_ingress_nlb" {
  description = "Create an AWS Network Load Balancer that forwards public HTTP/HTTPS to ingress-nginx NodePorts on self-managed Kubernetes worker nodes"
  type        = bool
  default     = false
}

variable "ingress_http_node_port" {
  description = "Fixed ingress-nginx HTTP NodePort"
  type        = number
  default     = 30080
}

variable "ingress_https_node_port" {
  description = "Fixed ingress-nginx HTTPS NodePort"
  type        = number
  default     = 30443
}

variable "ingress_nodeport_allowed_cidr" {
  description = "CIDR allowed to reach the ingress-nginx NodePort security group through the public NLB path"
  type        = string
  default     = "0.0.0.0/0"
}

variable "create_dns_record" {
  description = "Create an optional Route53 A/alias record for the application hostname"
  type        = bool
  default     = false
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID for optional DNS"
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "Base domain name for documentation and optional DNS"
  type        = string
  default     = ""
}

variable "app_hostname" {
  description = "Application hostname for ingress TLS and optional Route53 alias record"
  type        = string
  default     = "deploywatch.example.com"
}

variable "letsencrypt_email" {
  description = "Email address used by cert-manager ClusterIssuer for Let's Encrypt registration"
  type        = string
  default     = "admin@example.com"
}

variable "postgres_backup_bucket_name" {
  description = "Optional override for the PostgreSQL backup S3 bucket name. Leave empty to generate a project-scoped name."
  type        = string
  default     = ""
}

variable "postgres_backup_prefix" {
  description = "Prefix inside the PostgreSQL backup bucket for pg_dump files"
  type        = string
  default     = "postgres-backups"
}

variable "ebs_csi_driver_policy_arn" {
  description = "AWS managed policy attached to EC2 node roles for the self-managed Kubernetes EBS CSI driver"
  type        = string
  default     = "arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicyV2"
}
