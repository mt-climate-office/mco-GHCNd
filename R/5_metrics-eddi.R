# ============================================================================
# 5_metrics-eddi.R — Compute EDDI for stations with PET
#
# Evaporative Demand Drought Index: nonparametric rank-based index
# computed from accumulated PET. Positive EDDI = drought (high demand).
# Following Hobbins et al. (2016).
# ============================================================================

source(file.path(Sys.getenv("PROJECT_DIR",
  file.path(Sys.getenv("HOME"), "mco-GHCNd")), "R", "pipeline-common.R"))

env   = setup_pipeline_env()
paths = setup_pipeline_paths(env)
source_drought_functions(env$PROJECT_DIR)

msg("Step 5: Computing EDDI")

# ---- Load stations and parse config ------------------------------------------

spei_stations = readRDS(file.path(paths$station_lists, "stations_spei.rds"))
timescales    = parse_timescales(env$TIMESCALES)
clim_periods  = parse_clim_periods(env$CLIM_PERIODS)

msg(sprintf("Stations: %d | Timescales: %d | Clim periods: %d",
            nrow(spei_stations), length(timescales), length(clim_periods)))

# ---- Compute EDDI for each station -------------------------------------------

compute_eddi_for_station = function(sid) {
  tryCatch({
    rds_path = file.path(paths$station_data, sprintf("%s.rds", sid))
    if (!file.exists(rds_path))
      return(list(station_id = sid, skip_reason = "no RDS file"))

    dt = readRDS(rds_path)
    if (!("pet" %in% names(dt)))
      return(list(station_id = sid, skip_reason = "no PET column"))

    valid_dates = dt[!is.na(pet), date]
    if (length(valid_dates) == 0)
      return(list(station_id = sid, skip_reason = "all PET values are NA"))
    ref_date = max(valid_dates)

    days_since = as.integer(Sys.Date() - ref_date)
    if (days_since > env$MAX_REPORTING_LATENCY)
      return(list(station_id = sid, skip_reason = sprintf(
        "last obs %s (%d days ago)", ref_date, days_since)))

    current_year = as.integer(format(ref_date, "%Y"))

    results = list()
    na_reasons = character(0)

    for (cp in clim_periods) {
      clim_years = get_clim_years(cp, current_year, env$START_YEAR)

      for (ts in timescales) {
        window = ts$get_days(ref_date)
        if (window < 1) next

        label = paste0("eddi_", ts$label, "_", cp$label)

        pet_dt = dt[, .(date, value = pet)]
        clim_vec = extract_clim_vector(
          pet_dt, ref_date, window, clim_years,
          agg_fn = sum, min_obs_frac = env$MIN_OBS_FRACTION
        )

        clim_vec_clean = clim_vec[!is.na(clim_vec)]
        n_avail = length(clim_vec_clean)
        n_total = length(clim_vec)

        if (n_avail < 3) {
          results[[label]] = NA_real_
          na_reasons = c(na_reasons, sprintf(
            "%s: only %d/%d valid clim years", label, n_avail, n_total))
          next
        }

        eddi_val = nonparam_fit_eddi(clim_vec_clean,
                                     climatology_length = length(clim_vec_clean))

        results[[label]] = eddi_val
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

eddi_results = run_parallel(
  spei_stations$id,
  compute_eddi_for_station,
  cores = env$CORES,
  description = "stations (EDDI)"
)

# ---- Collect results and log diagnostics -------------------------------------

eddi_results = eddi_results[!sapply(eddi_results, is.null)]

skipped = eddi_results[sapply(eddi_results, function(r) {
  !is.null(r$skip_reason) && !is.na(r$skip_reason)
})]
computed = eddi_results[sapply(eddi_results, function(r) {
  is.null(r$skip_reason) || is.na(r$skip_reason)
})]

if (length(skipped) > 0) {
  msg(sprintf("EDDI skipped for %d stations:", length(skipped)))
  skip_reasons = sapply(skipped, function(r) r$skip_reason)
  reason_table = table(skip_reasons)
  for (reason in names(reason_table)) {
    msg(sprintf("  %d stations: %s", reason_table[[reason]], reason))
  }
}

if (length(computed) > 0) {
  eddi_dt = rbindlist(lapply(computed, function(r) {
    r$skip_reason = NULL
    r$na_details = NULL
    as.data.table(r)
  }), fill = TRUE)
  saveRDS(eddi_dt, file.path(paths$derived_dir, "eddi_results.rds"))
  msg(sprintf("Step 5 complete: EDDI computed for %d / %d stations",
              nrow(eddi_dt), nrow(spei_stations)))
} else {
  msg("WARNING: No EDDI results produced")
}
