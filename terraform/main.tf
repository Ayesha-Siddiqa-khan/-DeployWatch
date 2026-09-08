terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Project           = "DeployWatch"
      Environment       = "dev"
      ManagedBy         = "TerraPilot"
      TerraPilotProject = "DeployWatch"
    }
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  resource_prefix = (var.project_name == var.environment || endswith(var.project_name, "-dev")) ? var.project_name : "${var.project_name}-${var.environment}"
}
