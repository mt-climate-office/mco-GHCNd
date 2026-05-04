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
  setnames(spi_merge, "last_obs_date", "spi_last_obs")
  summary_dt = merge(summary_dt, spi_merge, by = "id", all.x = TRUE)
}

if (nrow(spei_dt) > 0) {
  spei_merge = copy(spei_dt)
  setnames(spei_merge, "station_id", "id")
  setnames(spei_merge, "last_obs_date", "spei_last_obs")
  summary_dt = merge(summary_dt, spei_merge, by = "id", all.x = TRUE)
}

if (nrow(eddi_dt) > 0) {
  eddi_merge = copy(eddi_dt)
  setnames(eddi_merge, "station_id", "id")
  setnames(eddi_merge, "last_obs_date", "eddi_last_obs")
  summary_dt = merge(summary_dt, eddi_merge, by = "id", all.x = TRUE)
}

if (nrow(precip_dt) > 0) {
  precip_merge = copy(precip_dt)
  setnames(precip_merge, "station_id", "id")
  setnames(precip_merge, "last_obs_date", "precip_last_obs")
  summary_dt = merge(summary_dt, precip_merge, by = "id", all.x = TRUE)
}

# Add pipeline run date
summary_dt[, data_date := as.character(Sys.Date())]

fwrite(summary_dt, file.path(paths$derived_dir, "all_stations.csv"))

# ---- Generate summary GeoJSON (compact) --------------------------------------
# All data included, but: NA properties dropped per feature, all numerics
# rounded to 2 decimals, coordinates to 4 decimals, no pretty-printing.

msg("Writing summary GeoJSON")

geo_dt = summary_dt[!is.na(lat) & !is.na(lon)]

if (nrow(geo_dt) > 0) {
  # Round all numeric columns to 2 decimal places
  num_cols = names(geo_dt)[sapply(geo_dt, is.numeric)]
  coord_cols = c("lat", "lon")
  metric_cols = setdiff(num_cols, c(coord_cols, "elev"))
  for (col in metric_cols) {
    geo_dt[, (col) := round(get(col), 2)]
  }
  # Coordinates to 4 decimal places (~11m precision, plenty for stations)
  for (col in coord_cols) {
    geo_dt[, (col) := round(get(col), 4)]
  }

  # Drop columns that are entirely NA (no station has that metric)
  all_na_cols = names(geo_dt)[sapply(geo_dt, function(x) all(is.na(x)))]
  if (length(all_na_cols) > 0) {
    geo_dt[, (all_na_cols) := NULL]
    msg(sprintf("  Dropped %d all-NA columns", length(all_na_cols)))
  }

  # Build GeoJSON manually — skip NA properties per feature for compact output
  prop_cols = setdiff(names(geo_dt), c("lat", "lon"))

  features = vector("list", nrow(geo_dt))
  for (i in seq_len(nrow(geo_dt))) {
    row = geo_dt[i]
    # Build properties list, skipping NAs
    props = list()
    for (col in prop_cols) {
      val = row[[col]]
      if (!is.na(val)) props[[col]] = val
    }
    features[[i]] = list(
      type = "Feature",
      geometry = list(
        type = "Point",
        coordinates = c(row$lon, row$lat)
      ),
      properties = props
    )
  }

  geojson = list(
    type = "FeatureCollection",
    features = features
  )

  geojson_path = file.path(paths$derived_dir, "GHCNd_drought_current.geojson")
  geojson_gz_path = paste0(geojson_path, ".gz")

  # Write uncompressed GeoJSON
  geojson_str = toJSON(geojson, auto_unbox = TRUE, digits = 4)
  writeLines(geojson_str, geojson_path)
  file_mb = round(file.info(geojson_path)$size / 1e6, 1)

  # Write gzipped version for web delivery
  gz_con = gzfile(geojson_gz_path, "wb")
  writeLines(geojson_str, gz_con)
  close(gz_con)
  gz_mb = round(file.info(geojson_gz_path)$size / 1e6, 1)

  rm(geojson_str)

  msg(sprintf("GeoJSON: %d features, %d property columns, %.1f MB (%.1f MB gzipped)",
              nrow(geo_dt), length(prop_cols), file_mb, gz_mb))
} else {
  msg("WARNING: No stations with valid coordinates for GeoJSON")
}

# ---- Generate base + per-slice + manifest layout (lazy-load) -----------------
# This produces a thin base GeoJSON (geometry + minimal metadata) plus one
# small JSON file per (var, ts, period) slice. Clients load the manifest first,
# then fetch the base once, then lazy-load only the slices they need to display.
#
# Layout under derived/ghcnd_drought/:
#   stations_base.geojson.gz        - geometry + id/name/state/elev/data_date
#   slices/<var>_<ts>_<period>.json.gz  - { var, ts, period, generated, values: {id: val} }
#   manifest.json.gz                - index of all slices

if (nrow(geo_dt) > 0) {
  msg("Writing lazy-load layout (base + slices + manifest)")

  generated = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  slices_dir = file.path(paths$derived_dir, "slices")
  dir.create(slices_dir, recursive = TRUE, showWarnings = FALSE)

  # Per-station data_date = max obs date across all metric families
  obs_date_cols = intersect(c("spi_last_obs", "spei_last_obs", "eddi_last_obs", "precip_last_obs"),
                             names(summary_dt))
  if (length(obs_date_cols) > 0) {
    summary_dt[, station_data_date := apply(.SD, 1, function(row) {
      dates = na.omit(unlist(row))
      if (length(dates) == 0) return(NA_character_)
      max(dates)
    }), .SDcols = obs_date_cols]
  } else {
    summary_dt[, station_data_date := NA_character_]
  }

  # ---- Base GeoJSON: geometry + minimal station metadata ---------------------
  base_dt = summary_dt[!is.na(lat) & !is.na(lon)]
  base_features = vector("list", nrow(base_dt))
  for (i in seq_len(nrow(base_dt))) {
    row = base_dt[i]
    props = list(id = row$id)
    for (col in c("name", "state", "elev", "station_data_date")) {
      val = row[[col]]
      if (!is.na(val)) {
        out_name = if (col == "station_data_date") "data_date" else col
        props[[out_name]] = val
      }
    }
    base_features[[i]] = list(
      type = "Feature",
      geometry = list(type = "Point",
                      coordinates = c(round(row$lon, 4), round(row$lat, 4))),
      properties = props
    )
  }
  base_geojson = list(type = "FeatureCollection", features = base_features)
  base_str = toJSON(base_geojson, auto_unbox = TRUE, digits = 4, na = "null")

  base_path = file.path(paths$derived_dir, "stations_base.geojson.gz")
  con = gzfile(base_path, "wb")
  writeLines(base_str, con)
  close(con)
  base_mb = round(file.info(base_path)$size / 1e6, 2)
  msg(sprintf("  Base GeoJSON: %d features, %.2f MB", nrow(base_dt), base_mb))

  # ---- Identify slice columns by parsing column names ------------------------
  KNOWN_VARS = c("spi", "spei", "eddi",
                 "precip_mm", "precip_pon", "precip_dev", "precip_pctile")

  parse_slice = function(col) {
    for (v in KNOWN_VARS) {
      prefix = paste0(v, "_")
      if (startsWith(col, prefix)) {
        rest = substr(col, nchar(prefix) + 1, nchar(col))
        m = regmatches(rest, regexec("^(\\d+d|wy|ytd)_(.+)$", rest))[[1]]
        if (length(m) == 3) {
          return(list(var = v, ts = m[2], period = m[3], col = col))
        }
      }
    }
    NULL
  }

  candidate_cols = setdiff(names(summary_dt),
                           c("id", "name", "lat", "lon", "elev", "state",
                             "data_date", "station_data_date",
                             obs_date_cols))
  parsed_slices = Filter(Negate(is.null), lapply(candidate_cols, parse_slice))
  msg(sprintf("  Found %d slice columns", length(parsed_slices)))

  # ---- Write each slice to slices/<var>_<ts>_<period>.json.gz ----------------
  # Sort station ids once for deterministic output across slices
  ids_sorted = sort(summary_dt$id)
  id_order = match(ids_sorted, summary_dt$id)

  slice_manifest = vector("list", length(parsed_slices))
  for (i in seq_along(parsed_slices)) {
    s = parsed_slices[[i]]
    vals = summary_dt[[s$col]][id_order]

    # Round to 2 decimals; NA passes through (becomes null in JSON)
    vals_rounded = ifelse(is.na(vals), NA_real_, round(vals, 2))

    # Build sorted named list (keys = station ids)
    values = setNames(as.list(vals_rounded), ids_sorted)

    slice_obj = list(
      var = s$var,
      ts = s$ts,
      period = s$period,
      generated = generated,
      values = values
    )

    filename = sprintf("%s_%s_%s.json.gz", s$var, s$ts, s$period)
    slice_path = file.path(slices_dir, filename)

    slice_str = toJSON(slice_obj, auto_unbox = TRUE, digits = 4, na = "null")
    con = gzfile(slice_path, "wb")
    writeLines(slice_str, con)
    close(con)

    n_valid = sum(!is.na(vals))

    slice_manifest[[i]] = list(
      var = s$var,
      ts = s$ts,
      period = s$period,
      path = sprintf("slices/%s", filename),
      n_valid = n_valid
    )
  }

  # Sort manifest entries by var, ts, period for stable diffs
  slice_order = order(
    sapply(slice_manifest, function(x) x$var),
    sapply(slice_manifest, function(x) x$ts),
    sapply(slice_manifest, function(x) x$period)
  )
  slice_manifest = slice_manifest[slice_order]

  # ---- Write manifest --------------------------------------------------------
  manifest_obj = list(
    generated = generated,
    base = "stations_base.geojson.gz",
    slices = slice_manifest
  )
  manifest_str = toJSON(manifest_obj, auto_unbox = TRUE, pretty = TRUE)
  manifest_path = file.path(paths$derived_dir, "manifest.json.gz")
  con = gzfile(manifest_path, "wb")
  writeLines(manifest_str, con)
  close(con)

  # Spot-check: total slice file size
  slice_files = list.files(slices_dir, pattern = "\\.json\\.gz$", full.names = TRUE)
  total_slice_mb = round(sum(file.info(slice_files)$size) / 1e6, 2)
  manifest_kb = round(file.info(manifest_path)$size / 1024, 1)
  msg(sprintf("  Wrote %d slices (%.2f MB total), manifest %.1f KB",
              length(slice_files), total_slice_mb, manifest_kb))
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
