# ============================================================================
# main.tf — Terraform config and provider
#
# HOW TERRAFORM WORKS (quick primer):
#   - Terraform reads all .tf files in this directory
#   - "terraform init" downloads the AWS provider plugin
#   - "terraform plan" shows what it WOULD create/change (dry run)
#   - "terraform apply" actually creates/changes the resources
#   - "terraform destroy" tears everything down
#   - State is tracked in terraform.tfstate (local file or S3 backend)
# ============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Optional: store state in S3 for team collaboration
  # Uncomment and configure if you want shared state
  # backend "s3" {
  #   bucket  = "mco-terraform-state"
  #   key     = "mco-GHCNd/terraform.tfstate"
  #   region  = "us-east-2"
  #   profile = "mco"
  # }
}

# The AWS provider — tells terraform which region and credentials to use
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}
