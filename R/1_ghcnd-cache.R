# ============================================================================
# 1_ghcnd-cache.R — Download and parse GHCNd by-year CSV data
#
# Cold start (no per-station RDS files): downloads all years, parses all,
#   saves per-station RDS files. Also saves a filtered station CSV per year
#   so future cold starts are faster.
#
# Warm start (RDS files exist): only downloads current year + prior year
#   if stale, parses just those, updates per-station RDS files.
# ============================================================================

source(file.path(Sys.getenv("PROJECT_DIR",
  file.path(Sys.getenv("HOME"), "mco-GHCNd")), "R", "pipeline-common.R"))

env   = setup_pipeline_env()
paths = setup_pipeline_paths(env)

msg("Step 1: Caching GHCNd data")

# ---- Load station lists ------------------------------------------------------

spi_stations  = readRDS(file.path(paths$station_lists, "stations_spi.rds"))
spei_stations = readRDS(file.path(paths$station_lists, "stations_spei.rds"))
all_station_ids = unique(c(spi_stations$id, spei_stations$id))

msg(sprintf("Target stations: %d", length(all_station_ids)))

current_year = as.integer(format(Sys.Date(), "%Y"))
all_years = seq(env$START_YEAR, current_year)

# ---- Detect cold vs warm start -----------------------------------------------
# Warm start: per-station RDS files already exist for most stations

existing_rds = list.files(paths$station_data, pattern = "\\.rds$", full.names = FALSE)
existing_ids = sub("\\.rds$", "", existing_rds)
n_existing = sum(all_station_ids %in% existing_ids)
warm_start = n_existing > (length(all_station_ids) * 0.5)

if (warm_start) {
  msg(sprintf("WARM START: %d / %d stations have existing RDS files", n_existing, length(all_station_ids)))
  msg("  Only downloading current year + prior year")
  years_to_download = c(current_year - 1L, current_year)
  years_to_parse = years_to_download
} else {
  msg(sprintf("COLD START: %d / %d stations have existing RDS files", n_existing, length(all_station_ids)))
  msg("  Downloading all years")
  years_to_download = all_years
  years_to_parse = all_years
}

# ---- Download by-year CSV.gz files -------------------------------------------

msg(sprintf("Downloading CSV files for %d year(s)", length(years_to_download)))

for (yr in years_to_download) {
  dest = file.path(paths$csv_dir, sprintf("%d.csv.gz", yr))
  url  = sprintf("%s/by_year/%d.csv.gz", NCEI_BASE, yr)

  if (yr == current_year) {
    msg(sprintf("  %d (current year — always refresh)", yr))
    safe_download(url, dest)
  } else if (yr >= current_year - 1L) {
    # Prior year: re-download if older than 7 days
    conditional_download(url, dest, max_age_days = 7)
  } else {
    # Historical years: skip if file exists
    conditional_download(url, dest)
  }
}

# ---- Helper: parse one year CSV and return wide data.table -------------------

parse_year_csv = function(yr, station_ids) {
  csv_path = file.path(paths$csv_dir, sprintf("%d.csv.gz", yr))
  if (!file.exists(csv_path)) {
    msg(sprintf("  WARNING: Missing CSV for %d, skipping", yr))
    return(NULL)
  }

  msg(sprintf("  Reading %d.csv.gz", yr))

  dt = tryCatch(
    read_ghcnd_year_csv(csv_path, station_ids = station_ids,
                        elements = c("PRCP", "TMAX", "TMIN")),
    error = function(e) {
      msg(sprintf("  ERROR reading %d: %s", yr, conditionMessage(e)))
      NULL
    }
  )

  if (is.null(dt) || nrow(dt) == 0) return(NULL)

  # Pivot to wide: one row per station-date
  dt_wide = dcast(dt, id + date ~ element, value.var = "value", fun.aggregate = mean)

  # Standardize column names to lowercase
  for (col in c("PRCP", "TMAX", "TMIN")) {
    if (col %in% names(dt_wide)) setnames(dt_wide, col, tolower(col))
  }

  dt_wide
}

# ---- Helper: finalize and save a station's data.table to RDS -----------------

save_station_rds = function(dt, sid) {
  setorder(dt, date)
  dt = unique(dt, by = "date")
  if (nrow(dt) < 2) return(FALSE)

  all_dates = data.table(date = seq(min(dt$date), max(dt$date), by = "day"))
  dt = merge(all_dates, dt, by = "date", all.x = TRUE)

  for (col in c("prcp", "tmax", "tmin")) {
    if (!col %in% names(dt)) dt[, (col) := NA_real_]
  }

  saveRDS(dt, file.path(paths$station_data, sprintf("%s.rds", sid)))
  TRUE
}

# ---- COLD START: parse all years, append to per-station RDS on disk ----------
# Processes one year at a time and appends to per-station RDS files on disk
# to avoid holding all years x all stations in memory.

if (!warm_start) {
  msg("Parsing all CSV files (cold start — streaming to disk)")

  for (yr in years_to_parse) {
    dt_wide = parse_year_csv(yr, all_station_ids)
    if (is.null(dt_wide)) next

    # Split by station and append to per-station RDS files
    ids_in_year = unique(dt_wide$id)
    for (sid in ids_in_year) {
      chunk = dt_wide[id == sid]
      chunk[, id := NULL]

      rds_path = file.path(paths$station_data, sprintf("%s.rds", sid))
      if (file.exists(rds_path)) {
        existing = readRDS(rds_path)
        chunk = rbindlist(list(existing, chunk), fill = TRUE)
        rm(existing)
      }

      # Save incrementally (unsorted/unfilled — finalized after all years)
      saveRDS(chunk, rds_path)
    }

    rm(dt_wide)
    gc(verbose = FALSE)
  }

  # Finalize all station RDS files (sort, dedup, fill date gaps)
  msg("Finalizing per-station RDS files")
  all_rds = list.files(paths$station_data, pattern = "\\.rds$", full.names = TRUE)
  saved = 0L
  for (rds_path in all_rds) {
    sid = sub("\\.rds$", "", basename(rds_path))
    dt = readRDS(rds_path)
    if (save_station_rds(dt, sid)) saved = saved + 1L
  }

  msg(sprintf("Step 1 complete (cold): %d station RDS files saved", saved))

} else {

  # ---- WARM START: parse only recent years, update existing RDS ----------------

  msg("Parsing recent CSV files (warm start)")

  # Collect new data from recent years
  new_data = list()

  for (yr in years_to_parse) {
    dt_wide = parse_year_csv(yr, all_station_ids)
    if (is.null(dt_wide)) next

    ids_in_year = unique(dt_wide$id)
    for (sid in ids_in_year) {
      chunk = dt_wide[id == sid]
      chunk[, id := NULL]
      if (sid %in% names(new_data)) {
        new_data[[sid]] = rbindlist(list(new_data[[sid]], chunk), fill = TRUE)
      } else {
        new_data[[sid]] = chunk
      }
    }

    rm(dt_wide)
  }

  msg(sprintf("Updating %d stations with new data", length(new_data)))

  updated = 0L
  created = 0L

  for (sid in names(new_data)) {
    rds_path = file.path(paths$station_data, sprintf("%s.rds", sid))

    if (file.exists(rds_path)) {
      # Merge new data into existing RDS
      existing = readRDS(rds_path)

      # Remove old data for the years we re-parsed (replace with fresh)
      new_dates = new_data[[sid]]$date
      min_new = min(new_dates)
      existing = existing[date < min_new]

      combined = rbindlist(list(existing, new_data[[sid]]), fill = TRUE)

      if (save_station_rds(combined, sid)) updated = updated + 1L
    } else {
      # New station not previously seen — need full history
      # For warm start, we only have recent years, so this station gets partial data
      if (save_station_rds(new_data[[sid]], sid)) created = created + 1L
    }
  }

  rm(new_data)
  gc(verbose = FALSE)

  msg(sprintf("Step 1 complete (warm): %d updated, %d created", updated, created))
}
