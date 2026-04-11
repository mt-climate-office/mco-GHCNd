# ============================================================================
# outputs.tf — Values printed after terraform apply
#
# These are the important URLs/ARNs you'll need for pushing images,
# checking logs, and accessing outputs.
# ============================================================================

output "ecr_repository_url" {
  description = "ECR repo URL — use for docker tag/push"
  value       = aws_ecr_repository.app.repository_url
}

output "s3_bucket_name" {
  description = "S3 bucket for pipeline outputs"
  value       = aws_s3_bucket.output.id
}

output "s3_bucket_url" {
  description = "Public URL to browse S3 outputs"
  value       = "https://${aws_s3_bucket.output.bucket}.s3.${var.aws_region}.amazonaws.com"
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_task_definition_arn" {
  description = "Task definition ARN (for manual runs)"
  value       = aws_ecs_task_definition.pipeline.arn
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group (for debugging)"
  value       = aws_cloudwatch_log_group.pipeline.name
}

output "scheduler_arn" {
  description = "EventBridge Scheduler ARN"
  value       = aws_scheduler_schedule.nightly.arn
}

output "push_commands" {
  description = "Commands to build and push the Docker image"
  value       = <<-EOT
    # Authenticate Docker to ECR:
    aws ecr get-login-password --region ${var.aws_region} --profile ${var.aws_profile} | docker login --username AWS --password-stdin ${aws_ecr_repository.app.repository_url}

    # Build, tag, and push:
    docker build --platform linux/amd64 -t ${var.project_name} .
    docker tag ${var.project_name}:latest ${aws_ecr_repository.app.repository_url}:latest
    docker push ${aws_ecr_repository.app.repository_url}:latest
  EOT
}
