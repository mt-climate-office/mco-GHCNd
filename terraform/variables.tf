# ============================================================================
# variables.tf — Input variables
#
# These are the knobs you turn. Some have defaults, some you must provide
# in terraform.tfvars or via -var flags.
# ============================================================================

# ---- AWS configuration -------------------------------------------------------

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-2"  # Ohio — where your ECS cluster lives
}

variable "aws_profile" {
  description = "AWS CLI profile name (from ~/.aws/config)"
  type        = string
  default     = "mco"
}

variable "aws_account_id" {
  description = "Your AWS account ID (find in top-right of console)"
  type        = string
  # No default — you must provide this
}

variable "project_name" {
  description = "Name used for all resources (ECR, ECS, S3, etc.)"
  type        = string
  default     = "mco-ghcnd"
}

# ---- Networking --------------------------------------------------------------
# Fargate tasks need a VPC with subnets that have internet access
# (either public subnets with public IP, or private subnets with NAT gateway)

variable "vpc_id" {
  description = "VPC ID where Fargate tasks will run"
  type        = string
  # No default — you must provide this
}

variable "subnet_ids" {
  description = "Subnet IDs for Fargate tasks. If empty, uses all subnets in the VPC"
  type        = list(string)
  default     = []
}

variable "assign_public_ip" {
  description = "Assign public IP to Fargate tasks (needed in public subnets without NAT)"
  type        = bool
  default     = true
}

variable "extra_security_group_ids" {
  description = "Additional security group IDs to attach to Fargate tasks"
  type        = list(string)
  default     = []
}

# ---- S3 storage --------------------------------------------------------------

variable "s3_bucket_name" {
  description = "S3 bucket for GHCNd drought outputs (will be created)"
  type        = string
  default     = "mco-ghcnd"
}

# ---- Scheduling --------------------------------------------------------------

variable "schedule_time" {
  description = "Cron expression for nightly run (EventBridge format)"
  type        = string
  default     = "cron(0 22 * * ? *)"  # 10 PM daily
}

variable "schedule_timezone" {
  description = "Timezone for the schedule (handles DST automatically)"
  type        = string
  default     = "America/Denver"
}

# ---- Fargate compute ---------------------------------------------------------

variable "fargate_cpu" {
  description = "CPU units for the Fargate task (1024 = 1 vCPU)"
  type        = number
  default     = 4096  # 4 vCPU
}

variable "fargate_memory" {
  description = "Memory in MiB for the Fargate task"
  type        = number
  default     = 16384  # 16 GB
}

variable "fargate_ephemeral_storage_gib" {
  description = "Ephemeral disk storage in GiB (holds downloaded CSVs + station data)"
  type        = number
  default     = 50  # 50 GiB — plenty for GHCNd station data
}

# ---- Container environment ---------------------------------------------------

variable "container_cores" {
  description = "Parallel R worker cores inside the container"
  type        = number
  default     = 4
}

variable "start_year" {
  description = "Earliest year of GHCNd data to download"
  type        = number
  default     = 1979
}

variable "clim_periods" {
  description = "Climatology reference periods (comma-separated)"
  type        = string
  default     = "rolling:30,full"
}

variable "timescales" {
  description = "Accumulation windows in days (comma-separated, plus wy and ytd)"
  type        = string
  default     = "15,30,45,60,90,120,180,365,730,wy,ytd"
}

variable "max_reporting_latency" {
  description = "Max days since last observation for a station to be included"
  type        = number
  default     = 3
}

variable "min_obs_fraction" {
  description = "Minimum fraction of non-missing days per rolling window"
  type        = number
  default     = 1
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 90
}
