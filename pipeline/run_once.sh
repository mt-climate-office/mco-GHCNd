#!/usr/bin/env bash
set -euo pipefail
PIPELINE_START=$SECONDS

export PROJECT_DIR="${PROJECT_DIR:-$HOME/mco-GHCNd}"
export DATA_DIR="${DATA_DIR:-$HOME/mco-GHCNd-data}"

export CORES="${CORES:-4}"
export START_YEAR="${START_YEAR:-1991}"

# Temp dirs
export TMPDIR="${TMPDIR:-$DATA_DIR/tmp}"
export R_TEMP_DIR="${R_TEMP_DIR:-$DATA_DIR/tmp/R}"

echo "=== $(date) — Preparing data directories ==="
mkdir -p \
  "$DATA_DIR" \
  "$DATA_DIR/raw/ghcnd/csv" \
  "$DATA_DIR/interim/station_lists" \
  "$DATA_DIR/interim/stations" \
  "$DATA_DIR/derived/ghcnd_drought/stations" \
  "$TMPDIR" \
  "$R_TEMP_DIR"

# Fix permissions (Docker non-root user)
chown -R "$(whoami)" "$DATA_DIR" 2>/dev/null || true

# ============================================================
# S3 CACHE RESTORE
# Pulls cached data from S3 so Fargate runs skip re-downloading.
# Only runs when AWS_BUCKET is set (local runs are unaffected).
# ============================================================
if [ -n "${AWS_BUCKET:-}" ]; then
  echo "=== $(date) — Restoring cached data from S3 ==="
  aws s3 sync "s3://${AWS_BUCKET}/raw/ghcnd/" "$DATA_DIR/raw/ghcnd/" --no-progress || true
  aws s3 sync "s3://${AWS_BUCKET}/interim/" "$DATA_DIR/interim/" --no-progress || true
  aws s3 sync "s3://${AWS_BUCKET}/derived/ghcnd_drought/latest/" "$DATA_DIR/derived/ghcnd_drought/" --no-progress || true
  echo "=== $(date) — Cache restore complete ==="
fi

# Seed data dates from manifest if restored from S3
_MANIFEST="$DATA_DIR/derived/ghcnd_drought/manifest.csv"
SPI_DATE="$(grep '^spi,' "$_MANIFEST" 2>/dev/null | cut -d, -f2 | head -1 || echo "")"
SPEI_DATE="$(grep '^spei,' "$_MANIFEST" 2>/dev/null | cut -d, -f2 | head -1 || echo "")"
PRECIP_DATE="$(grep '^precip_accum,' "$_MANIFEST" 2>/dev/null | cut -d, -f2 | head -1 || echo "")"

# S3 sync helper (only when AWS_BUCKET is set)
s3_sync_derived() {
  if [ -n "${AWS_BUCKET:-}" ]; then
    echo "=== $(date) — Syncing derived outputs to S3 ==="
    aws s3 sync "$DATA_DIR/derived/ghcnd_drought/" \
      "s3://${AWS_BUCKET}/derived/ghcnd_drought/latest/" \
      --no-progress || true
  fi
}

# ============================================================
# PIPELINE STEPS
# ============================================================

echo "=== $(date) — Step 0: Filtering active GHCNd stations ==="
Rscript "$PROJECT_DIR/R/0_ghcnd-station-filter.R"

echo "=== $(date) — Step 1: Downloading and parsing GHCNd data ==="
Rscript "$PROJECT_DIR/R/1_ghcnd-cache.R"

echo "=== $(date) — Step 2: Computing Hargreaves-Samani PET ==="
Rscript "$PROJECT_DIR/R/2_compute-pet.R"

echo "=== $(date) — Step 3: Computing SPI ==="
Rscript "$PROJECT_DIR/R/3_metrics-spi.R"
s3_sync_derived

echo "=== $(date) — Step 4: Computing SPEI ==="
Rscript "$PROJECT_DIR/R/4_metrics-spei.R"
s3_sync_derived

echo "=== $(date) — Step 5: Computing EDDI ==="
Rscript "$PROJECT_DIR/R/5_metrics-eddi.R"
s3_sync_derived

echo "=== $(date) — Step 6: Computing precipitation accumulations ==="
Rscript "$PROJECT_DIR/R/6_metrics-precip-accum.R"
s3_sync_derived

echo "=== $(date) — Step 7: Assembling outputs ==="
Rscript "$PROJECT_DIR/R/7_output-assembly.R"

echo "=== $(date) — All drought metrics complete ==="

# ============================================================
# S3 SYNC — final outputs
# ============================================================
if [ -n "${AWS_BUCKET:-}" ]; then
  DATA_DATE="$(date +%Y-%m-%d)"

  echo "=== $(date) — Saving raw cache to S3 ==="
  aws s3 sync "$DATA_DIR/raw/ghcnd/" "s3://${AWS_BUCKET}/raw/ghcnd/" --no-progress || true

  echo "=== $(date) — Saving interim cache to S3 ==="
  aws s3 sync "$DATA_DIR/interim/" "s3://${AWS_BUCKET}/interim/" --no-progress || true

  echo "=== $(date) — Archiving outputs to s3://${AWS_BUCKET}/derived/ghcnd_drought/${DATA_DATE}/ ==="
  aws s3 sync "$DATA_DIR/derived/ghcnd_drought/" \
    "s3://${AWS_BUCKET}/derived/ghcnd_drought/${DATA_DATE}/" \
    --no-progress

  echo "=== $(date) — Syncing latest outputs ==="
  aws s3 sync "$DATA_DIR/derived/ghcnd_drought/" \
    "s3://${AWS_BUCKET}/derived/ghcnd_drought/latest/" \
    --delete --no-progress

  echo "=== $(date) — S3 sync complete (date=${DATA_DATE}) ==="
else
  echo "=== $(date) — AWS_BUCKET not set; skipping S3 sync (local run) ==="
fi

PIPELINE_ELAPSED=$(( SECONDS - PIPELINE_START ))
echo "=== $(date) — Total pipeline wall time: $(( PIPELINE_ELAPSED / 60 ))m $(( PIPELINE_ELAPSED % 60 ))s ==="
