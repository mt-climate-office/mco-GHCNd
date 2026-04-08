#!/usr/bin/env bash
# ============================================================================
# run_test.sh — Quick test with ~100 CONUS stations
#
# Usage: bash pipeline/run_test.sh
#        docker compose run ghcnd bash pipeline/run_test.sh
# ============================================================================
set -euo pipefail

export TIMESCALES="30,90"
export CLIM_PERIODS="rolling:30"
export CORES="${CORES:-4}"
export START_YEAR="${START_YEAR:-1991}"
export MAX_STATIONS=1000

echo "=== GHCNd Pipeline Test Run ==="
echo "  Max stations: $MAX_STATIONS"
echo "  Timescales: $TIMESCALES"
echo "  Cores: $CORES"
echo ""

# Run the full pipeline — MAX_STATIONS limits station count
bash "$(dirname "$0")/run_once.sh"
