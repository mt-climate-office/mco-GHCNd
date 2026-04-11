# ============================================================================
# ecr.tf — Elastic Container Registry
#
# This is where your Docker image lives. The workflow is:
#   1. Build locally: docker build -t mco-ghcnd .
#   2. Tag for ECR:   docker tag mco-ghcnd:latest <ECR_URL>:latest
#   3. Push to ECR:   docker push <ECR_URL>:latest
#
# The ECS task definition always pulls :latest, so pushing a new image
# automatically updates what runs next time.
# ============================================================================

resource "aws_ecr_repository" "app" {
  name                 = var.project_name
  image_tag_mutability = "MUTABLE"
  tags                 = local.common_tags

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Keep only the 5 most recent images (saves storage costs)
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only 5 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}
