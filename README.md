# MCO GHCNd Station Drought Pipeline

A station-based drought monitoring pipeline for the contiguous United States (CONUS) built on
[GHCNd](https://www.ncei.noaa.gov/products/land-based-station/global-historical-climatology-network-daily)
(Global Historical Climatology Network - Daily) station observations. Produces GeoJSON, CSV, and
per-station JSON drought indices across a range of timescales, updated operationally via Docker.

---

## Metrics Produced

| Indicator | Description | Stations |
|-----------|-------------|----------|
| **SPI** | Standardized Precipitation Index | All with PRCP (~5,277) |
| **SPEI** | Standardized Precipitation-Evapotranspiration Index | PRCP + TMAX + TMIN (~4,096) |
| **EDDI** | Evaporative Demand Drought Index | TMAX + TMIN (~4,096) |
| **% of Normal** | Precipitation as percent of climatological normal | All with PRCP |
| **Deviation** | Precipitation departure from normal (mm) | All with PRCP |
| **Percentile** | Precipitation percentile rank | All with PRCP |
| **Accumulation** | Raw precipitation sum (mm) | All with PRCP |

**Timescales:** 15d, 30d, 45d, 60d, 90d, 120d, 180d, 365d, 730d, water year, year-to-date (YTD)

**PET Method:** Hargreaves-Samani daily reference evapotranspiration (FAO-56 extraterrestrial radiation)

---

## Pipeline

Scripts run sequentially inside the container via `run_once.sh`:

```
0_ghcnd-station-filter.R   Filter active CONUS stations from GHCNd inventory
        |
        v
1_ghcnd-cache.R            Download / parse GHCNd by-year CSVs → per-station RDS
        |
        v
2_compute-pet.R            Hargreaves-Samani daily ET₀
        |
        v
3_metrics-spi.R            SPI (Gamma + Stagge et al. zero handling)
        |
        v
4_metrics-spei.R           SPEI (GLO on water balance)
        |
        v
5_metrics-eddi.R           EDDI (nonparametric rank-based)
        |
        v
6_metrics-precip-accum.R   Precip accumulation, % of normal, departure, percentile
        |
        v
7_output-assembly.R        GeoJSON, CSV, per-station JSON, catalog, manifest
```

All outputs land in `$DATA_DIR/derived/ghcnd_drought/`.

---

## Repository Structure

```
mco-GHCNd/
├── Dockerfile
├── docker-compose.yml
├── R/
│   ├── 0_ghcnd-station-filter.R
│   ├── 1_ghcnd-cache.R
│   ├── 2_compute-pet.R
│   ├── 3_metrics-spi.R
│   ├── 4_metrics-spei.R
│   ├── 5_metrics-eddi.R
│   ├── 6_metrics-precip-accum.R
│   ├── 7_output-assembly.R
│   ├── drought-functions.R
│   └── pipeline-common.R
├── pipeline/
│   ├── run_once.sh             # Container entry point — orchestrates the full pipeline
│   └── run_test.sh             # Lightweight test harness (subset of stations)
├── scripts/
│   └── ecr-push.sh             # Build and push Docker image to ECR
├── terraform/                  # AWS infrastructure (see Cloud Architecture below)
│   ├── main.tf
│   ├── variables.tf
│   ├── locals.tf
│   ├── outputs.tf
│   ├── s3.tf
│   ├── ecr.tf
│   ├── iam.tf
│   ├── vpc.tf
│   ├── ecs.tf
│   ├── scheduler.tf
│   ├── cloudwatch.tf
│   └── terraform.tfvars.example
├── docs/
│   └── methods.html            # Detailed methods documentation
├── .gitignore
└── README.md
```

Expected data layout (outside the repo, mounted at runtime):

```
$DATA_DIR/                                  # e.g. ~/mco-GHCNd-data
├── raw/ghcnd/
│   ├── csv/                                # By-year CSV.gz files from NCEI
│   │   ├── 1979.csv.gz
│   │   └── ... 2026.csv.gz
│   ├── ghcnd-stations.txt                  # Station metadata
│   └── ghcnd-inventory.txt                 # Station element inventory
├── interim/
│   ├── station_lists/                      # Filtered station lists (RDS)
│   │   ├── stations_spi.rds
│   │   └── stations_spei.rds
│   └── stations/                           # Parsed per-station daily data (RDS)
│       ├── USW00024153.rds
│       └── ...
├── derived/ghcnd_drought/
│   ├── GHCNd_drought_current.geojson       # Summary GeoJSON (all stations)
│   ├── GHCNd_drought_current.geojson.gz    # Gzipped version (~2 MB, for web delivery)
│   ├── all_stations.csv                    # Summary CSV (wide format)
│   ├── station_catalog.csv                 # Station metadata + available indices
│   ├── manifest.csv                        # Per-dataset date manifest
│   ├── latest-date.txt                     # Most recent data date
│   └── stations/                           # Per-station JSON files
│       ├── USW00024153.json
│       └── ...
└── tmp/R/                                  # R scratch space
```

---

## Quick Start (Local Docker)

**Prerequisites:** Docker Desktop (or Docker Engine + Compose plugin).

```bash
# 1. Clone the repo
git clone https://github.com/mt-climate-office/mco-GHCNd.git
cd mco-GHCNd

# 2. Build the image
docker compose build

# 3. Run the full pipeline
docker compose up

# 4. Or run a quick test (~100 stations, 2 timescales)
docker compose run ghcnd bash pipeline/run_test.sh
```

All processed data is written to `~/mco-GHCNd-data` on your host (outside the repo,
never tracked by git). Override with the `DATA_DIR` environment variable:

```bash
DATA_DIR=/Volumes/my-drive/ghcnd-data docker compose up
```

S3 sync is **automatically skipped** in local runs — `AWS_BUCKET` is not set by
docker-compose, so no credentials or AWS access are required.

### Cold Start vs. Warm Start

| Run | Behavior |
|-----|----------|
| Cold start (first ever) | Downloads all 48 yearly CSVs from NCEI (~6 GB compressed); parses into per-station RDS files. Takes ~1–2 hours. |
| Warm start (subsequent) | Only re-downloads current year CSV (~33 MB); merges into existing per-station RDS files. Takes ~15–20 minutes. |

---

## Environment Variables

Override any of these in `docker-compose.yml` under `environment:`, or pass them with
`docker compose run -e VAR=value`.

| Variable | Default | Description |
|----------|---------|-------------|
| `CORES` | `4` | Parallel workers for station processing |
| `START_YEAR` | `1979` | Earliest year to include in GHCNd download |
| `TIMESCALES` | `15,30,...,730,wy,ytd` | Comma-separated aggregation timescales |
| `CLIM_PERIODS` | `rolling:30` | Climatological reference period specs (see below) |
| `MIN_CLIM_YEARS` | `30` | Minimum years of data for distribution fitting |
| `MAX_REPORTING_LATENCY` | `3` | Max days since last observation for a station to be included |
| `MIN_OBS_FRACTION` | `1` | Minimum fraction of non-missing days per rolling window (1 = no gaps allowed) |
| `COUNTRY_FILTER` | (empty) | FIPS country code filter; if empty, defaults to CONUS bounding box |
| `STATION_IDS` | (empty) | Comma-separated station IDs for testing specific stations |
| `MAX_STATIONS` | `0` | Cap on number of stations (0 = all; used by `run_test.sh`) |
| `DATA_DIR` | `~/mco-GHCNd-data` | Root directory for all data |
| `AWS_BUCKET` | (empty) | S3 bucket for output sync; if empty, S3 sync is skipped |

### `CLIM_PERIODS` syntax

| Spec | Description |
|------|-------------|
| `rolling:N` | Last N years from current date (default: `rolling:30`) |
| `fixed:YYYY:YYYY` | Fixed year range (e.g. `fixed:1991:2020`) |
| `full` | All years from `START_YEAR` to present |

Multiple specs are comma-separated. Each produces its own set of output columns:

```yaml
CLIM_PERIODS: "rolling:30"            # Single period (default)
CLIM_PERIODS: "rolling:30,full"       # Two periods in one run
```

---

## Quick Test

```bash
# Inside Docker (default: 1000 stations, 30d + 90d timescales)
docker compose run ghcnd bash pipeline/run_test.sh
```

Configurable via environment variables in `run_test.sh`: `MAX_STATIONS`, `TIMESCALES`,
`CORES`, `START_YEAR`.

---

## Cloud Architecture (AWS)

The pipeline runs nightly on AWS Fargate, triggered by an EventBridge Scheduler rule at
**10:00 PM Mountain Time** (DST-aware). Outputs are written to a public S3 bucket.
All infrastructure is managed with Terraform in the `terraform/` directory.

### Architecture Overview

```
EventBridge Scheduler (10 PM Mountain)
        |
        v
  ECS Fargate Task  ─────────────────────────────────────────┐
  (4 vCPU / 16 GB / 50 GiB ephemeral)                       |
        |                                                     |
        v                                                     v
  S3: mco-ghcnd/raw/              (restore at start / save at end)
  S3: mco-ghcnd/derived/          (final outputs, public)
        |
  ECR: mco-ghcnd                  (Docker image)
  CloudWatch: /ecs/mco-ghcnd      (logs, 90-day retention)
```

### AWS Resources

| Resource | Name | Purpose |
|----------|------|---------|
| S3 bucket | `mco-ghcnd` | Public outputs + GHCNd data cache |
| ECR repository | `mco-ghcnd` | Docker image registry |
| ECS cluster | `mco-ghcnd` | Fargate compute |
| ECS task definition | `mco-ghcnd` | 4 vCPU, 16 GB RAM, 50 GiB ephemeral |
| EventBridge Scheduler | `mco-ghcnd-nightly` | `cron(0 22 * * ? *)` / `America/Denver` |
| CloudWatch log group | `/ecs/mco-ghcnd` | Pipeline logs (90-day retention) |
| IAM roles | `mco-ghcnd-task`, `-task-execution`, `-scheduler` | Least-privilege permissions |

### S3 Bucket Layout

```
s3://mco-ghcnd/
├── raw/ghcnd/                             # GHCNd CSV cache
├── interim/                               # Per-station RDS cache
└── derived/ghcnd_drought/
    ├── {YYYY-MM-DD}/                      # Dated archive — one per pipeline run
    │   ├── GHCNd_drought_current.geojson
    │   ├── all_stations.csv
    │   ├── manifest.csv
    │   └── stations/
    │       └── {STATION_ID}.json
    └── latest/                            # Operational copy — always current
        ├── GHCNd_drought_current.geojson.gz
        ├── all_stations.csv
        ├── manifest.csv
        ├── latest-date.txt
        └── stations/
            └── {STATION_ID}.json
```

### Caching Strategy

Because Fargate ephemeral storage is wiped when a task stops, data is cached in S3:

| Run | Behavior |
|-----|----------|
| Cold start (first Fargate run) | Downloads all CSVs from NCEI; parses all stations; saves to S3 (~1–2 hours) |
| Every subsequent run | Restores cache from S3 (~5 min); refreshes current year only; saves updates back (~15–20 min total) |

---

### Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- AWS SSO configured in `~/.aws/config` with a profile named `mco`

### First-Time Deployment

```bash
# 1. Authenticate
aws sso login --profile mco

# 2. Create your tfvars
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform/terraform.tfvars with your account ID, VPC ID, subnet IDs

# 3. Deploy infrastructure
cd terraform
terraform init
terraform apply

# 4. Build and push the Docker image
cd ..
bash scripts/ecr-push.sh
```

After `terraform apply` completes, the outputs show all resource identifiers:

```
ecr_repository_url      = 202533506375.dkr.ecr.us-east-2.amazonaws.com/mco-ghcnd
ecs_cluster_name        = mco-ghcnd
s3_bucket_url           = https://mco-ghcnd.s3.us-east-2.amazonaws.com
scheduler_arn           = arn:aws:scheduler:us-east-2:...:schedule/default/mco-ghcnd-nightly
cloudwatch_log_group    = /ecs/mco-ghcnd
```

### Triggering a Manual Run

```bash
aws ecs run-task --cluster mco-ghcnd --task-definition mco-ghcnd --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets=[subnet-XXXXXXXXX],assignPublicIp=ENABLED}" --profile mco --region us-east-2
```

### Monitoring

```bash
# Watch logs from a running task
aws logs tail /ecs/mco-ghcnd --follow --profile mco --region us-east-2

# Check task status
aws ecs describe-tasks --cluster mco-ghcnd --tasks <task-id> --profile mco --region us-east-2 --query 'tasks[0].{status:lastStatus,stopReason:stoppedReason}'
```

### Redeploying After Code Changes

```bash
aws sso login --profile mco   # if SSO session has expired
bash scripts/ecr-push.sh      # rebuilds image and pushes :latest to ECR
```

The scheduler always pulls `:latest`, so the next nightly run automatically uses the new image.
No Terraform changes are needed for code-only updates.

### `terraform.tfvars` Reference

`terraform/terraform.tfvars` is gitignored. Copy `terraform.tfvars.example` and populate:

| Variable | Description |
|----------|-------------|
| `aws_region` | AWS region (e.g. `us-east-2`) |
| `aws_profile` | SSO profile name in `~/.aws/config` |
| `aws_account_id` | 12-digit AWS account ID |
| `vpc_id` | Existing VPC ID |
| `subnet_ids` | List of subnet IDs for Fargate tasks (must have internet access) |
| `s3_bucket_name` | S3 bucket for outputs (default: `mco-ghcnd`) |

---

## Data Source

Raw station data comes from **GHCNd** (NOAA NCEI):

- Variables used: `PRCP` (precipitation), `TMAX` (max temperature), `TMIN` (min temperature)
- Coverage: ~100,000+ stations globally; ~5,277 currently active CONUS stations with 30+ year records
- Temporal coverage: 1979–present (daily, updated daily by NCEI)
- Access: by-year CSV files from [ncei.noaa.gov/pub/data/ghcn/daily/by_year/](https://www.ncei.noaa.gov/pub/data/ghcn/daily/by_year/)
- Reference: Menne MJ et al. (2012). *An overview of the Global Historical Climatology
  Network-Daily database.* J. Atmos. Oceanic Technol.
  [doi:10.1175/JTECH-D-11-00103.1](https://doi.org/10.1175/JTECH-D-11-00103.1)

---

## Methods Documentation

See [docs/methods.html](docs/methods.html) for detailed scientific methods, including:
- Hargreaves-Samani PET with FAO-56 extraterrestrial radiation equations
- SPI (Gamma + Stagge et al. 2015 zero handling)
- SPEI (Generalized Logistic on water balance)
- EDDI (nonparametric rank-based, Hobbins et al. 2016)
- Station selection criteria and quality control
- Climatological reference period options

---

## Running Locally (Without Docker)

**Requirements:**

- R 4.4+
- System libraries: `gdal`, `geos`, `proj` (for `sf` GeoJSON output)
- R packages: `data.table`, `lmomco`, `sf`, `jsonlite`, `pbmcapply`, `purrr`

Set the required environment variables, then run `pipeline/run_once.sh` or invoke each script
individually:

```bash
export PROJECT_DIR=~/mco-GHCNd
export DATA_DIR=~/mco-GHCNd-data
export CORES=4

bash pipeline/run_once.sh   # full pipeline

# or run individual scripts:
Rscript R/0_ghcnd-station-filter.R
Rscript R/1_ghcnd-cache.R
# etc.
```

S3 sync is skipped automatically when `AWS_BUCKET` is not set.
