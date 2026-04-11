# ============================================================================
# 3_metrics-spi.R — Compute SPI for all precipitation stations
#
# For each SPI-eligible station, computes SPI at all timescales using
# L-moment gamma fit with Stagge et al. (2015) zero handling.
# ============================================================================

source(file.path(Sys.getenv("PROJECT_DIR",
  file.path(Sys.getenv("HOME"), "mco-GHCNd")), "R", "pipeline-common.R"))

env   = setup_pipeline_env()
paths = setup_pipeline_paths(env)
source_drought_functions(env$PROJECT_DIR)

msg("Step 3: Computing SPI")

# ---- Load stations and parse config ------------------------------------------

spi_stations = readRDS(file.path(paths$station_lists, "stations_spi.rds"))
timescales   = parse_timescales(env$TIMESCALES)
clim_periods = parse_clim_periods(env$CLIM_PERIODS)

msg(sprintf("Stations: %d | Timescales: %d | Clim periods: %d",
            nrow(spi_stations), length(timescales), length(clim_periods)))

# ---- Compute SPI for each station --------------------------------------------

compute_spi_for_station = function(sid) {
  tryCatch({
    rds_path = file.path(paths$station_data, sprintf("%s.rds", sid))
    if (!file.exists(rds_path))
      return(list(station_id = sid, skip_reason = "no RDS file"))

    dt = readRDS(rds_path)
    if (!("prcp" %in% names(dt)))
      return(list(station_id = sid, skip_reason = "no PRCP column in data"))

    # Find the latest date with a valid PRCP observation
    valid_dates = dt[!is.na(prcp), date]
    if (length(valid_dates) == 0)
      return(list(station_id = sid, skip_reason = "all PRCP values are NA"))
    ref_date = max(valid_dates)

    # Check data freshness
    days_since = as.integer(Sys.Date() - ref_date)
    if (days_since > env$MAX_REPORTING_LATENCY)
      return(list(station_id = sid, skip_reason = sprintf(
        "last obs %s (%d days ago, max %d)", ref_date, days_since, env$MAX_REPORTING_LATENCY)))

    current_year = as.integer(format(ref_date, "%Y"))
    n_total_days = nrow(dt)
    n_valid_prcp = sum(!is.na(dt$prcp))

    results = list()
    na_reasons = character(0)

    for (cp in clim_periods) {
      clim_years = get_clim_years(cp, current_year, env$START_YEAR)

      for (ts in timescales) {
        window = ts$get_days(ref_date)
        if (window < 1) next

        label = paste0("spi_", ts$label, "_", cp$label)

        prcp_dt = dt[, .(date, value = prcp)]
        clim_vec = extract_clim_vector(
          prcp_dt, ref_date, window, clim_years,
          agg_fn = sum, min_obs_frac = env$MIN_OBS_FRACTION
        )

        clim_vec_clean = clim_vec[!is.na(clim_vec)]
        n_avail = length(clim_vec_clean)
        n_total = length(clim_vec)

        if (n_avail < 3) {
          results[[label]] = NA_real_
          na_reasons = c(na_reasons, sprintf(
            "%s: only %d/%d valid clim years (missing data in %dd windows)",
            label, n_avail, n_total, window))
          next
        }

        spi_val = gamma_fit_spi(clim_vec_clean,
                                export_opts = "SPI",
                                return_latest = TRUE,
                                climatology_length = length(clim_vec_clean))

        results[[label]] = spi_val
      }
    }

    results$station_id = sid
    results$last_obs_date = as.character(ref_date)
    results$skip_reason = NA_character_
    if (length(na_reasons) > 0) results$na_details = paste(na_reasons, collapse = "; ")
    return(results)

  }, error = function(e) {
    return(list(station_id = sid, skip_reason = sprintf("error: %s", conditionMessage(e))))
  })
}

spi_results = run_parallel(
  spi_stations$id,
  compute_spi_for_station,
  cores = env$CORES,
  description = "stations (SPI)"
)

# ---- Collect results and log diagnostics -------------------------------------

spi_results = spi_results[!sapply(spi_results, is.null)]

# Separate successes from skips
skipped = spi_results[sapply(spi_results, function(r) {
  !is.null(r$skip_reason) && !is.na(r$skip_reason)
})]
computed = spi_results[sapply(spi_results, function(r) {
  is.null(r$skip_reason) || is.na(r$skip_reason)
})]

# Log skip reasons
if (length(skipped) > 0) {
  msg(sprintf("SPI skipped for %d stations:", length(skipped)))
  skip_reasons = sapply(skipped, function(r) r$skip_reason)
  reason_table = table(skip_reasons)
  for (reason in names(reason_table)) {
    msg(sprintf("  %d stations: %s", reason_table[[reason]], reason))
  }
}

if (length(computed) > 0) {
  spi_dt = rbindlist(lapply(computed, function(r) {
    r$skip_reason = NULL
    r$na_details = NULL
    as.data.table(r)
  }), fill = TRUE)
  saveRDS(spi_dt, file.path(paths$derived_dir, "spi_results.rds"))

  # Log NA details for stations that computed but had some NA timescales
  na_stations = computed[sapply(computed, function(r) !is.null(r$na_details))]
  if (length(na_stations) > 0) {
    msg(sprintf("SPI partial results (%d stations had some NA timescales):", length(na_stations)))
    for (r in na_stations[1:min(5, length(na_stations))]) {
      msg(sprintf("  %s: %s", r$station_id, r$na_details))
    }
    if (length(na_stations) > 5) msg(sprintf("  ... and %d more", length(na_stations) - 5))
  }

  msg(sprintf("Step 3 complete: SPI computed for %d / %d stations",
              nrow(spi_dt), nrow(spi_stations)))
} else {
  msg("WARNING: No SPI results produced")
}
