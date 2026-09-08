
# Bootstrap S3 bucket for EC2 user-data scripts
resource "aws_s3_bucket" "bootstrap" {
  bucket        = lower("${local.resource_prefix}-bootstrap-${random_id.suffix.hex}")
  force_destroy = true

  tags = {
    Name      = "${local.resource_prefix}-bootstrap"
    ManagedBy = "TerraPilot"
    Purpose   = "EC2 user-data bootstrap artifacts"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bootstrap" {
  bucket = aws_s3_bucket.bootstrap.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "bootstrap" {
  bucket = aws_s3_bucket.bootstrap.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


# Bootstrap S3 objects for EC2 user-data scripts

resource "aws_s3_object" "bootstrap_kubernetes_master_base_packages" {
  bucket  = aws_s3_bucket.bootstrap.id
  key     = "scripts/kubernetes-master/base-packages.sh"
  content = <<-EOT
#!/bin/bash
echo "[TerraPilot][base] Installing common packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl unzip git jq gnupg lsb-release apt-transport-https
# Post-install verification
for CMD in curl wget unzip git; do
  if command -v "$CMD" >/dev/null 2>&1; then
    echo "[TerraPilot][base] [OK] $CMD installed"
  else
    echo "[TerraPilot][base] [WARN] $CMD not found after install"
  fi
done
echo "[TerraPilot][base] Base packages installed"

EOT
  etag = md5(<<-EOT
#!/bin/bash
echo "[TerraPilot][base] Installing common packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl unzip git jq gnupg lsb-release apt-transport-https
# Post-install verification
for CMD in curl wget unzip git; do
  if command -v "$CMD" >/dev/null 2>&1; then
    echo "[TerraPilot][base] [OK] $CMD installed"
  else
    echo "[TerraPilot][base] [WARN] $CMD not found after install"
  fi
done
echo "[TerraPilot][base] Base packages installed"

EOT
  )
}

resource "aws_s3_object" "bootstrap_kubernetes_master_install_kubectl_cli" {
  bucket  = aws_s3_bucket.bootstrap.id
  key     = "scripts/kubernetes-master/install-kubectl-cli.sh"
  content = <<-EOT
#!/bin/bash
set -euo pipefail
echo "[TerraPilot][kubectl] Installing kubectl"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubectl
kubectl version --client=true
echo "[TerraPilot][kubectl] kubectl setup complete"

EOT
  etag = md5(<<-EOT
#!/bin/bash
set -euo pipefail
echo "[TerraPilot][kubectl] Installing kubectl"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubectl
kubectl version --client=true
echo "[TerraPilot][kubectl] kubectl setup complete"

EOT
  )
}

resource "aws_s3_object" "bootstrap_kubernetes_master_install_helm" {
  bucket  = aws_s3_bucket.bootstrap.id
  key     = "scripts/kubernetes-master/install-helm.sh"
  content = <<-EOT
#!/bin/bash
set -euo pipefail
log() {
  echo "[TerraPilot][helm][$(date -Is)] $*"
}
if command -v helm >/dev/null 2>&1; then
  log "Helm already installed: $(helm version --short 2>/dev/null || true)"
  exit 0
fi
log "Installing Helm 3 via official installer."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
log "Helm installation complete: $(helm version --short 2>/dev/null || true)"

EOT
  etag = md5(<<-EOT
#!/bin/bash
set -euo pipefail
log() {
  echo "[TerraPilot][helm][$(date -Is)] $*"
}
if command -v helm >/dev/null 2>&1; then
  log "Helm already installed: $(helm version --short 2>/dev/null || true)"
  exit 0
fi
log "Installing Helm 3 via official installer."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
log "Helm installation complete: $(helm version --short 2>/dev/null || true)"

EOT
  )
}

resource "aws_s3_object" "bootstrap_kubernetes_master_install_nginx" {
  bucket  = aws_s3_bucket.bootstrap.id
  key     = "scripts/kubernetes-master/install-nginx.sh"
  content = <<-EOT
#!/bin/bash
set -euo pipefail
echo "[TerraPilot][nginx] Installing Nginx"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx
systemctl enable nginx
systemctl start nginx
echo "TerraPilot Nginx setup complete" > /var/www/html/index.html
# Post-install verification
if command -v nginx >/dev/null 2>&1; then
  nginx -v 2>&1
  echo "[TerraPilot][nginx] [OK] nginx installed"
else
  echo "[TerraPilot][nginx] [WARN] nginx command not found after install"
  exit 1
fi
echo "[TerraPilot][nginx] Nginx setup complete"

EOT
  etag = md5(<<-EOT
#!/bin/bash
set -euo pipefail
echo "[TerraPilot][nginx] Installing Nginx"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx
systemctl enable nginx
systemctl start nginx
echo "TerraPilot Nginx setup complete" > /var/www/html/index.html
# Post-install verification
if command -v nginx >/dev/null 2>&1; then
  nginx -v 2>&1
  echo "[TerraPilot][nginx] [OK] nginx installed"
else
  echo "[TerraPilot][nginx] [WARN] nginx command not found after install"
  exit 1
fi
echo "[TerraPilot][nginx] Nginx setup complete"

EOT
  )
}

resource "aws_s3_object" "bootstrap_kubernetes_master_user_data" {
  bucket = aws_s3_bucket.bootstrap.id
  key    = "scripts/kubernetes-master/kubernetes-master-user-data.sh"
  content = templatefile("${path.module}/scripts/master-user-data.sh", {
    project_name               = var.project_name
    environment                = var.environment
    region                     = var.region
    instance_name              = ""
    instance_role              = "kubernetes-master"
    aws_region                 = var.region
    ssm_join_private_path      = local.terrapilot_ssm_join_private_path
    ssm_join_public_path       = local.terrapilot_ssm_join_public_path
    ssm_auto_join_enabled      = local.terrapilot_ssm_auto_join_enabled
    kagent_enabled             = var.kagent_enabled
    kagent_provider            = var.kagent_provider
    kagent_aws_credential_mode = var.kagent_aws_credential_mode
    bedrock_region             = var.bedrock_region
    bedrock_model_id           = var.bedrock_model_id
    model_id                   = var.model_id
    openai_api_key             = var.openai_api_key
    anthropic_api_key          = var.anthropic_api_key
    gemini_api_key             = var.gemini_api_key
    ollama_endpoint            = var.ollama_endpoint
    custom_provider_name       = var.custom_provider_name
    custom_provider_endpoint   = var.custom_provider_endpoint
    custom_provider_api_key    = var.custom_provider_api_key
    bootstrap_bucket           = aws_s3_bucket.bootstrap.id
  })
  etag = md5(file("${path.module}/scripts/master-user-data.sh"))
}

resource "aws_s3_object" "bootstrap_kubernetes_worker_base_packages" {
  bucket  = aws_s3_bucket.bootstrap.id
  key     = "scripts/kubernetes-worker/base-packages.sh"
  content = <<-EOT
#!/bin/bash
echo "[TerraPilot][base] Installing common packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl unzip git jq gnupg lsb-release apt-transport-https
# Post-install verification
for CMD in curl wget unzip git; do
  if command -v "$CMD" >/dev/null 2>&1; then
    echo "[TerraPilot][base] [OK] $CMD installed"
  else
    echo "[TerraPilot][base] [WARN] $CMD not found after install"
  fi
done
echo "[TerraPilot][base] Base packages installed"

EOT
  etag = md5(<<-EOT
#!/bin/bash
echo "[TerraPilot][base] Installing common packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl unzip git jq gnupg lsb-release apt-transport-https
# Post-install verification
for CMD in curl wget unzip git; do
  if command -v "$CMD" >/dev/null 2>&1; then
    echo "[TerraPilot][base] [OK] $CMD installed"
  else
    echo "[TerraPilot][base] [WARN] $CMD not found after install"
  fi
done
echo "[TerraPilot][base] Base packages installed"

EOT
  )
}

resource "aws_s3_object" "bootstrap_kubernetes_worker_install_kubectl_cli" {
  bucket  = aws_s3_bucket.bootstrap.id
  key     = "scripts/kubernetes-worker/install-kubectl-cli.sh"
  content = <<-EOT
#!/bin/bash
set -euo pipefail
echo "[TerraPilot][kubectl] Installing kubectl"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubectl
kubectl version --client=true
echo "[TerraPilot][kubectl] kubectl setup complete"

EOT
  etag = md5(<<-EOT
#!/bin/bash
set -euo pipefail
echo "[TerraPilot][kubectl] Installing kubectl"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubectl
kubectl version --client=true
echo "[TerraPilot][kubectl] kubectl setup complete"

EOT
  )
}

resource "aws_s3_object" "bootstrap_kubernetes_worker_install_nginx" {
  bucket  = aws_s3_bucket.bootstrap.id
  key     = "scripts/kubernetes-worker/install-nginx.sh"
  content = <<-EOT
#!/bin/bash
set -euo pipefail
echo "[TerraPilot][nginx] Installing Nginx"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx
systemctl enable nginx
systemctl start nginx
echo "TerraPilot Nginx setup complete" > /var/www/html/index.html
# Post-install verification
if command -v nginx >/dev/null 2>&1; then
  nginx -v 2>&1
  echo "[TerraPilot][nginx] [OK] nginx installed"
else
  echo "[TerraPilot][nginx] [WARN] nginx command not found after install"
  exit 1
fi
echo "[TerraPilot][nginx] Nginx setup complete"

EOT
  etag = md5(<<-EOT
#!/bin/bash
set -euo pipefail
echo "[TerraPilot][nginx] Installing Nginx"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx
systemctl enable nginx
systemctl start nginx
echo "TerraPilot Nginx setup complete" > /var/www/html/index.html
# Post-install verification
if command -v nginx >/dev/null 2>&1; then
  nginx -v 2>&1
  echo "[TerraPilot][nginx] [OK] nginx installed"
else
  echo "[TerraPilot][nginx] [WARN] nginx command not found after install"
  exit 1
fi
echo "[TerraPilot][nginx] Nginx setup complete"

EOT
  )
}

resource "aws_s3_object" "bootstrap_kubernetes_worker_user_data" {
  bucket = aws_s3_bucket.bootstrap.id
  key    = "scripts/kubernetes-worker/kubernetes-worker-user-data.sh"
  content = templatefile("${path.module}/scripts/worker-user-data.sh", {
    project_name               = var.project_name
    environment                = var.environment
    region                     = var.region
    instance_name              = ""
    instance_role              = "kubernetes-worker"
    aws_region                 = var.region
    ssm_join_private_path      = local.terrapilot_ssm_join_private_path
    ssm_join_public_path       = local.terrapilot_ssm_join_public_path
    ssm_auto_join_enabled      = local.terrapilot_ssm_auto_join_enabled
    kagent_enabled             = var.kagent_enabled
    kagent_provider            = var.kagent_provider
    kagent_aws_credential_mode = var.kagent_aws_credential_mode
    bedrock_region             = var.bedrock_region
    bedrock_model_id           = var.bedrock_model_id
    model_id                   = var.model_id
    openai_api_key             = var.openai_api_key
    anthropic_api_key          = var.anthropic_api_key
    gemini_api_key             = var.gemini_api_key
    ollama_endpoint            = var.ollama_endpoint
    custom_provider_name       = var.custom_provider_name
    custom_provider_endpoint   = var.custom_provider_endpoint
    custom_provider_api_key    = var.custom_provider_api_key
    bootstrap_bucket           = aws_s3_bucket.bootstrap.id
  })
  etag = md5(file("${path.module}/scripts/worker-user-data.sh"))
}

resource "aws_s3_object" "bootstrap_common_setup" {
  bucket = aws_s3_bucket.bootstrap.id
  key    = "scripts/common-setup.sh"
  content = templatefile("${path.module}/scripts/common-setup.sh", {
    project_name               = var.project_name
    environment                = var.environment
    region                     = var.region
    instance_name              = ""
    instance_role              = "web"
    aws_region                 = var.region
    ssm_join_private_path      = local.terrapilot_ssm_join_private_path
    ssm_join_public_path       = local.terrapilot_ssm_join_public_path
    ssm_auto_join_enabled      = local.terrapilot_ssm_auto_join_enabled
    kagent_enabled             = var.kagent_enabled
    kagent_provider            = var.kagent_provider
    kagent_aws_credential_mode = var.kagent_aws_credential_mode
    bedrock_region             = var.bedrock_region
    bedrock_model_id           = var.bedrock_model_id
    model_id                   = var.model_id
    openai_api_key             = var.openai_api_key
    anthropic_api_key          = var.anthropic_api_key
    gemini_api_key             = var.gemini_api_key
    ollama_endpoint            = var.ollama_endpoint
    custom_provider_name       = var.custom_provider_name
    custom_provider_endpoint   = var.custom_provider_endpoint
    custom_provider_api_key    = var.custom_provider_api_key
    bootstrap_bucket           = aws_s3_bucket.bootstrap.id
  })
  etag = md5(file("${path.module}/scripts/common-setup.sh"))
}

resource "aws_s3_object" "bootstrap_verify_packages" {
  bucket  = aws_s3_bucket.bootstrap.id
  key     = "scripts/verify-bootstrap-packages.sh"
  content = file("${path.module}/scripts/verify-bootstrap-packages.sh")
  etag    = md5(file("${path.module}/scripts/verify-bootstrap-packages.sh"))
}

resource "aws_s3_object" "bootstrap_plan" {
  bucket  = aws_s3_bucket.bootstrap.id
  key     = "scripts/bootstrap-plan.json"
  content = <<-EOT
{
  "project": "DeployWatch",
  "environment": "dev",
  "delivery_mode": "inline",
  "roles": {
    "kubernetes-master": {
      "selected_scripts": [
        "scripts/kubernetes-master/base-packages.sh",
        "scripts/kubernetes-master/install-helm.sh",
        "scripts/kubernetes-master/install-kubectl-cli.sh",
        "scripts/kubernetes-master/install-nginx.sh",
        "scripts/common-setup.sh",
        "scripts/kubernetes-master/kubernetes-master-user-data.sh",
        "scripts/verify-bootstrap-packages.sh"
      ],
      "optional_scripts": [],
      "optional_s3_scripts": [],
      "script_policies": {}
    },
    "kubernetes-worker": {
      "selected_scripts": [
        "scripts/kubernetes-worker/base-packages.sh",
        "scripts/kubernetes-worker/install-kubectl-cli.sh",
        "scripts/kubernetes-worker/install-nginx.sh",
        "scripts/common-setup.sh",
        "scripts/kubernetes-worker/kubernetes-worker-user-data.sh",
        "scripts/verify-bootstrap-packages.sh"
      ],
      "optional_scripts": [],
      "optional_s3_scripts": [],
      "script_policies": {}
    }
  }
}
EOT
  etag = md5(<<-EOT
{
  "project": "DeployWatch",
  "environment": "dev",
  "delivery_mode": "inline",
  "roles": {
    "kubernetes-master": {
      "selected_scripts": [
        "scripts/kubernetes-master/base-packages.sh",
        "scripts/kubernetes-master/install-helm.sh",
        "scripts/kubernetes-master/install-kubectl-cli.sh",
        "scripts/kubernetes-master/install-nginx.sh",
        "scripts/common-setup.sh",
        "scripts/kubernetes-master/kubernetes-master-user-data.sh",
        "scripts/verify-bootstrap-packages.sh"
      ],
      "optional_scripts": [],
      "optional_s3_scripts": [],
      "script_policies": {}
    },
    "kubernetes-worker": {
      "selected_scripts": [
        "scripts/kubernetes-worker/base-packages.sh",
        "scripts/kubernetes-worker/install-kubectl-cli.sh",
        "scripts/kubernetes-worker/install-nginx.sh",
        "scripts/common-setup.sh",
        "scripts/kubernetes-worker/kubernetes-worker-user-data.sh",
        "scripts/verify-bootstrap-packages.sh"
      ],
      "optional_scripts": [],
      "optional_s3_scripts": [],
      "script_policies": {}
    }
  }
}
EOT
  )
}

# EC2 Instances (Multiple)

data "aws_key_pair" "existing" {
  key_name = var.existing_key_pair_name
}

locals {
  ec2_key_name = data.aws_key_pair.existing.key_name
}


locals {
  terrapilot_ssm_join_private_path = "/terrapilot/${var.project_name}/${var.environment}/kubernetes/join-command/private"
  terrapilot_ssm_join_public_path  = "/terrapilot/${var.project_name}/${var.environment}/kubernetes/join-command/public"
  terrapilot_ssm_auto_join_enabled = true
}


resource "aws_iam_role" "terrapilot_ec2_userdata" {
  name = "${local.resource_prefix}-ec2-userdata-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "TerraPilot"
  }
}

resource "aws_iam_policy" "terrapilot_worker_join_ssm" {
  name        = "${local.resource_prefix}-worker-join-ssm"
  description = "Allow EC2 user-data scripts to exchange kubeadm worker join commands through SSM Parameter Store."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:AddTagsToResource",
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:*:*:parameter/terrapilot/${var.project_name}/${var.environment}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "terrapilot_worker_join_ssm" {
  role       = aws_iam_role.terrapilot_ec2_userdata.name
  policy_arn = aws_iam_policy.terrapilot_worker_join_ssm.arn
}

resource "aws_iam_role_policy_attachment" "terrapilot_ssm_managed_instance" {
  role       = aws_iam_role.terrapilot_ec2_userdata.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}




resource "aws_iam_policy" "terrapilot_bootstrap_s3_access" {
  name        = "${local.resource_prefix}-bootstrap-s3-access"
  description = "Allow EC2 instances to download bootstrap scripts from the S3 bootstrap bucket."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowListBootstrapBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = "arn:aws:s3:::${local.resource_prefix}-*"
      },
      {
        Sid    = "AllowGetBootstrapObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "arn:aws:s3:::${local.resource_prefix}-*/scripts/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "terrapilot_bootstrap_s3_access" {
  role       = aws_iam_role.terrapilot_ec2_userdata.name
  policy_arn = aws_iam_policy.terrapilot_bootstrap_s3_access.arn
}



resource "aws_iam_instance_profile" "terrapilot_ec2_userdata" {
  name = "${local.resource_prefix}-ec2-userdata-profile"
  role = aws_iam_role.terrapilot_ec2_userdata.name
}

locals {
  ec2_instance_base_names = [for item in var.ec2_instances : item.name]
  ec2_duplicate_names = toset([
    for name in local.ec2_instance_base_names : name
    if length([for candidate in local.ec2_instance_base_names : candidate if candidate == name]) > 1
  ])

  ec2_instances_expanded = {
    for inst in flatten([
      for item_index, item in var.ec2_instances : [
        for idx in range(item.quantity) : {
          key                 = contains(local.ec2_duplicate_names, item.name) ? "${item.name}-${item_index + 1}-${idx + 1}" : "${item.name}-${idx + 1}"
          name                = contains(local.ec2_duplicate_names, item.name) ? "${item.name}-${item_index + 1}-${idx + 1}" : "${item.name}-${idx + 1}"
          base_name           = item.name
          instance_type       = item.instance_type
          subnet_type         = item.subnet_type
          associate_public_ip = item.associate_public_ip
          root_volume_size    = item.root_volume_size
          root_volume_type    = item.root_volume_type
          encrypt_root_volume = item.encrypt_root_volume
          role                = item.role
        }
      ]
    ]) : inst.key => inst
  }
}

resource "aws_instance" "main" {
  for_each = local.ec2_instances_expanded

  ami           = data.aws_ami.ubuntu.id
  instance_type = each.value.instance_type

  subnet_id = each.value.subnet_type == "public" ? local.public_subnet_ids[0] : local.private_subnet_ids[0]

  associate_public_ip_address = each.value.associate_public_ip
  vpc_security_group_ids      = local.ec2_security_group_ids
  key_name                    = local.ec2_key_name
  user_data_base64 = each.value.role == "kubernetes-master" ? base64gzip(templatefile("${path.module}/scripts/bootstrap-user-data.sh", {
    project_name               = var.project_name
    environment                = var.environment
    region                     = var.region
    instance_name              = each.value.base_name
    instance_role              = "kubernetes-master"
    aws_region                 = var.region
    ssm_join_private_path      = local.terrapilot_ssm_join_private_path
    ssm_join_public_path       = local.terrapilot_ssm_join_public_path
    ssm_auto_join_enabled      = local.terrapilot_ssm_auto_join_enabled
    kagent_enabled             = var.kagent_enabled
    kagent_provider            = var.kagent_provider
    kagent_aws_credential_mode = var.kagent_aws_credential_mode
    bedrock_region             = var.bedrock_region
    bedrock_model_id           = var.bedrock_model_id
    model_id                   = var.model_id
    openai_api_key             = var.openai_api_key
    anthropic_api_key          = var.anthropic_api_key
    gemini_api_key             = var.gemini_api_key
    ollama_endpoint            = var.ollama_endpoint
    custom_provider_name       = var.custom_provider_name
    custom_provider_endpoint   = var.custom_provider_endpoint
    custom_provider_api_key    = var.custom_provider_api_key
    bootstrap_bucket           = aws_s3_bucket.bootstrap.id
    })) : each.value.role == "kubernetes-worker" ? base64gzip(templatefile("${path.module}/scripts/bootstrap-user-data.sh", {
    project_name               = var.project_name
    environment                = var.environment
    region                     = var.region
    instance_name              = each.value.base_name
    instance_role              = "kubernetes-worker"
    aws_region                 = var.region
    ssm_join_private_path      = local.terrapilot_ssm_join_private_path
    ssm_join_public_path       = local.terrapilot_ssm_join_public_path
    ssm_auto_join_enabled      = local.terrapilot_ssm_auto_join_enabled
    kagent_enabled             = var.kagent_enabled
    kagent_provider            = var.kagent_provider
    kagent_aws_credential_mode = var.kagent_aws_credential_mode
    bedrock_region             = var.bedrock_region
    bedrock_model_id           = var.bedrock_model_id
    model_id                   = var.model_id
    openai_api_key             = var.openai_api_key
    anthropic_api_key          = var.anthropic_api_key
    gemini_api_key             = var.gemini_api_key
    ollama_endpoint            = var.ollama_endpoint
    custom_provider_name       = var.custom_provider_name
    custom_provider_endpoint   = var.custom_provider_endpoint
    custom_provider_api_key    = var.custom_provider_api_key
    bootstrap_bucket           = aws_s3_bucket.bootstrap.id
    })) : base64gzip(templatefile("${path.module}/scripts/bootstrap-user-data.sh", {
    project_name               = var.project_name
    environment                = var.environment
    region                     = var.region
    instance_name              = each.value.base_name
    instance_role              = "kubernetes-master"
    aws_region                 = var.region
    ssm_join_private_path      = local.terrapilot_ssm_join_private_path
    ssm_join_public_path       = local.terrapilot_ssm_join_public_path
    ssm_auto_join_enabled      = local.terrapilot_ssm_auto_join_enabled
    kagent_enabled             = var.kagent_enabled
    kagent_provider            = var.kagent_provider
    kagent_aws_credential_mode = var.kagent_aws_credential_mode
    bedrock_region             = var.bedrock_region
    bedrock_model_id           = var.bedrock_model_id
    model_id                   = var.model_id
    openai_api_key             = var.openai_api_key
    anthropic_api_key          = var.anthropic_api_key
    gemini_api_key             = var.gemini_api_key
    ollama_endpoint            = var.ollama_endpoint
    custom_provider_name       = var.custom_provider_name
    custom_provider_endpoint   = var.custom_provider_endpoint
    custom_provider_api_key    = var.custom_provider_api_key
    bootstrap_bucket           = aws_s3_bucket.bootstrap.id
  }))

  user_data_replace_on_change = true

  iam_instance_profile = each.value.role == "kubernetes-worker" ? aws_iam_instance_profile.worker_ec2_ecr_pull.name : aws_iam_instance_profile.terrapilot_ec2_userdata.name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size           = each.value.root_volume_size
    volume_type           = each.value.root_volume_type
    encrypted             = each.value.encrypt_root_volume
    delete_on_termination = true
  }

  tags = {
    Name                   = each.value.name
    Role                   = each.value.role
    Project                = var.project_name
    TerraPilotProject      = var.project_name
    TerraPilotResourceType = "ec2-instance"
    Environment            = var.environment
    ManagedBy              = "TerraPilot"
    CostSensitive          = "true"
  }

  depends_on = [
    aws_s3_object.bootstrap_kubernetes_master_base_packages,
    aws_s3_object.bootstrap_kubernetes_master_install_kubectl_cli,
    aws_s3_object.bootstrap_kubernetes_master_install_helm,
    aws_s3_object.bootstrap_kubernetes_master_install_nginx,
    aws_s3_object.bootstrap_kubernetes_master_user_data,
    aws_s3_object.bootstrap_kubernetes_worker_base_packages,
    aws_s3_object.bootstrap_kubernetes_worker_install_kubectl_cli,
    aws_s3_object.bootstrap_kubernetes_worker_install_nginx,
    aws_s3_object.bootstrap_kubernetes_worker_user_data,
    aws_s3_object.bootstrap_common_setup,
    aws_s3_object.bootstrap_verify_packages,
    aws_s3_object.bootstrap_plan,
    aws_iam_instance_profile.terrapilot_ec2_userdata,
    aws_iam_role_policy_attachment.terrapilot_bootstrap_s3_access,
    aws_iam_role_policy_attachment.terrapilot_worker_join_ssm,
    aws_iam_role_policy_attachment.terrapilot_ssm_managed_instance,
    aws_iam_instance_profile.worker_ec2_ecr_pull,
    aws_iam_role_policy_attachment.worker_ec2_ecr_pull,
    aws_iam_role_policy_attachment.worker_ec2_bootstrap_s3_access,
    aws_iam_role_policy_attachment.worker_ec2_join_ssm,
    aws_iam_role_policy_attachment.worker_ec2_ssm_managed_instance,
    aws_iam_role_policy_attachment.terrapilot_ec2_ecr_pull,
  ]

  lifecycle {
    precondition {
      condition     = local.ec2_security_group_count <= var.security_group_quota_per_network_interface
      error_message = "EC2 security group attachment count exceeds the configured AWS quota per network interface."
    }

    precondition {
      condition     = local.ec2_security_group_rules_product <= 1000
      error_message = "EC2 security group count multiplied by selected generated security group rules exceeds AWS quota guidance."
    }
  }
}

