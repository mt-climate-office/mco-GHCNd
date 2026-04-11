# ============================================================================
# cloudwatch.tf — Logging
#
# Container stdout/stderr goes here. Check these logs when debugging
# failed runs: AWS Console → CloudWatch → Log Groups → /ecs/mco-ghcnd
# ============================================================================

resource "aws_cloudwatch_log_group" "pipeline" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}
