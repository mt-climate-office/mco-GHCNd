# ============================================================================
# 6_metrics-precip-accum.R — Precipitation accumulations and simple metrics
#
# For each SPI-eligible station, computes:
#   - Raw precipitation total (mm) for each timescale
#   - Percent of normal
#   - Deviation from normal (mm)
#   - Empirical percentile
# ============================================================================

source(file.path(Sys.getenv("PROJECT_DIR",
  file.path(Sys.getenv("HOME"), "mco-GHCNd")), "R", "pipeline-common.R"))

env   = setup_pipeline_env()
paths = setup_pipeline_paths(env)
source_drought_functions(env$PROJECT_DIR)

msg("Step 6: Computing precipitation accumulations")

# ---- Load stations and parse config ------------------------------------------

spi_stations = readRDS(file.path(paths$station_lists, "stations_spi.rds"))
timescales   = parse_timescales(env$TIMESCALES)
clim_periods = parse_clim_periods(env$CLIM_PERIODS)

msg(sprintf("Stations: %d | Timescales: %d", nrow(spi_stations), length(timescales)))

# ---- Compute precip metrics for each station ---------------------------------

compute_precip_for_station = function(sid) {
  tryCatch({
    rds_path = file.path(paths$station_data, sprintf("%s.rds", sid))
    if (!file.exists(rds_path)) return(NULL)

    dt = readRDS(rds_path)
    if (!("prcp" %in% names(dt))) return(NULL)

    valid_dates = dt[!is.na(prcp), date]
    if (length(valid_dates) == 0) return(NULL)
    ref_date = max(valid_dates)

    current_year = as.integer(format(ref_date, "%Y"))

    results = list()

    for (cp in clim_periods) {
      clim_years = get_clim_years(cp, current_year, env$START_YEAR)

      for (ts in timescales) {
        window = ts$get_days(ref_date)
        if (window < 1) next

        ts_label = ts$label
        cp_label = cp$label

        prcp_dt = dt[, .(date, value = prcp)]

        # Current observation (independent of clim_years)
        current_val = compute_current_value(
          prcp_dt, ref_date, window,
          agg_fn = sum, min_obs_frac = env$MIN_OBS_FRACTION
        )

        if (is.na(current_val)) next

        # Reference distribution from clim_years
        clim_vec = extract_clim_vector(
          prcp_dt, ref_date, window, clim_years,
          agg_fn = sum, min_obs_frac = env$MIN_OBS_FRACTION
        )

        clim_vec_clean = clim_vec[!is.na(clim_vec)]
        if (length(clim_vec_clean) < 3) next

        # Raw current accumulation (note: this is NOT the last clim_vec element
        # for fixed:YYYY:YYYY when current year is outside the range)
        results[[paste0("precip_mm_", ts_label, "_", cp_label)]] = current_val

        results[[paste0("precip_pon_", ts_label, "_", cp_label)]] =
          percent_of_normal(clim_vec_clean, current_val,
                            climatology_length = length(clim_vec_clean))

        results[[paste0("precip_dev_", ts_label, "_", cp_label)]] =
          deviation_from_normal(clim_vec_clean, current_val,
                                climatology_length = length(clim_vec_clean))

        results[[paste0("precip_pctile_", ts_label, "_", cp_label)]] =
          compute_percentile(clim_vec_clean, current_val,
                             climatology_length = length(clim_vec_clean))
      }
    }

    results$station_id = sid
    results$last_obs_date = as.character(ref_date)
    return(results)

  }, error = function(e) {
    return(NULL)
  })
}

precip_results = run_parallel(
  spi_stations$id,
  compute_precip_for_station,
  cores = env$CORES,
  description = "stations (precip accum)"
)

# ---- Collect results ---------------------------------------------------------

precip_results = precip_results[!sapply(precip_results, is.null)]

if (length(precip_results) > 0) {
  precip_dt = rbindlist(lapply(precip_results, as.data.table), fill = TRUE)
  saveRDS(precip_dt, file.path(paths$derived_dir, "precip_accum_results.rds"))
  msg(sprintf("Step 6 complete: Precip metrics computed for %d stations", nrow(precip_dt)))
} else {
  msg("WARNING: No precip accumulation results produced")
}
