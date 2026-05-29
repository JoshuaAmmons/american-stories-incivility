# R/did_wrapper.R — Wrapper for modern DiD estimators
#
# Provides a unified interface for:
#   cs_notyet  — Callaway & Sant'Anna (2021) via {did}
#   iw         — Sun & Abraham (2021) via {fixest} sunab()
#   didm       — de Chaisemartin & D'Haultfoeuille (2020) via {DIDmultiplegt}
#   twfe       — Dynamic TWFE event study via {fixest}
#
# Returns a list with:
#   $est.att    — data.table of period-level ATTs (ATT, S.E., CI.lower, CI.upper, period)
#   $est.avg    — list with ATT.avg, S.E., CI.lower, CI.upper, p.value
#   $method     — character string of method name
#   $model      — the raw model object

# Install packages if needed (first-run guard)
for (pkg in c("did", "fixest")) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    install.packages(pkg, repos = "https://cloud.r-project.org")
  }
}
# DIDmultiplegt may not be available on all systems
if (!requireNamespace("DIDmultiplegt", quietly = TRUE)) {
  message("DIDmultiplegt not installed. The 'didm' method will be unavailable.")
}

did_wrapper <- function(data, Y, D, index, method,
                        didm.effects = 6, didm.placebo = 3,
                        seed = 42, ...) {

  unit_id <- index[1]
  time_id <- index[2]

  # Ensure data is a data.frame with proper column types
  data <- as.data.frame(data)
  data[[unit_id]] <- as.integer(data[[unit_id]])
  data[[time_id]] <- as.integer(data[[time_id]])

  # Determine treatment cohort for each unit
  # treat_cohort = first time_id where D == 1 (0 = never treated)
  if (!"treat_cohort" %in% names(data)) {
    dt_tmp <- data.table::as.data.table(data)
    cohort_dt <- dt_tmp[get(D) == 1, .(treat_cohort = min(get(time_id))), by = c(unit_id)]
    data <- merge(data, as.data.frame(cohort_dt), by = unit_id, all.x = TRUE)
    data$treat_cohort[is.na(data$treat_cohort)] <- 0L
  }

  set.seed(seed)

  result <- switch(method,
    # ------ Callaway & Sant'Anna (2021) ------
    cs_notyet = {
      library(did)

      # Drop rows with NA in outcome before calling att_gt
      data <- data[!is.na(data[[Y]]), , drop = FALSE]

      out <- att_gt(
        yname  = Y,
        tname  = time_id,
        idname = unit_id,
        gname  = "treat_cohort",
        data   = data,
        control_group = "notyettreated",
        bstrap = TRUE,
        cband  = TRUE,
        allow_unbalanced_panel = TRUE,
        ...
      )

      # Aggregate to event-time ATTs (na.rm=TRUE for unbalanced panels)
      agg_es <- aggte(out, type = "dynamic", na.rm = TRUE)

      # Period-level
      est_att <- data.table::data.table(
        period   = agg_es$egt,
        ATT      = agg_es$att.egt,
        S.E.     = agg_es$se.egt,
        CI.lower = agg_es$att.egt - 1.96 * agg_es$se.egt,
        CI.upper = agg_es$att.egt + 1.96 * agg_es$se.egt
      )

      # Simple average (accounts for covariance internally)
      agg_avg <- aggte(out, type = "simple", na.rm = TRUE)
      est_avg <- list(
        ATT.avg  = agg_avg$overall.att,
        S.E.     = agg_avg$overall.se,
        CI.lower = agg_avg$overall.att - 1.96 * agg_avg$overall.se,
        CI.upper = agg_avg$overall.att + 1.96 * agg_avg$overall.se,
        p.value  = 2 * pnorm(-abs(agg_avg$overall.att / agg_avg$overall.se))
      )

      list(est.att = est_att, est.avg = est_avg, method = "cs_notyet", model = out)
    },

    # ------ Sun & Abraham (2021) — interaction-weighted via sunab() ------
    iw = {
      library(fixest)

      # FIXED: Use sunab() for the actual Sun & Abraham (2021) estimator.
      # The previous version was a plain TWFE event study, identical to the twfe method.
      # sunab() is the correct fixest function for the interaction-weighted estimator.
      # It handles heterogeneous treatment effects across cohorts properly.

      # sunab requires the cohort variable and the time variable
      # treat_cohort = 0 for never-treated; sunab needs Inf or a large number for never-treated
      data$cohort_sa <- data$treat_cohort
      data$cohort_sa[data$cohort_sa == 0] <- .Machine$integer.max  # never-treated sentinel

      # Build formula using proper variable referencing
      vcov_fml <- as.formula(paste0("~", unit_id))

      fml <- as.formula(paste0(Y, " ~ sunab(cohort_sa, ", time_id, ") | ",
                               unit_id, " + ", time_id))

      out <- feols(fml, data = data, vcov = vcov_fml)

      # Extract event-study coefficients from sunab output
      coef_vals <- coef(out)
      se_all <- sqrt(diag(vcov(out)))

      # Extract period-level ATTs from sunab coefficient names
      # sunab names vary by fixest version:
      #   "time_id::-5", "time_id::0", "time_id::3" (simple format)
      #   "time_id::5:cohort_sa::100" (multi-factor format)
      # Anchor to the known time variable name to avoid matching unrelated covariates
      coef_nms <- names(coef_vals)
      time_re <- paste0("^", time_id, "::(-?\\d+)")
      periods_raw <- sub(paste0(time_re, ".*"), "\\1", coef_nms)
      periods <- suppressWarnings(as.integer(periods_raw))
      valid <- !is.na(periods)

      est_att <- data.table::data.table(
        period   = periods[valid],
        ATT      = unname(coef_vals[valid]),
        S.E.     = unname(se_all[valid]),
        CI.lower = unname(coef_vals[valid]) - 1.96 * unname(se_all[valid]),
        CI.upper = unname(coef_vals[valid]) + 1.96 * unname(se_all[valid])
      )
      data.table::setorder(est_att, period)

      # Average post-treatment ATT using full vcov for proper SE
      post_idx <- which(valid & periods >= 0)
      if (length(post_idx) > 0) {
        post_coefs <- coef_vals[post_idx]
        post_vcov  <- vcov(out)[post_idx, post_idx, drop = FALSE]
        avg_att <- mean(post_coefs)
        # Proper SE accounting for covariance: Var(mean) = (1/K^2) * sum(Sigma)
        K <- length(post_coefs)
        avg_se  <- sqrt(sum(post_vcov) / K^2)
        est_avg <- list(
          ATT.avg  = avg_att,
          S.E.     = avg_se,
          CI.lower = avg_att - 1.96 * avg_se,
          CI.upper = avg_att + 1.96 * avg_se,
          p.value  = 2 * pnorm(-abs(avg_att / avg_se))
        )
      } else {
        est_avg <- list(ATT.avg = NA, S.E. = NA, CI.lower = NA,
                        CI.upper = NA, p.value = NA)
      }

      list(est.att = est_att, est.avg = est_avg, method = "iw", model = out)
    },

    # ------ de Chaisemartin & D'Haultfoeuille (2024a) via did_multiplegt(mode="dyn") ------
    didm = {
      if (!requireNamespace("DIDmultiplegt", quietly = TRUE)) {
        warning("DIDmultiplegt package not installed. Skipping didm method.")
        return(list(est.att = data.table::data.table(), est.avg = list(
          ATT.avg = NA, S.E. = NA, CI.lower = NA, CI.upper = NA, p.value = NA
        ), method = "didm", model = NULL))
      }
      library(DIDmultiplegt)

      # DIDmultiplegt v2.0+ requires mode= as first argument
      # mode="dyn" uses the fast event-study estimator (dCDH 2024a)
      # IMPORTANT: df, Y, G, T, D are POSITIONAL args after mode (not named)
      out <- tryCatch({
        did_multiplegt(
          "dyn", data, Y, unit_id, time_id, D,
          effects = didm.effects,
          placebo = didm.placebo,
          graph_off = TRUE
        )
      }, error = function(e) {
        message("  did_multiplegt(mode='dyn') failed: ", e$message)
        message("  Trying mode='old'...")
        tryCatch({
          did_multiplegt(
            "old", data, Y, unit_id, time_id, D,
            dynamic = didm.effects,
            placebo = didm.placebo,
            brep    = 100,
            cluster = unit_id
          )
        }, error = function(e2) {
          message("  mode='old' also failed: ", e2$message)
          NULL
        })
      })

      if (is.null(out)) {
        return(list(est.att = data.table::data.table(), est.avg = list(
          ATT.avg = NA, S.E. = NA, CI.lower = NA, CI.upper = NA, p.value = NA
        ), method = "didm", model = NULL))
      }

      # Extract results from DIDmultiplegt v2 "dyn" mode output
      # $coef$b = vector of coefficients (placebos then effects)
      # $coef$vcov = variance-covariance matrix
      # $results$ATE = c(ATT, SE, CI.lower, CI.upper, ...)
      # $results$N_Effects, $results$N_Placebos

      n_eff <- as.integer(out$results$N_Effects)
      n_plac <- as.integer(out$results$N_Placebos)
      coef_b <- out$coef$b
      coef_vcov <- out$coef$vcov

      # SEs from diagonal of vcov
      se_all <- sqrt(diag(coef_vcov))

      # Periods: -n_plac, ..., -1, 1, 2, ..., n_eff (dyn mode has no period 0)
      periods <- c(-seq(n_plac, 1), seq_len(n_eff))

      est_att <- data.table::data.table(
        period   = periods,
        ATT      = coef_b,
        S.E.     = se_all,
        CI.lower = coef_b - 1.96 * se_all,
        CI.upper = coef_b + 1.96 * se_all
      )

      # Average post-treatment ATT from $results$ATE
      ate_vec <- out$results$ATE
      if (length(ate_vec) >= 4 && !is.na(ate_vec[1])) {
        est_avg <- list(
          ATT.avg  = ate_vec[1],
          S.E.     = ate_vec[2],
          CI.lower = ate_vec[3],
          CI.upper = ate_vec[4],
          p.value  = 2 * pnorm(-abs(ate_vec[1] / ate_vec[2]))
        )
      } else {
        est_avg <- list(ATT.avg = NA, S.E. = NA, CI.lower = NA,
                        CI.upper = NA, p.value = NA)
      }

      list(est.att = est_att, est.avg = est_avg, method = "didm", model = out)
    },

    # ------ Dynamic TWFE ------
    twfe = {
      library(fixest)

      # Create relative time; never-treated units get NA (excluded from event study)
      data$rel_time <- data[[time_id]] - data$treat_cohort
      data$rel_time[data$treat_cohort == 0] <- NA

      max_lead <- 24
      max_lag  <- 24

      # Only create binned factor for treated units
      data$rel_time_binned <- pmax(-max_lead, pmin(max_lag, data$rel_time))
      # NA stays NA — never-treated units are absorbed by fixed effects

      # FIXED: Use proper vcov formula syntax
      vcov_fml <- as.formula(paste0("~", unit_id))

      fml <- as.formula(paste0(Y, " ~ i(rel_time_binned, ref = -1) | ",
                               unit_id, " + ", time_id))

      out <- feols(fml, data = data, vcov = vcov_fml)

      coef_names <- grep("^rel_time_binned::", names(coef(out)), value = TRUE)
      periods <- as.integer(gsub("rel_time_binned::", "", coef_names))
      att_vals <- coef(out)[coef_names]
      se_vals  <- sqrt(diag(vcov(out)))[coef_names]

      est_att <- data.table::data.table(
        period   = periods,
        ATT      = unname(att_vals),
        S.E.     = unname(se_vals),
        CI.lower = unname(att_vals) - 1.96 * unname(se_vals),
        CI.upper = unname(att_vals) + 1.96 * unname(se_vals)
      )
      data.table::setorder(est_att, period)

      # Average post-treatment ATT using full vcov for proper SE
      post_idx <- which(periods >= 0)
      if (length(post_idx) > 0) {
        post_coefs <- att_vals[post_idx]
        post_vcov  <- vcov(out)[coef_names[post_idx], coef_names[post_idx], drop = FALSE]
        avg_att <- mean(post_coefs)
        K <- length(post_coefs)
        avg_se  <- sqrt(sum(post_vcov) / K^2)
        est_avg <- list(
          ATT.avg  = unname(avg_att),
          S.E.     = avg_se,
          CI.lower = unname(avg_att) - 1.96 * avg_se,
          CI.upper = unname(avg_att) + 1.96 * avg_se,
          p.value  = 2 * pnorm(-abs(unname(avg_att) / avg_se))
        )
      } else {
        est_avg <- list(ATT.avg = NA, S.E. = NA, CI.lower = NA,
                        CI.upper = NA, p.value = NA)
      }

      list(est.att = est_att, est.avg = est_avg, method = "twfe", model = out)
    },

    stop("Unknown method: ", method)
  )

  return(result)
}

message("did_wrapper loaded (cs_notyet, iw/sunab, didm, twfe).")
