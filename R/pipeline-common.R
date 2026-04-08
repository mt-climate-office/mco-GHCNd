# ============================================================================
# pipeline-common.R — Shared infrastructure for mco-GHCNd pipeline
#
# Provides: environment variable parsing, directory setup, timescale/climatology
# handling, GHCNd data readers, rolling window functions, parallel dispatch,
# and IO helpers.
# ============================================================================

library(data.table)

# ---- A. Core utilities -------------------------------------------------------

`%||%` = function(a, b) if (!is.null(a) && !is.na(a) && a != "") a else b

.abs_path = function(...) normalizePath(file.path(...), mustWork = FALSE)

msg = function(...) {
  cat(sprintf("=== %s — %s\n", format(Sys.time()), paste0(...)))
  flush.console()
}

# ---- B. Environment & path setup --------------------------------------------

setup_pipeline_env = function() {
  env = list()
  env$PROJECT_DIR  = Sys.getenv("PROJECT_DIR", .abs_path(Sys.getenv("HOME"), "mco-GHCNd"))
  env$DATA_DIR     = Sys.getenv("DATA_DIR", .abs_path(Sys.getenv("HOME"), "mco-GHCNd-data"))
  env$CORES        = as.integer(Sys.getenv("CORES", "4"))
  env$START_YEAR   = as.integer(Sys.getenv("START_YEAR", "1991"))
  env$TIMESCALES   = Sys.getenv("TIMESCALES", "30,60,90,180,365,wy,ytd")
  env$CLIM_PERIODS = Sys.getenv("CLIM_PERIODS", "rolling:30")
  env$MIN_CLIM_YEARS       = as.integer(Sys.getenv("MIN_CLIM_YEARS", "30"))
  env$MAX_REPORTING_LATENCY = as.integer(Sys.getenv("MAX_REPORTING_LATENCY", "60"))
  env$MIN_OBS_FRACTION     = as.numeric(Sys.getenv("MIN_OBS_FRACTION", "0.8"))
  env$COUNTRY_FILTER       = Sys.getenv("COUNTRY_FILTER", "")
  env$STATION_IDS          = Sys.getenv("STATION_IDS", "")
  env$AWS_BUCKET           = Sys.getenv("AWS_BUCKET", "")

  # Cap cores
  env$CORES = min(env$CORES, 12L)

  env
}

setup_pipeline_paths = function(env) {
  paths = list(
    raw_dir         = .abs_path(env$DATA_DIR, "raw", "ghcnd"),
    csv_dir         = .abs_path(env$DATA_DIR, "raw", "ghcnd", "csv"),
    stations_file   = .abs_path(env$DATA_DIR, "raw", "ghcnd", "ghcnd-stations.txt"),
    inventory_file  = .abs_path(env$DATA_DIR, "raw", "ghcnd", "ghcnd-inventory.txt"),
    interim_dir     = .abs_path(env$DATA_DIR, "interim"),
    station_lists   = .abs_path(env$DATA_DIR, "interim", "station_lists"),
    station_data    = .abs_path(env$DATA_DIR, "interim", "stations"),
    derived_dir     = .abs_path(env$DATA_DIR, "derived", "ghcnd_drought"),
    stations_out    = .abs_path(env$DATA_DIR, "derived", "ghcnd_drought", "stations"),
    tmp_dir         = .abs_path(env$DATA_DIR, "tmp", "R")
  )

  # Create directories only (not file paths)
  dirs_to_create = c("raw_dir", "csv_dir", "interim_dir", "station_lists",
                     "station_data", "derived_dir", "stations_out", "tmp_dir")
  for (d in dirs_to_create) {
    dir.create(paths[[d]], recursive = TRUE, showWarnings = FALSE)
  }

  paths
}

# ---- C. Timescale parsing ----------------------------------------------------

parse_timescales = function(ts_string) {
  # Returns a list of timescale specs: list(label, days_fn)
  # days_fn(ref_date) returns the number of days for that timescale
  raw = trimws(strsplit(ts_string, ",")[[1]])
  lapply(raw, function(t) {
    if (t == "wy") {
      list(label = "wy", get_days = function(ref_date) {
        # Water year: Oct 1 to ref_date
        yr = as.integer(format(ref_date, "%Y"))
        mo = as.integer(format(ref_date, "%m"))
        wy_start = if (mo >= 10) as.Date(sprintf("%d-10-01", yr)) else as.Date(sprintf("%d-10-01", yr - 1L))
        as.integer(ref_date - wy_start + 1L)
      })
    } else if (t == "ytd") {
      list(label = "ytd", get_days = function(ref_date) {
        as.integer(format(ref_date, "%j"))
      })
    } else {
      days = as.integer(t)
      list(label = paste0(days, "d"), get_days = function(ref_date) days)
    }
  })
}

# ---- D. Climatology period parsing -------------------------------------------

parse_clim_periods = function(clim_string) {
  raw = trimws(strsplit(clim_string, ",")[[1]])
  lapply(raw, function(p) {
    if (startsWith(p, "rolling:")) {
      n = as.integer(sub("rolling:", "", p))
      list(type = "rolling", n = n, label = paste0("rolling-", n))
    } else if (startsWith(p, "fixed:")) {
      parts = strsplit(sub("fixed:", "", p), ":")[[1]]
      list(type = "fixed", start = as.integer(parts[1]),
           end = as.integer(parts[2]),
           label = paste0("fixed-", parts[1], "-", parts[2]))
    } else if (p == "full") {
      list(type = "full", label = "full")
    } else {
      stop("Unknown climatology period: ", p)
    }
  })
}

get_clim_years = function(clim_period, current_year, start_year) {
  if (clim_period$type == "rolling") {
    seq(current_year - clim_period$n + 1L, current_year)
  } else if (clim_period$type == "fixed") {
    seq(clim_period$start, clim_period$end)
  } else {
    seq(start_year, current_year)
  }
}

# ---- E. GHCNd metadata readers ----------------------------------------------

NCEI_BASE = "https://www.ncei.noaa.gov/pub/data/ghcn/daily"

read_ghcnd_stations = function(stations_file) {
  # Fixed-width format from GHCNd readme
  # ID: 1-11, LAT: 13-20, LON: 22-30, ELEV: 32-37, STATE: 39-40, NAME: 42-71
  widths = c(11, 1, 8, 1, 9, 1, 6, 1, 2, 1, 30, 1, 3, 1, 3, 1, 5)
  col_names = c("id", "x1", "lat", "x2", "lon", "x3", "elev", "x4",
                "state", "x5", "name", "x6", "gsn_flag", "x7",
                "hcn_crn_flag", "x8", "wmo_id")

  dt = fread(stations_file, header = FALSE, sep = "\n", col.names = "raw")
  dt[, id    := trimws(substr(raw, 1, 11))]
  dt[, lat   := as.numeric(substr(raw, 13, 20))]
  dt[, lon   := as.numeric(substr(raw, 22, 30))]
  dt[, elev  := as.numeric(substr(raw, 32, 37))]
  dt[, state := trimws(substr(raw, 39, 40))]
  dt[, name  := trimws(substr(raw, 42, 71))]
  dt[, raw := NULL]

  # Clean up missing elevation (-999.9 = missing)
  dt[elev < -999, elev := NA_real_]

  dt
}

read_ghcnd_inventory = function(inventory_file) {
  # Fixed-width: ID(1-11) LAT(13-20) LON(22-30) ELEMENT(32-35) FIRSTYEAR(37-40) LASTYEAR(42-45)
  dt = fread(inventory_file, header = FALSE, sep = "\n", col.names = "raw")
  dt[, id        := trimws(substr(raw, 1, 11))]
  dt[, lat       := as.numeric(substr(raw, 13, 20))]
  dt[, lon       := as.numeric(substr(raw, 22, 30))]
  dt[, element   := trimws(substr(raw, 32, 35))]
  dt[, firstyear := as.integer(substr(raw, 37, 40))]
  dt[, lastyear  := as.integer(substr(raw, 42, 45))]
  dt[, raw := NULL]
  dt
}

# ---- F. GHCNd CSV reader (by-year files) ------------------------------------

read_ghcnd_year_csv = function(csv_path, station_ids = NULL, elements = c("PRCP", "TMAX", "TMIN")) {
  # Columns: ID, DATE, ELEMENT, DATA_VALUE, M_FLAG, Q_FLAG, S_FLAG, OBS_TIME
  # Use cmd to decompress .gz files (avoids R.utils dependency)
  if (grepl("\\.gz$", csv_path)) {
    dt = fread(
      cmd = paste("gzip -dc", shQuote(csv_path)),
      header = FALSE,
      col.names = c("id", "date_int", "element", "value", "m_flag", "q_flag", "s_flag", "obs_time"),
      colClasses = c("character", "integer", "character", "numeric",
                     "character", "character", "character", "character"),
      na.strings = ""
    )
  } else {
    dt = fread(
      csv_path,
      header = FALSE,
      col.names = c("id", "date_int", "element", "value", "m_flag", "q_flag", "s_flag", "obs_time"),
      colClasses = c("character", "integer", "character", "numeric",
                     "character", "character", "character", "character"),
      na.strings = ""
    )
  }

  # Filter to target elements
  dt = dt[element %in% elements]

  # Filter to target stations if provided
  if (!is.null(station_ids) && length(station_ids) > 0) {
    dt = dt[id %in% station_ids]
  }

  # Remove quality-flagged observations (non-blank Q_FLAG)
  dt = dt[is.na(q_flag) | q_flag == ""]

  # Parse date
  dt[, date := as.Date(as.character(date_int), format = "%Y%m%d")]

  # Unit conversions
  # PRCP: tenths of mm -> mm; TMAX/TMIN: tenths of C -> C
  dt[, value := value / 10]

  # Keep only needed columns
  dt[, .(id, date, element, value)]
}

# ---- G. Rolling window functions ---------------------------------------------

rolling_sum = function(x, window) {
  # Compute rolling sum of last 'window' values ending at each position
  # Returns NA if fraction of non-missing values < threshold
  n = length(x)
  if (n < window) return(rep(NA_real_, n))

  out = rep(NA_real_, n)
  for (i in window:n) {
    vals = x[(i - window + 1):i]
    out[i] = sum(vals, na.rm = FALSE)  # strict: any NA -> NA
  }
  out
}

rolling_sum_latest = function(x, window, min_obs_frac = 0.8) {
  # Compute rolling sum for just the latest (last) window
  # Returns NA if too many missing values
  n = length(x)
  if (n < window) return(NA_real_)

  vals = tail(x, window)
  n_valid = sum(!is.na(vals))
  if (n_valid / window < min_obs_frac) return(NA_real_)
  sum(vals, na.rm = TRUE)
}

rolling_mean_latest = function(x, window, min_obs_frac = 0.8) {
  n = length(x)
  if (n < window) return(NA_real_)

  vals = tail(x, window)
  n_valid = sum(!is.na(vals))
  if (n_valid / window < min_obs_frac) return(NA_real_)
  mean(vals, na.rm = TRUE)
}

# ---- H. Climatology window extraction ---------------------------------------

# Extract one aggregated value per reference year for a given DOY and window size.
# This is the core function for building the climatology vector fed to SPI/SPEI.
#
# Arguments:
#   daily_dt   — data.table with columns: date, value (a single variable)
#   ref_date   — Date, the "current" observation date
#   window     — integer, number of days in the accumulation window
#   clim_years — integer vector, the years to include in climatology
#   agg_fn     — function to aggregate (sum for precip, mean for temp)
#   min_obs_frac — minimum fraction of non-NA days required per window
#
# Returns: named numeric vector (names = years) with one value per clim year

extract_clim_vector = function(daily_dt, ref_date, window, clim_years,
                                agg_fn = sum, min_obs_frac = 0.8) {
  ref_doy = as.integer(format(ref_date, "%j"))
  ref_md  = format(ref_date, "%m-%d")

  values = setNames(rep(NA_real_, length(clim_years)), clim_years)

  for (i in seq_along(clim_years)) {
    yr = clim_years[i]

    # Target end date: same month-day in this year
    end_date = tryCatch(
      as.Date(sprintf("%d-%s", yr, ref_md)),
      error = function(e) {
        # Handle Feb 29 in non-leap years
        as.Date(sprintf("%d-02-28", yr))
      }
    )

    start_date = end_date - window + 1L

    # Extract window
    idx = daily_dt$date >= start_date & daily_dt$date <= end_date
    vals = daily_dt$value[idx]

    if (length(vals) < window * 0.5) next  # too few observations even present

    n_valid = sum(!is.na(vals))
    if (n_valid / window < min_obs_frac) next

    values[i] = agg_fn(vals, na.rm = TRUE)
  }

  values
}

# ---- I. Parallel dispatch ----------------------------------------------------

run_parallel = function(items, fn, cores, description = "items") {
  msg(sprintf("Processing %d %s on %d cores", length(items), description, cores))

  if (cores > 1 && requireNamespace("pbmcapply", quietly = TRUE)) {
    results = pbmcapply::pbmclapply(items, fn, mc.cores = cores)
  } else if (cores > 1) {
    results = parallel::mclapply(items, fn, mc.cores = cores)
  } else {
    results = lapply(items, fn)
  }

  # Check for errors in forked workers
  errors = sapply(results, inherits, "try-error")
  if (any(errors)) {
    msg(sprintf("WARNING: %d / %d %s failed", sum(errors), length(items), description))
  }

  results
}

# ---- J. IO helpers -----------------------------------------------------------

safe_download = function(url, dest, quiet = TRUE) {
  tryCatch({
    download.file(url, dest, mode = "wb", quiet = quiet, method = "curl",
                  extra = "-f --retry 3 --retry-delay 5")
    TRUE
  }, error = function(e) {
    msg(sprintf("Download failed: %s — %s", url, conditionMessage(e)))
    FALSE
  })
}

conditional_download = function(url, dest, force = FALSE, max_age_days = NULL) {
  if (!force && file.exists(dest)) {
    if (is.null(max_age_days)) return(TRUE)
    age_days = as.numeric(difftime(Sys.time(), file.info(dest)$mtime, units = "days"))
    if (age_days <= max_age_days) return(TRUE)
  }
  safe_download(url, dest)
}

# Source drought-functions.R
source_drought_functions = function(project_dir) {
  source(file.path(project_dir, "R", "drought-functions.R"))
}
