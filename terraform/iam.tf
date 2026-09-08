# IAM / Access Management

# Generated CI/CD role: GitHub Actions OIDC to push Docker images to ECR.
resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = [var.github_oidc_audience]
  thumbprint_list = var.github_oidc_thumbprint_list
}

resource "aws_iam_role" "github_actions_oidc" {
  name        = "${local.resource_prefix}-github-actions-oidc"
  description = "GitHub Actions OIDC role for pushing Docker images to the selected ECR repository."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = var.github_oidc_audience
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:ref:refs/heads/${var.github_branch}"
          }
        }
      }
    ]
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "TerraPilot"
    Purpose     = "github-actions-oidc-ecr-push"
  }
}

resource "aws_iam_policy" "github_actions_ecr_push" {
  name        = "${local.resource_prefix}-github-actions-ecr-push"
  description = "Least-privilege ECR image push permissions for the GitHub Actions OIDC role."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowEcrAuthorization"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid      = "AllowPushToSelectedRepository"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = local.ecr_repository_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_ecr_push" {
  role       = aws_iam_role.github_actions_oidc.name
  policy_arn = aws_iam_policy.github_actions_ecr_push.arn
}


# Generated worker role: EC2 worker nodes pull Docker images from ECR.
resource "aws_iam_role" "worker_ec2_ecr_pull" {
  name        = "${local.resource_prefix}-worker-ec2-ecr-pull"
  description = "Worker EC2 role for pulling Docker images from the selected ECR repository."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "TerraPilot"
    Purpose     = "worker-ec2-ecr-pull"
  }
}

resource "aws_iam_policy" "worker_ec2_ecr_pull" {
  name        = "${local.resource_prefix}-worker-ec2-ecr-pull"
  description = "Least-privilege ECR image pull permissions for worker EC2 instances."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowEcrAuthorization"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid      = "AllowPullFromSelectedRepository"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = local.ecr_repository_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "worker_ec2_ecr_pull" {
  role       = aws_iam_role.worker_ec2_ecr_pull.name
  policy_arn = aws_iam_policy.worker_ec2_ecr_pull.arn
}

resource "aws_iam_instance_profile" "worker_ec2_ecr_pull" {
  name = "${local.resource_prefix}-worker-ec2-ecr-pull-profile"
  role = aws_iam_role.worker_ec2_ecr_pull.name
}

resource "aws_iam_role_policy_attachment" "worker_ec2_bootstrap_s3_access" {
  role       = aws_iam_role.worker_ec2_ecr_pull.name
  policy_arn = aws_iam_policy.terrapilot_bootstrap_s3_access.arn
}

resource "aws_iam_role_policy_attachment" "worker_ec2_join_ssm" {
  role       = aws_iam_role.worker_ec2_ecr_pull.name
  policy_arn = aws_iam_policy.terrapilot_worker_join_ssm.arn
}

resource "aws_iam_role_policy_attachment" "worker_ec2_ssm_managed_instance" {
  role       = aws_iam_role.worker_ec2_ecr_pull.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}





# ECR pull policy for the EC2 User Data role (non-worker instances).
resource "aws_iam_policy" "terrapilot_ec2_ecr_pull" {
  name        = "${local.resource_prefix}-ec2-ecr-pull"
  description = "Least-privilege ECR image pull permissions for EC2 User Data role."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowEcrAuthorization"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid      = "AllowPullFromSelectedRepository"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = local.ecr_repository_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "terrapilot_ec2_ecr_pull" {
  role       = aws_iam_role.terrapilot_ec2_userdata.name
  policy_arn = aws_iam_policy.terrapilot_ec2_ecr_pull.arn
}

