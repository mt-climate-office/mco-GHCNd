# ============================================================================
# 7_output-assembly.R — Assemble final outputs
#
# Combines SPI, SPEI, EDDI, and precip accumulation results into:
#   - Per-station JSON files
#   - Summary GeoJSON (all stations)
#   - Summary CSV (all stations)
#   - Station catalog
#   - Manifest
# ============================================================================

source(file.path(Sys.getenv("PROJECT_DIR",
  file.path(Sys.getenv("HOME"), "mco-GHCNd")), "R", "pipeline-common.R"))

library(jsonlite)
library(sf)

env   = setup_pipeline_env()
paths = setup_pipeline_paths(env)

msg("Step 7: Assembling outputs")

# ---- Load all results --------------------------------------------------------

spi_stations  = readRDS(file.path(paths$station_lists, "stations_spi.rds"))
spei_stations = readRDS(file.path(paths$station_lists, "stations_spei.rds"))

spi_dt = if (file.exists(file.path(paths$derived_dir, "spi_results.rds"))) {
  readRDS(file.path(paths$derived_dir, "spi_results.rds"))
} else data.table()

spei_dt = if (file.exists(file.path(paths$derived_dir, "spei_results.rds"))) {
  readRDS(file.path(paths$derived_dir, "spei_results.rds"))
} else data.table()

eddi_dt = if (file.exists(file.path(paths$derived_dir, "eddi_results.rds"))) {
  readRDS(file.path(paths$derived_dir, "eddi_results.rds"))
} else data.table()

precip_dt = if (file.exists(file.path(paths$derived_dir, "precip_accum_results.rds"))) {
  readRDS(file.path(paths$derived_dir, "precip_accum_results.rds"))
} else data.table()

# ---- Parse timescales and clim periods for column grouping -------------------

timescales   = parse_timescales(env$TIMESCALES)
clim_periods = parse_clim_periods(env$CLIM_PERIODS)

# ---- Generate per-station JSON files -----------------------------------------

msg("Writing per-station JSON files")

all_spi_ids   = if (nrow(spi_dt) > 0) spi_dt$station_id else character(0)
all_spei_ids  = if (nrow(spei_dt) > 0) spei_dt$station_id else character(0)
all_eddi_ids  = if (nrow(eddi_dt) > 0) eddi_dt$station_id else character(0)
all_ids       = unique(c(all_spi_ids, all_spei_ids, all_eddi_ids))

json_count = 0L

for (sid in all_ids) {
  # Station metadata
  meta = spi_stations[id == sid]
  if (nrow(meta) == 0) meta = spei_stations[id == sid]
  if (nrow(meta) == 0) next

  station_json = list(
    station_id = sid,
    name       = meta$name[1],
    lat        = meta$lat[1],
    lon        = meta$lon[1],
    elevation  = meta$elev[1],
    state      = meta$state[1]
  )

  # Determine what indices are available
  has_spi  = sid %in% all_spi_ids
  has_spei = sid %in% all_spei_ids
  has_eddi = sid %in% all_eddi_ids
  station_json$indices_available = c(
    if (has_spi) "spi",
    if (has_spei) "spei",
    if (has_eddi) "eddi"
  )

  # For each clim period, build metric objects
  for (cp in clim_periods) {
    cp_label = cp$label

    # SPI
    if (has_spi) {
      spi_row = spi_dt[station_id == sid]
      if (nrow(spi_row) > 0) {
        station_json$last_obs_date = spi_row$last_obs_date[1]
        spi_obj = list()
        for (ts in timescales) {
          col = paste0("spi_", ts$label, "_", cp_label)
          if (col %in% names(spi_row)) {
            val = spi_row[[col]][1]
            if (!is.na(val)) spi_obj[[ts$label]] = round(val, 2)
          }
        }
        station_json$spi = spi_obj
      }
    }

    # SPEI
    if (has_spei) {
      spei_row = spei_dt[station_id == sid]
      if (nrow(spei_row) > 0) {
        spei_obj = list()
        for (ts in timescales) {
          col = paste0("spei_", ts$label, "_", cp_label)
          if (col %in% names(spei_row)) {
            val = spei_row[[col]][1]
            if (!is.na(val)) spei_obj[[ts$label]] = round(val, 2)
          }
        }
        station_json$spei = spei_obj
      }
    }

    # EDDI
    if (has_eddi) {
      eddi_row = eddi_dt[station_id == sid]
      if (nrow(eddi_row) > 0) {
        eddi_obj = list()
        for (ts in timescales) {
          col = paste0("eddi_", ts$label, "_", cp_label)
          if (col %in% names(eddi_row)) {
            val = eddi_row[[col]][1]
            if (!is.na(val)) eddi_obj[[ts$label]] = round(val, 2)
          }
        }
        station_json$eddi = eddi_obj
      }
    }

    # Precip accumulations
    if (has_spi && nrow(precip_dt) > 0) {
      precip_row = precip_dt[station_id == sid]
      if (nrow(precip_row) > 0) {
        mm_obj = list(); pon_obj = list(); pctile_obj = list()
        for (ts in timescales) {
          mm_col     = paste0("precip_mm_", ts$label, "_", cp_label)
          pon_col    = paste0("precip_pon_", ts$label, "_", cp_label)
          pctile_col = paste0("precip_pctile_", ts$label, "_", cp_label)

          if (mm_col %in% names(precip_row)) {
            val = precip_row[[mm_col]][1]
            if (!is.na(val)) mm_obj[[ts$label]] = round(val, 1)
          }
          if (pon_col %in% names(precip_row)) {
            val = precip_row[[pon_col]][1]
            if (!is.na(val)) pon_obj[[ts$label]] = round(val, 1)
          }
          if (pctile_col %in% names(precip_row)) {
            val = precip_row[[pctile_col]][1]
            if (!is.na(val)) pctile_obj[[ts$label]] = round(val, 3)
          }
        }
        station_json$precip_mm          = mm_obj
        station_json$precip_pct_normal  = pon_obj
        station_json$precip_percentile  = pctile_obj
      }
    }
  }

  station_json$data_date = as.character(Sys.Date())

  # Write JSON
  json_path = file.path(paths$stations_out, sprintf("%s.json", sid))
  write_json(station_json, json_path, auto_unbox = TRUE, pretty = TRUE)
  json_count = json_count + 1L
}

msg(sprintf("Wrote %d per-station JSON files", json_count))

# ---- Generate summary CSV ----------------------------------------------------

msg("Writing summary CSV")

# Merge all results with station metadata
summary_dt = spi_stations[, .(id, name, lat, lon, elev, state)]

if (nrow(spi_dt) > 0) {
  spi_merge = copy(spi_dt)
  setnames(spi_merge, "station_id", "id")
  spi_obs = spi_merge[, .(id, spi_last_obs = last_obs_date)]
  spi_merge[, last_obs_date := NULL]
  summary_dt = merge(summary_dt, spi_merge, by = "id", all.x = TRUE)
  summary_dt = merge(summary_dt, spi_obs, by = "id", all.x = TRUE)
}

if (nrow(spei_dt) > 0) {
  spei_merge = copy(spei_dt)
  setnames(spei_merge, "station_id", "id")
  spei_merge[, last_obs_date := NULL]
  summary_dt = merge(summary_dt, spei_merge, by = "id", all.x = TRUE)
}

if (nrow(eddi_dt) > 0) {
  eddi_merge = copy(eddi_dt)
  setnames(eddi_merge, "station_id", "id")
  eddi_merge[, last_obs_date := NULL]
  summary_dt = merge(summary_dt, eddi_merge, by = "id", all.x = TRUE)
}

if (nrow(precip_dt) > 0) {
  precip_merge = copy(precip_dt)
  setnames(precip_merge, "station_id", "id")
  precip_merge[, last_obs_date := NULL]
  summary_dt = merge(summary_dt, precip_merge, by = "id", all.x = TRUE)
}

fwrite(summary_dt, file.path(paths$derived_dir, "all_stations.csv"))

# ---- Generate summary GeoJSON -----------------------------------------------

msg("Writing summary GeoJSON")

# Filter to stations with valid coordinates
geo_dt = summary_dt[!is.na(lat) & !is.na(lon)]

if (nrow(geo_dt) > 0) {
  geo_sf = st_as_sf(geo_dt, coords = c("lon", "lat"), crs = 4326)
  st_write(geo_sf, file.path(paths$derived_dir, "all_stations.geojson"),
           driver = "GeoJSON", delete_dsn = TRUE, quiet = TRUE)
  msg(sprintf("GeoJSON: %d features", nrow(geo_sf)))
} else {
  msg("WARNING: No stations with valid coordinates for GeoJSON")
}

# ---- Generate station catalog ------------------------------------------------

msg("Writing station catalog")

catalog = spi_stations[, .(id, name, lat, lon, elev, state, firstyear, lastyear)]
catalog[, has_spi := id %in% all_spi_ids]
catalog[, has_spei := id %in% all_spei_ids]
catalog[, has_eddi := id %in% all_eddi_ids]

if (nrow(spi_dt) > 0) {
  obs_dates = spi_dt[, .(id = station_id, last_obs_date)]
  catalog = merge(catalog, obs_dates, by = "id", all.x = TRUE)
}

fwrite(catalog, file.path(paths$derived_dir, "station_catalog.csv"))

# ---- Write manifest ----------------------------------------------------------

msg("Writing manifest")

data_date = as.character(Sys.Date())

manifest = data.table(
  dataset = c("updated", "spi", "spei", "eddi", "precip_accum"),
  date = c(
    data_date,
    if (nrow(spi_dt) > 0) data_date else "",
    if (nrow(spei_dt) > 0) data_date else "",
    if (nrow(eddi_dt) > 0) data_date else "",
    if (nrow(precip_dt) > 0) data_date else ""
  )
)

fwrite(manifest, file.path(paths$derived_dir, "manifest.csv"))
writeLines(data_date, file.path(paths$derived_dir, "latest-date.txt"))

msg(sprintf("Step 7 complete: %d JSON, CSV, GeoJSON, catalog, manifest written", json_count))
