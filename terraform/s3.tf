# ============================================================================
# s3.tf — S3 bucket for outputs
#
# This bucket holds the pipeline outputs (GeoJSON, CSV, per-station JSON)
# and also caches the raw/interim data so subsequent Fargate runs don't
# need to re-download everything.
#
# Public read access is enabled so the GeoJSON/CSV can be consumed by
# web applications without authentication.
# ============================================================================

resource "aws_s3_bucket" "output" {
  bucket = var.s3_bucket_name
  tags   = local.common_tags
}

# Allow public reads (for web delivery of GeoJSON, CSV, etc.)
resource "aws_s3_bucket_public_access_block" "output" {
  bucket = aws_s3_bucket.output.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "public_read" {
  bucket     = aws_s3_bucket.output.id
  depends_on = [aws_s3_bucket_public_access_block.output]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicRead"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.output.arn}/*"
    }]
  })
}

# CORS — allow web apps to fetch data directly from S3
resource "aws_s3_bucket_cors_configuration" "output" {
  bucket = aws_s3_bucket.output.id

  cors_rule {
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["*"]
    allowed_headers = ["*"]
    max_age_seconds = 3600
  }
}
