# ============================================================================
# 0_ghcnd-station-filter.R — Identify active GHCNd stations
#
# Downloads ghcnd-inventory.txt and ghcnd-stations.txt, filters for stations
# that are currently reporting and have sufficient history for climatology.
# Outputs: stations_spi.rds (PRCP) and stations_spei.rds (PRCP+TMAX+TMIN)
# ============================================================================

source(file.path(Sys.getenv("PROJECT_DIR",
  file.path(Sys.getenv("HOME"), "mco-GHCNd")), "R", "pipeline-common.R"))

env   = setup_pipeline_env()
paths = setup_pipeline_paths(env)
source_drought_functions(env$PROJECT_DIR)

msg("Step 0: Filtering GHCNd stations")

# ---- Download metadata files -------------------------------------------------

msg("Downloading ghcnd-stations.txt")
safe_download(paste0(NCEI_BASE, "/ghcnd-stations.txt"), paths$stations_file)

msg("Downloading ghcnd-inventory.txt")
safe_download(paste0(NCEI_BASE, "/ghcnd-inventory.txt"), paths$inventory_file)

# ---- Parse metadata ----------------------------------------------------------

stations = read_ghcnd_stations(paths$stations_file)
inventory = read_ghcnd_inventory(paths$inventory_file)

current_year = as.integer(format(Sys.Date(), "%Y"))
min_last_year = current_year - 1L  # must have reported within the last year

msg(sprintf("Current year: %d | Min last year: %d | Min clim years: %d",
            current_year, min_last_year, env$MIN_CLIM_YEARS))

# ---- Filter for SPI-eligible stations (PRCP) ---------------------------------

prcp_inv = inventory[element == "PRCP"]
prcp_inv = prcp_inv[lastyear >= min_last_year]
prcp_inv = prcp_inv[(lastyear - firstyear + 1L) >= env$MIN_CLIM_YEARS]

# ---- Filter for SPEI-eligible stations (PRCP + TMAX + TMIN) ------------------

tmax_inv = inventory[element == "TMAX" & lastyear >= min_last_year &
                     (lastyear - firstyear + 1L) >= env$MIN_CLIM_YEARS]
tmin_inv = inventory[element == "TMIN" & lastyear >= min_last_year &
                     (lastyear - firstyear + 1L) >= env$MIN_CLIM_YEARS]

# Stations that have all three elements
spei_ids = intersect(prcp_inv$id, intersect(tmax_inv$id, tmin_inv$id))

# ---- Apply CONUS filter (default) or optional country filter -----------------
# CONUS bounding box: 24.5-49.5°N, -125 to -66.5°W
# Filters to US stations within continental bounds (excludes AK, HI, territories)

if (nchar(env$COUNTRY_FILTER) > 0) {
  # Custom country filter overrides CONUS default
  countries = trimws(strsplit(env$COUNTRY_FILTER, ",")[[1]])
  msg(sprintf("Applying country filter: %s", paste(countries, collapse = ", ")))
  prcp_inv = prcp_inv[substr(id, 1, 2) %in% countries]
  spei_ids = spei_ids[substr(spei_ids, 1, 2) %in% countries]
} else {
  # Default: CONUS only
  msg("Applying CONUS filter (US stations, 24.5-49.5°N, 125-66.5°W)")
  conus_ids = stations[substr(id, 1, 2) == "US" &
                       lat >= 24.5 & lat <= 49.5 &
                       lon >= -125 & lon <= -66.5, id]
  prcp_inv = prcp_inv[id %in% conus_ids]
  spei_ids = spei_ids[spei_ids %in% conus_ids]
  msg(sprintf("  CONUS stations in metadata: %d", length(conus_ids)))
}

# ---- Apply optional station ID subset ----------------------------------------

if (nchar(env$STATION_IDS) > 0) {
  subset_ids = trimws(strsplit(env$STATION_IDS, ",")[[1]])
  msg(sprintf("Applying station subset: %d stations", length(subset_ids)))

  prcp_inv = prcp_inv[id %in% subset_ids]
  spei_ids = spei_ids[spei_ids %in% subset_ids]
}

# ---- Apply optional MAX_STATIONS cap (for testing) ---------------------------

max_stations = as.integer(Sys.getenv("MAX_STATIONS", "0"))
if (max_stations > 0 && nrow(prcp_inv) > max_stations) {
  msg(sprintf("MAX_STATIONS=%d — sampling from %d SPI-eligible stations", max_stations, nrow(prcp_inv)))
  set.seed(42)  # reproducible subset
  sampled_ids = sample(prcp_inv$id, max_stations)
  prcp_inv = prcp_inv[id %in% sampled_ids]
  spei_ids = spei_ids[spei_ids %in% sampled_ids]
}

# ---- Join with station metadata ----------------------------------------------

spi_stations = merge(prcp_inv[, .(id, firstyear, lastyear)],
                     stations, by = "id", all.x = TRUE)

spei_stations = merge(
  data.table(id = spei_ids),
  stations, by = "id", all.x = TRUE
)

# Add firstyear info for SPEI stations from PRCP inventory
spei_prcp = prcp_inv[id %in% spei_ids, .(id, prcp_firstyear = firstyear, prcp_lastyear = lastyear)]
spei_stations = merge(spei_stations, spei_prcp, by = "id", all.x = TRUE)

msg(sprintf("SPI-eligible stations: %d", nrow(spi_stations)))
msg(sprintf("SPEI-eligible stations: %d", nrow(spei_stations)))

# ---- Save station lists ------------------------------------------------------

saveRDS(spi_stations, file.path(paths$station_lists, "stations_spi.rds"))
saveRDS(spei_stations, file.path(paths$station_lists, "stations_spei.rds"))

msg("Step 0 complete: station lists saved")
