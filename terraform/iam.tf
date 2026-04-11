# ============================================================================
# iam.tf — IAM roles and policies
#
# Three roles, each with a specific job:
#
# 1. Task Execution Role — used by the ECS *agent* (not your code) to:
#    - Pull your Docker image from ECR
#    - Write container logs to CloudWatch
#
# 2. Task Role — used by your *running container* to:
#    - Read/write objects in the S3 output bucket
#    (This is what your R code's aws s3 sync commands use)
#
# 3. Scheduler Role — used by EventBridge to:
#    - Launch the ECS task on a schedule
#    - Pass the above roles to the task
# ============================================================================

# ---- 1. Task Execution Role --------------------------------------------------

resource "aws_iam_role" "task_execution" {
  name = "${var.project_name}-task-execution"
  tags = local.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ---- 2. Task Role (S3 access for your code) ----------------------------------

resource "aws_iam_role" "task" {
  name = "${var.project_name}-task"
  tags = local.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "task_s3" {
  name = "s3-access"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.output.arn,
        "${aws_s3_bucket.output.arn}/*"
      ]
    }]
  })
}

# ---- 3. Scheduler Role (EventBridge → ECS) -----------------------------------

resource "aws_iam_role" "scheduler" {
  name = "${var.project_name}-scheduler"
  tags = local.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "run-ecs-task"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RunECSTask"
        Effect   = "Allow"
        Action   = "ecs:RunTask"
        Resource = aws_ecs_task_definition.pipeline.arn
      },
      {
        Sid      = "PassRoles"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = [
          aws_iam_role.task_execution.arn,
          aws_iam_role.task.arn
        ]
      }
    ]
  })
}
