# ============================================================================
# locals.tf — Computed values used across other files
# ============================================================================

data "aws_subnets" "vpc" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}

locals {
  common_tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }

  # Use explicit subnet_ids if provided, otherwise auto-discover all VPC subnets
  resolved_subnet_ids = length(var.subnet_ids) > 0 ? var.subnet_ids : data.aws_subnets.vpc.ids

  # Security groups — use extra_security_group_ids if provided
  fargate_security_group_ids = var.extra_security_group_ids

  # ECR image URL (always pull :latest)
  ecr_image_url = "${aws_ecr_repository.app.repository_url}:latest"
}
