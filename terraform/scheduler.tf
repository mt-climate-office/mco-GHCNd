# ============================================================================
# scheduler.tf — EventBridge Scheduler
#
# This is the "cron job" that triggers the pipeline nightly.
# It creates a new Fargate task from the task definition, waits for it
# to finish, and that's it. No retries — if it fails, tomorrow's run
# is the retry.
#
# DST is handled automatically — "10 PM America/Denver" is always 10 PM
# whether it's MST or MDT.
# ============================================================================

resource "aws_scheduler_schedule" "nightly" {
  name       = "${var.project_name}-nightly"
  group_name = "default"

  schedule_expression          = var.schedule_time
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode = "OFF"  # Run at exactly the scheduled time
  }

  target {
    arn      = aws_ecs_cluster.main.arn
    role_arn = aws_iam_role.scheduler.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.pipeline.arn
      launch_type         = "FARGATE"
      task_count          = 1

      network_configuration {
        assign_public_ip = var.assign_public_ip
        subnets          = local.resolved_subnet_ids
        security_groups  = local.fargate_security_group_ids
      }
    }

    retry_policy {
      maximum_retry_attempts       = 0     # No retries
      maximum_event_age_in_seconds = 3600  # Give up after 1 hour if not started
    }
  }
}
