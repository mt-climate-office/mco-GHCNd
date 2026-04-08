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

gamma_fit_spi = function(x, export_opts = 'SPI', return_latest = TRUE,
                         climatology_length = 30, zero_threshold = 0) {
  library(lmomco)
  tryCatch({
    x = as.numeric(x)
    x = tail(x, climatology_length)
    n = length(x)
    if (n < 3) return(NA)

    # Identify zeros (threshold per Stagge et al.)
    is_zero = (x <= zero_threshold)
    n_zero  = sum(is_zero)

    if (n_zero == n) {
      spi = rep(0, n)
      fit_cdf = rep(0.5, n)
    } else {
      x_pos = x[!is_zero]
      if (length(x_pos) < 3 || stats::sd(x_pos) == 0) return(NA)

      # L-moment gamma fit to non-zero values
      pwm      = pwm.ub(x_pos)
      lmom     = pwm2lmom(pwm)
      fit.gam  = pargam(lmom)

      # Weibull plotting positions (Eq. 2-3)
      p0      = n_zero / (n + 1)
      p_bar_0 = (n_zero + 1) / (2 * (n + 1))

      # Build CDF (Eq. 4)
      fit_cdf = numeric(n)
      fit_cdf[is_zero]  = p_bar_0
      fit_cdf[!is_zero] = p0 + (1 - p0) * cdfgam(x_pos, fit.gam)

      # Transform to standard normal and clamp to [-3, 3]
      spi = qnorm(fit_cdf)
    }

    if (return_latest) {
      if (export_opts == 'CDF')    return(fit_cdf[n])
      if (export_opts == 'params') return(list(fit = fit.gam,
                                                p0 = n_zero / (n + 1)))
      if (export_opts == 'SPI')    return(spi[n])
    } else {
      if (export_opts == 'CDF')    return(fit_cdf)
      if (export_opts == 'params') return(list(fit = fit.gam,
                                                p0 = n_zero / (n + 1)))
      if (export_opts == 'SPI')    return(spi)
    }
  }, error = function(cond) return(NA))
}


# ---- GLO SPEI ---------------------------------------------------------------
# Generalized Logistic distribution fit for SPEI (water balance = precip - PET).
# GLO handles the unbounded, potentially negative water balance values.

glo_fit_spei = function(x, export_opts = 'SPEI', return_latest = TRUE,
                        climatology_length = 30) {
  library(lmomco)
  tryCatch({
    x = as.numeric(x)
    x = tail(x, climatology_length)
    n = length(x)
    if (n < 3 || stats::sd(x) == 0) return(NA)

    # Unbiased Sample Probability-Weighted Moments
    pwm = pwm.ub(x)
    lmoments_x = pwm2lmom(pwm)

    # Fit generalized logistic
    fit.parglo = parglo(lmoments_x)

    # Compute CDF
    fit.cdf = cdfglo(x, fit.parglo)

    # Transform to standard normal
    spei = qnorm(fit.cdf, mean = 0, sd = 1)

    if (return_latest) {
      if (export_opts == 'CDF')    return(fit.cdf[n])
      if (export_opts == 'params') return(fit.parglo)
      if (export_opts == 'SPEI')   return(spei[n])
    } else {
      if (export_opts == 'CDF')    return(fit.cdf)
      if (export_opts == 'params') return(fit.parglo)
      if (export_opts == 'SPEI')   return(spei)
    }
  }, error = function(cond) return(NA))
}


# ---- Nonparametric EDDI (Hobbins et al., 2016) -------------------------------
# Evaporative Demand Drought Index: rank-based index from PET.
# Positive EDDI = drought (high evaporative demand).
# Uses Abramowitz & Stegun rational approximation for the inverse normal.

nonparam_fit_eddi = function(x, climatology_length = 30) {
  C0 = 2.515517
  C1 = 0.802853
  C2 = 0.010328
  d1 = 1.432788
  d2 = 0.189269
  d3 = 0.001308

  x = as.numeric(x)
  x = tail(x, climatology_length)

  if (all(is.na(x))) return(NA)

  # Rank PET (1 = max)
  rank_1 = rank(-x)

  # Empirical probabilities
  prob = ((rank_1 - 0.33) / (length(rank_1) + 0.33))

  # Compute W
  W = numeric(length(prob))
  for (i in seq_along(prob)) {
    if (prob[i] <= 0.5) {
      W[i] = sqrt(-2 * log(prob[i]))
    } else {
      W[i] = sqrt(-2 * log(1 - prob[i]))
    }
  }

  # Indexes needing sign reversal
  reverse_index = which(prob > 0.5)

  # Compute EDDI
  EDDI = W - ((C0 + C1 * W + C2 * W^2) / (1 + d1 * W + d2 * W^2 + d3 * W^3))

  # Reverse sign where prob > 0.5
  EDDI[reverse_index] = -EDDI[reverse_index]

  return(EDDI[length(EDDI)])
}


# ---- Simple metrics ----------------------------------------------------------

percent_of_normal = function(x, climatology_length = 30) {
  x = tail(x, climatology_length)
  x_mean = mean(x, na.rm = TRUE)
  if (is.na(x_mean) || x_mean == 0) return(NA_real_)
  return((x[length(x)] / x_mean) * 100)
}

deviation_from_normal = function(x, climatology_length = 30) {
  x = tail(x, climatology_length)
  x_mean = mean(x, na.rm = TRUE)
  return(x[length(x)] - x_mean)
}

compute_percentile = function(x, climatology_length = 30) {
  tryCatch({
    x = tail(x, climatology_length)
    ecdf_ = ecdf(x)
    return(ecdf_(x[length(x)]))
  }, error = function(e) return(NA))
}
