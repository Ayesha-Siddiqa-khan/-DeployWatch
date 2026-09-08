# KubeState Recovery Lab additions for self-managed Kubernetes on EC2.
# Worker EC2 instances are targeted by the NLB.

locals {
  postgres_backup_bucket_name = var.postgres_backup_bucket_name != "" ? var.postgres_backup_bucket_name : substr(lower(replace("${var.project_name}-${var.environment}-postgres-backups-${random_id.suffix.hex}", "_", "-")), 0, 63)
}

resource "aws_security_group" "ingress_nginx_nodeports" {
  count       = var.enable_kubernetes_ingress_nlb ? 1 : 0
  name        = substr("${local.resource_prefix}-ingress-nodeports", 0, 255)
  description = "Allow AWS NLB traffic to ingress-nginx fixed NodePorts"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP to ingress-nginx NodePort"
    from_port   = var.ingress_http_node_port
    to_port     = var.ingress_http_node_port
    protocol    = "tcp"
    cidr_blocks = [var.ingress_nodeport_allowed_cidr]
  }

  ingress {
    description = "HTTPS to ingress-nginx NodePort"
    from_port   = var.ingress_https_node_port
    to_port     = var.ingress_https_node_port
    protocol    = "tcp"
    cidr_blocks = [var.ingress_nodeport_allowed_cidr]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                   = "${local.resource_prefix}-ingress-nodeports"
    Project                = var.project_name
    TerraPilotProject      = var.project_name
    TerraPilotResourceType = "kubernetes-ingress-nodeport-security-group"
    Environment            = var.environment
    ManagedBy              = "TerraPilot"
    CostSensitive          = "false"
  }
}

resource "aws_network_interface_sg_attachment" "ingress_nginx_nodeports" {
  for_each = var.enable_kubernetes_ingress_nlb ? {
    for key, instance in aws_instance.main : key => instance.primary_network_interface_id
    if local.ec2_instances_expanded[key].role == "kubernetes-worker"
  } : {}
  security_group_id    = aws_security_group.ingress_nginx_nodeports[0].id
  network_interface_id = each.value
}

resource "aws_lb" "ingress_nginx" {
  count              = var.enable_kubernetes_ingress_nlb ? 1 : 0
  name               = substr("${local.resource_prefix}-ingress-nlb", 0, 32)
  internal           = false
  load_balancer_type = "network"
  subnets            = local.public_subnet_ids

  tags = {
    Name                   = "${local.resource_prefix}-ingress-nlb"
    Project                = var.project_name
    TerraPilotProject      = var.project_name
    TerraPilotResourceType = "network-load-balancer"
    Environment            = var.environment
    ManagedBy              = "TerraPilot"
    CostSensitive          = "true"
  }

  lifecycle {
    precondition {
      condition     = length(local.public_subnet_ids) > 0
      error_message = "enable_kubernetes_ingress_nlb requires public subnets. Enable public internet access / load balancer networking in the wizard."
    }
  }
}

resource "aws_lb_target_group" "ingress_http" {
  count       = var.enable_kubernetes_ingress_nlb ? 1 : 0
  name        = substr("${local.resource_prefix}-http-30080", 0, 32)
  port        = var.ingress_http_node_port
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }
}

resource "aws_lb_target_group" "ingress_https" {
  count       = var.enable_kubernetes_ingress_nlb ? 1 : 0
  name        = substr("${local.resource_prefix}-https-30443", 0, 32)
  port        = var.ingress_https_node_port
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }
}

resource "aws_lb_listener" "ingress_http" {
  count             = var.enable_kubernetes_ingress_nlb ? 1 : 0
  load_balancer_arn = aws_lb.ingress_nginx[0].arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress_http[0].arn
  }
}

resource "aws_lb_listener" "ingress_https" {
  count             = var.enable_kubernetes_ingress_nlb ? 1 : 0
  load_balancer_arn = aws_lb.ingress_nginx[0].arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress_https[0].arn
  }
}

resource "aws_lb_target_group_attachment" "ingress_http_workers" {
  for_each = var.enable_kubernetes_ingress_nlb ? {
    for key, instance in aws_instance.main : key => instance
    if local.ec2_instances_expanded[key].role == "kubernetes-worker"
  } : {}
  target_group_arn = aws_lb_target_group.ingress_http[0].arn
  target_id        = each.value.id
  port             = var.ingress_http_node_port
}

resource "aws_lb_target_group_attachment" "ingress_https_workers" {
  for_each = var.enable_kubernetes_ingress_nlb ? {
    for key, instance in aws_instance.main : key => instance
    if local.ec2_instances_expanded[key].role == "kubernetes-worker"
  } : {}
  target_group_arn = aws_lb_target_group.ingress_https[0].arn
  target_id        = each.value.id
  port             = var.ingress_https_node_port
}

resource "aws_route53_record" "app_alias" {
  count   = var.enable_kubernetes_ingress_nlb && var.create_dns_record && var.hosted_zone_id != "" && var.app_hostname != "" ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.app_hostname
  type    = "A"

  alias {
    name                   = aws_lb.ingress_nginx[0].dns_name
    zone_id                = aws_lb.ingress_nginx[0].zone_id
    evaluate_target_health = true
  }
}

resource "aws_s3_bucket" "postgres_backups" {
  bucket        = local.postgres_backup_bucket_name
  force_destroy = false

  tags = {
    Name                   = local.postgres_backup_bucket_name
    Project                = var.project_name
    TerraPilotProject      = var.project_name
    TerraPilotResourceType = "postgres-backup-bucket"
    Environment            = var.environment
    ManagedBy              = "TerraPilot"
    CostSensitive          = "true"
  }
}

resource "aws_s3_bucket_versioning" "postgres_backups" {
  bucket = aws_s3_bucket.postgres_backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "postgres_backups" {
  bucket = aws_s3_bucket.postgres_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "postgres_backups" {
  bucket                  = aws_s3_bucket.postgres_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "postgres_backups" {
  bucket = aws_s3_bucket.postgres_backups.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_iam_policy" "postgres_backup_s3_access" {
  name        = "${local.resource_prefix}-postgres-backup-s3-access"
  description = "Allow PostgreSQL backup and restore access to the generated S3 bucket prefix only."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListPostgresBackupPrefix"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.postgres_backup_bucket_name}"
        Condition = {
          StringLike = {
            "s3:prefix" = ["${var.postgres_backup_prefix}/*"]
          }
        }
      },
      {
        Sid    = "ReadWritePostgresBackupObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "arn:aws:s3:::${local.postgres_backup_bucket_name}/${var.postgres_backup_prefix}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "terrapilot_postgres_backup_s3_access" {
  role       = aws_iam_role.terrapilot_ec2_userdata.name
  policy_arn = aws_iam_policy.postgres_backup_s3_access.arn
}

resource "aws_iam_role_policy_attachment" "terrapilot_ebs_csi_driver" {
  role       = aws_iam_role.terrapilot_ec2_userdata.name
  policy_arn = var.ebs_csi_driver_policy_arn
}

resource "aws_iam_role_policy_attachment" "worker_ec2_postgres_backup_s3_access" {
  role       = aws_iam_role.worker_ec2_ecr_pull.name
  policy_arn = aws_iam_policy.postgres_backup_s3_access.arn
}

resource "aws_iam_role_policy_attachment" "worker_ec2_ebs_csi_driver" {
  role       = aws_iam_role.worker_ec2_ecr_pull.name
  policy_arn = var.ebs_csi_driver_policy_arn
}

