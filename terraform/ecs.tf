# ============================================================================
# ecs.tf — ECS Cluster and Task Definition
#
# KEY CONCEPT: A "task definition" is like a recipe — it describes WHAT to run
# (Docker image, CPU, memory, env vars). It doesn't run anything by itself.
#
# The EventBridge Scheduler (scheduler.tf) triggers a new "task" from this
# definition each night. The task runs run_once.sh, processes data, writes
# to S3, and exits. No long-running service needed.
# ============================================================================

# The ECS cluster — a logical grouping of tasks
resource "aws_ecs_cluster" "main" {
  name = var.project_name
  tags = local.common_tags

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 100
    base              = 1
  }
}

# The task definition — the "recipe" for running the pipeline
resource "aws_ecs_task_definition" "pipeline" {
  family                   = var.project_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.fargate_cpu
  memory                   = var.fargate_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn
  tags                     = local.common_tags

  ephemeral_storage {
    size_in_gib = var.fargate_ephemeral_storage_gib
  }

  container_definitions = jsonencode([{
    name      = "ghcnd-pipeline"
    image     = local.ecr_image_url
    essential = true

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.pipeline.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "pipeline"
      }
    }

    # These env vars override the Dockerfile defaults and docker-compose.yml
    environment = [
      { name = "TZ",                     value = "America/Denver" },
      { name = "PROJECT_DIR",            value = "/opt/app" },
      { name = "DATA_DIR",               value = "/data" },
      { name = "CORES",                  value = tostring(var.container_cores) },
      { name = "START_YEAR",             value = tostring(var.start_year) },
      { name = "CLIM_PERIODS",           value = var.clim_periods },
      { name = "TIMESCALES",             value = var.timescales },
      { name = "MAX_REPORTING_LATENCY",  value = tostring(var.max_reporting_latency) },
      { name = "MIN_OBS_FRACTION",       value = tostring(var.min_obs_fraction) },
      { name = "MIN_CLIM_YEARS",         value = "30" },
      { name = "AWS_BUCKET",             value = var.s3_bucket_name },
      { name = "AWS_DEFAULT_REGION",     value = var.aws_region },
    ]

    ulimits = [{
      name      = "nofile"
      softLimit = 65536
      hardLimit = 65536
    }]
  }])
}
