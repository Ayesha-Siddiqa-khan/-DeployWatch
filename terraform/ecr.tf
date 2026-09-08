# ECR

resource "aws_ecr_repository" "main" {
  name                 = var.ecr_repository_name
  image_tag_mutability = var.ecr_image_tag_mutability

  image_scanning_configuration {
    scan_on_push = var.ecr_scan_on_push
  }

  tags = {
    Name                   = "${var.project_name}"
    Project                = var.project_name
    TerraPilotProject      = var.project_name
    TerraPilotResourceType = "ecr-repository"
    Environment            = var.environment
    ManagedBy              = "TerraPilot"
    CostSensitive          = "true"
  }
}

resource "aws_ecr_lifecycle_policy" "main" {
  count      = var.ecr_lifecycle_policy_enabled ? 1 : 0
  repository = aws_ecr_repository.main.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images older than 30 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

locals {
  ecr_repository_url = aws_ecr_repository.main.repository_url
  ecr_repository_arn = aws_ecr_repository.main.arn
}
