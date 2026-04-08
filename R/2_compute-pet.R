# ============================================================================
# 2_compute-pet.R — Compute daily Hargreaves-Samani ET0
#
# For SPEI-eligible stations (TMAX + TMIN), computes daily reference
# evapotranspiration using the Hargreaves-Samani method with FAO-56
# extraterrestrial radiation equations. Saves updated station RDS files
# with a 'pet' column.
# ============================================================================

source(file.path(Sys.getenv("PROJECT_DIR",
  file.path(Sys.getenv("HOME"), "mco-GHCNd")), "R", "pipeline-common.R"))

env   = setup_pipeline_env()
paths = setup_pipeline_paths(env)
source_drought_functions(env$PROJECT_DIR)

msg("Step 2: Computing Hargreaves-Samani daily ET0")

# ---- Load SPEI station list --------------------------------------------------

spei_stations = readRDS(file.path(paths$station_lists, "stations_spei.rds"))
msg(sprintf("SPEI-eligible stations: %d", nrow(spei_stations)))

# ---- Process each station ----------------------------------------------------

compute_pet_for_station = function(sid) {
  tryCatch({
    rds_path = file.path(paths$station_data, sprintf("%s.rds", sid))
    if (!file.exists(rds_path)) return(NULL)

    dt = readRDS(rds_path)

    # Get station latitude
    stn_meta = spei_stations[id == sid]
    if (nrow(stn_meta) == 0 || is.na(stn_meta$lat[1])) return(NULL)
    lat = stn_meta$lat[1]

    # Compute day of year
    doy = as.integer(format(dt$date, "%j"))

    # Compute daily ET0 (mm/day) via Hargreaves-Samani
    dt[, pet := hargreaves_samani_daily(tmax, tmin, lat, doy)]

    # Save updated RDS
    saveRDS(dt, rds_path)
    return(sid)
  }, error = function(e) {
    return(NULL)
  })
}

results = run_parallel(
  spei_stations$id,
  compute_pet_for_station,
  cores = env$CORES,
  description = "stations (PET)"
)

n_success = sum(!sapply(results, is.null))
msg(sprintf("Step 2 complete: PET computed for %d / %d stations", n_success, nrow(spei_stations)))
