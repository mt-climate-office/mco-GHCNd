# ============================================================================
# drought-functions.R — Statistical fitting functions for drought indices
#
# Adapted from mco-drought-conus/R/drought-functions.R
# Includes: gamma SPI, GLO SPEI, Hargreaves-Samani daily ET0,
#           percent of normal, deviation, percentile
# ============================================================================

# ---- Hargreaves-Samani daily reference ET0 (FAO-56) -------------------------
# Computes daily reference evapotranspiration using only Tmax, Tmin, latitude,
# and day of year. All radiation equations follow FAO-56 (Allen et al., 1998).
#
# Arguments:
#   tmax    — numeric vector, daily max temperature (C)
#   tmin    — numeric vector, daily min temperature (C)
#   lat_deg — scalar, station latitude in decimal degrees
#   doy     — integer vector, day of year (1-366)
#
# Returns: numeric vector of ET0 in mm/day (same length as inputs)

hargreaves_samani_daily = function(tmax, tmin, lat_deg, doy) {
  # Solar constant (MJ m-2 min-1)
  Gsc = 0.0820

  # Convert latitude to radians
  phi = lat_deg * pi / 180

  # FAO-56 Eq. 24: Solar declination (radians)
  delta = 0.409 * sin(2 * pi / 365 * doy - 1.39)

  # FAO-56 Eq. 23: Inverse relative Earth-Sun distance
  dr = 1 + 0.033 * cos(2 * pi / 365 * doy)

  # FAO-56 Eq. 25: Sunset hour angle (radians)
  # Handle polar latitudes where |tan(phi)*tan(delta)| >= 1
  tan_prod = tan(phi) * tan(delta)
  omega_s = acos(pmin(pmax(-tan_prod, -1), 1))

  # FAO-56 Eq. 21: Extraterrestrial radiation (MJ m-2 day-1)
  Ra = (24 * 60 / pi) * Gsc * dr *
    (omega_s * sin(phi) * sin(delta) +
     cos(phi) * cos(delta) * sin(omega_s))

  # FAO-56 Eq. 20: Convert Ra to mm/day equivalent (1/lambda, lambda=2.45 MJ/kg)
  Ra_mm = 0.408 * Ra

  # Mean temperature
  tmean = (tmax + tmin) / 2

  # Temperature range (must be non-negative)
  td = tmax - tmin
  td = pmax(td, 0)

  # Hargreaves-Samani equation
  et0 = 0.0023 * Ra_mm * (tmean + 17.8) * sqrt(td)

  # Clamp to non-negative (ET0 cannot be negative)
  et0 = pmax(et0, 0)

  # Propagate NA from inputs
  et0[is.na(tmax) | is.na(tmin)] = NA_real_


  return(et0)
}


# ---- Gamma SPI following Stagge et al. (2015) --------------------------------
# L-moment gamma SPI with proper zero handling via center-of-probability-mass
# (Weibull plotting position) following Stagge et al. (2015).
# Reference: https://rmets.onlinelibrary.wiley.com/doi/10.1002/joc.4267
#
# Zero precipitation methodology (Stagge et al. 2015, Eq. 2-4):
#   p0      = n_zero / (n + 1)            -- Weibull probability of zero
#   p_bar_0 = (n_zero + 1) / (2*(n + 1))  -- center of mass for zeros
#   For x > 0: p = p0 + (1 - p0) * F(x, gamma_params)
#   For x = 0: p = p_bar_0
#   SPI = Phi^-1(p)

gamma_fit_spi = function(ref_dist, current_val, export_opts = 'SPI',
                         climatology_length = 30, zero_threshold = 0) {
  library(lmomco)
  tryCatch({
    ref_dist = as.numeric(ref_dist)
    ref_dist = tail(ref_dist, climatology_length)
    n = length(ref_dist)
    if (n < 3) return(NA)
    if (is.na(current_val)) return(NA)

    # Identify zeros in reference distribution (threshold per Stagge et al.)
    is_zero_ref = (ref_dist <= zero_threshold)
    n_zero  = sum(is_zero_ref)

    # Weibull plotting positions (Eq. 2-3)
    p0      = n_zero / (n + 1)
    p_bar_0 = (n_zero + 1) / (2 * (n + 1))

    if (n_zero == n) {
      # All reference values are zero
      fit_cdf_current = if (current_val <= zero_threshold) p_bar_0 else 1 - 1/(2*(n+1))
      spi_current = qnorm(fit_cdf_current)
    } else {
      ref_pos = ref_dist[!is_zero_ref]
      if (length(ref_pos) < 3 || stats::sd(ref_pos) == 0) return(NA)

      # L-moment gamma fit to non-zero reference values
      pwm      = pwm.ub(ref_pos)
      lmom     = pwm2lmom(pwm)
      fit.gam  = pargam(lmom)

      # Evaluate CDF at current_val
      if (current_val <= zero_threshold) {
        fit_cdf_current = p_bar_0
      } else {
        fit_cdf_current = p0 + (1 - p0) * cdfgam(current_val, fit.gam)
      }

      spi_current = qnorm(fit_cdf_current)
    }

    if (export_opts == 'CDF')    return(fit_cdf_current)
    if (export_opts == 'params') return(list(fit = if (n_zero == n) NULL else fit.gam,
                                              p0 = p0))
    if (export_opts == 'SPI')    return(spi_current)
  }, error = function(cond) return(NA))
}


# ---- GLO SPEI ---------------------------------------------------------------
# Generalized Logistic distribution fit for SPEI (water balance = precip - PET).
# GLO handles the unbounded, potentially negative water balance values.

glo_fit_spei = function(ref_dist, current_val, export_opts = 'SPEI',
                        climatology_length = 30) {
  library(lmomco)
  tryCatch({
    ref_dist = as.numeric(ref_dist)
    ref_dist = tail(ref_dist, climatology_length)
    n = length(ref_dist)
    if (n < 3 || stats::sd(ref_dist) == 0) return(NA)
    if (is.na(current_val)) return(NA)

    # Fit GLO to reference distribution only
    pwm = pwm.ub(ref_dist)
    lmoments_x = pwm2lmom(pwm)
    fit.parglo = parglo(lmoments_x)

    # Evaluate at current_val
    fit_cdf_current = cdfglo(current_val, fit.parglo)
    spei_current = qnorm(fit_cdf_current, mean = 0, sd = 1)

    if (export_opts == 'CDF')    return(fit_cdf_current)
    if (export_opts == 'params') return(fit.parglo)
    if (export_opts == 'SPEI')   return(spei_current)
  }, error = function(cond) return(NA))
}


# ---- Nonparametric EDDI (Hobbins et al., 2016) -------------------------------
# Evaporative Demand Drought Index: rank-based index from PET.
# Positive EDDI = drought (high evaporative demand).
# Uses Abramowitz & Stegun rational approximation for the inverse normal.

nonparam_fit_eddi = function(ref_dist, current_val, climatology_length = 30) {
  C0 = 2.515517
  C1 = 0.802853
  C2 = 0.010328
  d1 = 1.432788
  d2 = 0.189269
  d3 = 0.001308

  ref_dist = as.numeric(ref_dist)
  ref_dist = tail(ref_dist, climatology_length)

  if (all(is.na(ref_dist))) return(NA)
  if (is.na(current_val)) return(NA)

  # If current_val is the last element of ref_dist (rolling/full case),
  # preserve original n-sample ranking. Otherwise (fixed-outside-range),
  # rank current_val within the ref_dist + current_val (n+1) sample.
  n_ref = length(ref_dist)
  current_in_ref = (n_ref > 0) && isTRUE(all.equal(ref_dist[n_ref], current_val))

  if (current_in_ref) {
    sample = ref_dist
    target_idx = n_ref
  } else {
    sample = c(ref_dist, current_val)
    target_idx = length(sample)
  }

  # Rank PET (1 = max evaporative demand)
  rank_1 = rank(-sample)
  n = length(rank_1)

  # Tukey plotting position for current_val
  prob_current = (rank_1[target_idx] - 0.33) / (n + 0.33)

  # Compute W
  if (prob_current <= 0.5) {
    W = sqrt(-2 * log(prob_current))
  } else {
    W = sqrt(-2 * log(1 - prob_current))
  }

  EDDI = W - ((C0 + C1 * W + C2 * W^2) / (1 + d1 * W + d2 * W^2 + d3 * W^3))

  # Sign reversal for prob > 0.5 so high demand → positive EDDI
  if (prob_current > 0.5) EDDI = -EDDI

  return(EDDI)
}


# ---- Simple metrics ----------------------------------------------------------

percent_of_normal = function(ref_dist, current_val, climatology_length = 30) {
  ref_dist = tail(ref_dist, climatology_length)
  x_mean = mean(ref_dist, na.rm = TRUE)
  if (is.na(x_mean) || x_mean == 0 || is.na(current_val)) return(NA_real_)
  return((current_val / x_mean) * 100)
}

deviation_from_normal = function(ref_dist, current_val, climatology_length = 30) {
  ref_dist = tail(ref_dist, climatology_length)
  x_mean = mean(ref_dist, na.rm = TRUE)
  if (is.na(current_val)) return(NA_real_)
  return(current_val - x_mean)
}

compute_percentile = function(ref_dist, current_val, climatology_length = 30) {
  tryCatch({
    ref_dist = tail(ref_dist, climatology_length)
    if (is.na(current_val)) return(NA)
    ecdf_ = ecdf(ref_dist)
    return(ecdf_(current_val))
  }, error = function(e) return(NA))
}
