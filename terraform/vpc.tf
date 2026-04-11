# ============================================================================
# vpc.tf — Reference existing VPC
#
# We don't create a VPC — we reference your existing one.
# Fargate tasks run inside this VPC and need internet access to
# download GHCNd data from NCEI.
# ============================================================================

data "aws_vpc" "existing" {
  id = var.vpc_id
}
