#!/usr/bin/env bash
# ============================================================================
# ecr-push.sh — Build and push Docker image to ECR
#
# Usage: bash scripts/ecr-push.sh
#
# Prerequisites:
#   - AWS CLI configured (aws configure or aws sso login --profile mco)
#   - terraform apply completed (so ECR repo exists)
# ============================================================================
set -euo pipefail

REGION="${AWS_REGION:-us-east-2}"
PROFILE="${AWS_PROFILE:-mco}"
PROJECT="mco-ghcnd"

# Get ECR URL from terraform output
cd "$(dirname "$0")/../terraform"
ECR_URL=$(terraform output -raw ecr_repository_url)
cd -

echo "=== Authenticating Docker to ECR ==="
aws ecr get-login-password --region "$REGION" --profile "$PROFILE" \
  | docker login --username AWS --password-stdin "$ECR_URL"

echo "=== Building Docker image (linux/amd64) ==="
docker build --platform linux/amd64 -t "$PROJECT" .

echo "=== Tagging and pushing ==="
docker tag "$PROJECT:latest" "$ECR_URL:latest"
docker tag "$PROJECT:latest" "$ECR_URL:$(git rev-parse --short HEAD)"
docker push "$ECR_URL:latest"
docker push "$ECR_URL:$(git rev-parse --short HEAD)"

echo "=== Done! Image pushed to $ECR_URL ==="
