FROM rocker/r-ver:4.4.1

# System dependencies
# cmake: needed by fs (libuv) and s2 (abseil)
# libgdal-dev/libgeos-dev/libproj-dev: needed by sf for GeoJSON output
# libudunits2-dev: needed by units (sf dependency)
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    tzdata \
    cmake \
    pkg-config \
    libgdal-dev \
    libgeos-dev \
    libproj-dev \
    libsqlite3-dev \
    libudunits2-dev \
    zlib1g-dev \
    unzip \
  && rm -rf /var/lib/apt/lists/*

# AWS CLI v2 (for S3 sync on Fargate)
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
  && unzip -q /tmp/awscliv2.zip -d /tmp \
  && /tmp/aws/install \
  && rm -rf /tmp/awscliv2.zip /tmp/aws

# Timezone
ENV TZ=America/Denver

# Single-threaded BLAS for forked workers
ENV OMP_NUM_THREADS=1
ENV OPENBLAS_NUM_THREADS=1
ENV MKL_NUM_THREADS=1

# R packages — install to system library so all users can access
RUN R -q -e 'install.packages(c( \
    "data.table", \
    "jsonlite", \
    "sf", \
    "lmomco", \
    "pbmcapply", \
    "purrr" \
  ), repos = "https://cloud.r-project.org", lib = .Library)' \
  && R -q -e 'stopifnot(all(c("data.table","jsonlite","sf","lmomco","pbmcapply","purrr") %in% installed.packages()[,"Package"]))'

# Non-root user
RUN useradd -m -s /bin/bash mco-ghcnd

# Create data directory (writable by mco-ghcnd)
# On Fargate, DATA_DIR=/data is set by the task definition
# Locally, DATA_DIR defaults to /home/mco-ghcnd/mco-GHCNd-data
RUN mkdir -p /data && chown mco-ghcnd:mco-ghcnd /data

# Copy application code
WORKDIR /opt/app
COPY R/ /opt/app/R/
COPY pipeline/ /opt/app/pipeline/
RUN chmod +x /opt/app/pipeline/*.sh

# Default environment
ENV PROJECT_DIR=/opt/app
ENV DATA_DIR=/home/mco-ghcnd/mco-GHCNd-data

USER mco-ghcnd
CMD ["/opt/app/pipeline/run_once.sh"]
