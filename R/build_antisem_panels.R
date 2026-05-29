# R/build_antisem_panels.R
# Memory-safe, sequential construction of antisemitism treatment panels.
#
# Replaces the OOM-prone parallel logic that used to live inline in
# rmd/06b_treatment_panel_antisem.Rmd. That version loaded all ~336M scored
# rows into one ~63 GB data.table and then clusterExport()'d it to 5 workers
# (each also doing copy(dt)) -> >300 GB peak -> guaranteed OOM on 128 GB.
#
# This version streams the corpus ONE YEAR AT A TIME:
#   * each year's text file is read once and ALL figures are flagged in that
#     single pass (no 19x re-scan),
#   * the year's scored rows are aggregated to newspaper x month immediately,
#   * only the small monthly aggregates are accumulated.
# Peak memory is ~one year of data (~7-8 GB), not the whole corpus.
#
# Output is byte-for-byte the same panel schema the old code produced, so
# 07c_did_antisemitism.Rmd and 08b_figures_tables_antisem.Rmd are unchanged.
#
# Public entry point:
#   build_all_antisem_panels(roberta_dir, text_dir, figures, out_dir,
#                            year_min = 1774L, year_max = 1960L)

suppressMessages({
  library(arrow)
  library(data.table)
  library(stringr)
})

# Split a figure's keyword list into a plain "\\b(a|b|c)\\b" alternation and any
# lookahead-style regexes (e.g. "(?=.*gerald smith).*america first").
.compile_patterns <- function(keywords) {
  simple_kws <- keywords[!grepl("\\(\\?=", keywords)]
  regex_kws  <- keywords[grepl("\\(\\?=", keywords)]
  simple_pattern <- if (length(simple_kws) > 0) {
    stringr::regex(paste0("\\b(", paste(simple_kws, collapse = "|"), ")\\b"),
                   ignore_case = TRUE)
  } else NULL
  regex_patterns <- if (length(regex_kws) > 0) {
    lapply(regex_kws, function(p) stringr::regex(p, ignore_case = TRUE))
  } else list()
  list(simple = simple_pattern, regex = regex_patterns)
}

# Article-level aggregation for one figure within one year (newspaper x month).
# Identical statistics to the original build_antisem_panel().
.aggregate_year <- function(sc, ids) {
  sc[, .isfig := as.integer(article_id %chin% ids)]
  agg <- sc[, .(
    antisem_rate_roberta  = mean(p_antisem[.isfig == 0], na.rm = TRUE),
    antisem_rate_lexicon  = mean(antisem_score[.isfig == 0], na.rm = TRUE),
    figure_count          = sum(.isfig),
    figure_share          = mean(.isfig),
    n_articles            = .N,
    n_articles_non_figure = sum(.isfig == 0),
    mean_words            = mean(n_words, na.rm = TRUE),
    mean_ocr              = mean(ocr_quality, na.rm = TRUE),
    front_page_share      = mean(front_page, na.rm = TRUE)
  ), by = .(newspaper_name, year_month)]
  sc[, .isfig := NULL]
  agg
}

# Assemble accumulated monthly aggregates for one figure, define treatment,
# apply filters, and save. Treatment logic is copied verbatim from the original.
.finalize_panel <- function(fig_key, parts, out_dir) {
  if (length(parts) == 0) {
    message("  ", fig_key, ": no data in study window, skipped.")
    return(invisible(NULL))
  }
  panel <- rbindlist(parts, fill = TRUE)
  if (nrow(panel) == 0) {
    message("  ", fig_key, ": empty panel, skipped.")
    return(invisible(NULL))
  }

  panel[, ym_date := as.Date(paste0(year_month, "-01"))]
  panel[, time_id := (as.integer(format(ym_date, "%Y")) - 1774L) * 12L +
                      as.integer(format(ym_date, "%m"))]
  setorder(panel, newspaper_name, ym_date)

  # Sustained coverage: >= 2 figure articles in >= 2 of 3 consecutive months.
  panel[, sustained := {
    n <- .N
    flag <- rep(0L, n)
    if (n >= 3) {
      tid <- time_id
      fc  <- figure_count
      for (i in 1:(n - 2)) {
        if (tid[i + 1] - tid[i] == 1L && tid[i + 2] - tid[i + 1] == 1L) {
          months_with <- sum(fc[i:(i + 2)] >= 2)
          if (months_with >= 2) { flag[i] <- 1L; break }
        }
      }
    }
    flag
  }, by = newspaper_name]

  treat_info <- panel[sustained == 1,
                      .(treat_date = min(ym_date), treat_time_id = min(time_id)),
                      by = newspaper_name]
  panel <- merge(panel, treat_info, by = "newspaper_name", all.x = TRUE)
  panel[, treated := as.integer(!is.na(treat_date) & ym_date >= treat_date)]
  panel[is.na(treated), treated := 0L]
  panel[, treat_cohort := fifelse(!is.na(treat_time_id), treat_time_id, 0L)]
  panel[, newspaper_id := as.integer(factor(newspaper_name))]

  np_counts <- panel[, .N, by = newspaper_name]
  keep_nps <- np_counts[N >= 12, newspaper_name]
  panel <- panel[newspaper_name %in% keep_nps]
  panel <- panel[n_articles_non_figure >= 5]
  panel[, c("sustained", "ym_date") := NULL]

  n_treated <- uniqueN(panel[treated == 1, newspaper_name])
  message("  ", fig_key, ": ", nrow(panel), " newspaper-months, ",
          uniqueN(panel$newspaper_name), " newspapers, ", n_treated, " treated")
  if (n_treated == 0) {
    message("  ", fig_key, ": no treated newspapers, panel not saved.")
    return(invisible(NULL))
  }

  outpath <- file.path(out_dir, paste0("did_panel_antisem_", fig_key, ".parquet"))
  write_parquet(panel, outpath)
  write.csv(panel, file.path(out_dir, paste0("did_panel_antisem_", fig_key, ".csv")),
            row.names = FALSE)
  message("  ", fig_key, ": saved -> ", outpath)
  invisible(panel)
}

build_all_antisem_panels <- function(roberta_dir, text_dir, figures, out_dir,
                                     year_min = 1774L, year_max = 1960L,
                                     verbose = TRUE) {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  pats      <- lapply(figures, function(f) .compile_patterns(f$keywords))
  min_years <- vapply(figures, function(f) as.integer(f$min_year), integer(1))
  starts    <- vapply(figures, function(f) as.integer(f$study_start), integer(1))
  ends      <- vapply(figures, function(f) as.integer(f$study_end), integer(1))
  fig_keys  <- names(figures)

  # Skip-if-exists (resumable).
  done <- file.exists(file.path(out_dir, paste0("did_panel_antisem_", fig_keys, ".parquet")))
  todo <- fig_keys[!done]
  if (length(todo) == 0) {
    message("All antisemitism panels already exist. Delete to rebuild.")
    return(invisible(NULL))
  }
  message("Figures to build: ", length(todo), " of ", length(figures),
          " (", paste(todo, collapse = ", "), ")")

  acc <- setNames(vector("list", length(todo)), todo)

  scored_cols <- c("article_id", "newspaper_name", "year", "year_month",
                   "p_antisem", "antisem_score", "n_words", "ocr_quality",
                   "front_page")

  for (yr in year_min:year_max) {
    rfile <- file.path(roberta_dir, paste0("roberta_scored_", yr, ".parquet"))
    tfile <- file.path(text_dir,    paste0("antisem_scored_", yr, ".parquet"))
    if (!file.exists(rfile)) next

    active <- todo[yr >= starts[todo] & yr <= ends[todo]]
    if (length(active) == 0) next

    sc <- as.data.table(read_parquet(rfile, col_select = scored_cols))
    sc <- sc[!is.na(year_month)]
    if (nrow(sc) == 0) next

    # Only figures whose min_year floor is reached get flagged this year.
    to_flag <- active[yr >= min_years[active]]

    ids_year <- list()
    if (length(to_flag) > 0 && file.exists(tfile)) {
      tx <- as.data.table(read_parquet(tfile, col_select = c("article_id", "article")))
      tl <- tolower(tx$article)
      for (fk in to_flag) {
        p <- pats[[fk]]
        hit <- rep(FALSE, length(tl))
        if (!is.null(p$simple)) {
          h <- str_detect(tl, p$simple); h[is.na(h)] <- FALSE; hit <- hit | h
        }
        for (rp in p$regex) {
          h <- str_detect(tl, rp); h[is.na(h)] <- FALSE; hit <- hit | h
        }
        ids_year[[fk]] <- tx$article_id[hit]
      }
      rm(tx, tl)
    }

    for (fk in active) {
      ids <- if (fk %in% names(ids_year)) ids_year[[fk]] else character(0)
      acc[[fk]][[as.character(yr)]] <- .aggregate_year(sc, ids)
    }

    rm(sc, ids_year); gc(verbose = FALSE)
    if (verbose) message("  year ", yr, ": aggregated ", length(active), " figure(s)")
  }

  message("\nFinalizing panels...")
  for (fk in todo) {
    tryCatch(.finalize_panel(fk, acc[[fk]], out_dir),
             error = function(e) message("  ERROR finalizing ", fk, ": ", e$message))
    acc[[fk]] <- NULL
    gc(verbose = FALSE)
  }
  message("\nAll antisemitism panels built.")
  invisible(NULL)
}
