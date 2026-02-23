# overnight_scoring_v2.R — Parallel RF scoring using R's parallel package
# No external process launching — uses mclapply/parLapply for reliable parallelism
#
# Usage: Rscript R/overnight_scoring_v2.R
# Monitor: type output\logs\overnight_v2.log

cat("==========================================================\n")
cat("  OVERNIGHT RF SCORING + PIPELINE RUN (v2)\n")
cat("  Started:", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n")
cat("==========================================================\n\n")
flush.console()

source("C:/Users/ammonsj/Ideas/_config.R")
source("C:/Users/ammonsj/Ideas/R/helpers.R")

library(arrow)
library(data.table)
library(ranger)
library(quanteda)
library(parallel)

# --- Configuration ---
N_WORKERS     <- 6L      # 6 parallel workers
CHUNK_SIZE    <- 50000L   # 50K rows per chunk (safe for memory)

# --- Find missing years ---
scored_dir    <- file.path(DATA_PARQUET, "articles_scored")
rf_scored_dir <- file.path(DATA_PANELS, "rf_scored")
dir.create(rf_scored_dir, recursive = TRUE, showWarnings = FALSE)

scored_files <- list.files(scored_dir, pattern = "\\.parquet$", full.names = TRUE)
rf_done      <- list.files(rf_scored_dir, pattern = "\\.parquet$")
rf_done_yrs  <- gsub("rf_scored_(\\d{4})\\.parquet", "\\1", rf_done)

missing <- data.frame(
  year = character(),
  path = character(),
  size_mb = numeric(),
  stringsAsFactors = FALSE
)

for (sf in scored_files) {
  yr <- gsub(".*scored_(\\d{4})\\.parquet", "\\1", sf)
  if (!yr %in% rf_done_yrs) {
    sz <- file.info(sf)$size / 1024^2
    missing <- rbind(missing, data.frame(year = yr, path = sf, size_mb = sz,
                                          stringsAsFactors = FALSE))
  }
}

# Sort smallest first — process quick wins early for steady progress, big years last
missing <- missing[order(missing$size_mb), ]

cat("Total source years:", length(scored_files), "\n")
cat("Already RF-scored:", length(rf_done_yrs), "\n")
cat("Missing (to process):", nrow(missing), "\n")
cat("Total data:", round(sum(missing$size_mb) / 1024, 1), "GB\n")
cat("Workers:", N_WORKERS, "\n")
cat("Chunk size:", format(CHUNK_SIZE, big.mark = ","), "\n\n")
flush.console()

if (nrow(missing) == 0) {
  cat("All years already scored! Skipping to pipeline.\n\n")
} else {
  # --- Load model artifacts (shared across workers via fork) ---
  cat("Loading model artifacts...\n")
  flush.console()
  rf_final     <- readRDS(file.path(MODELS_DIR, "rf_incivility_model.rds"))
  calibrate_fn <- readRDS(file.path(MODELS_DIR, "calibration_fn.rds"))
  feature_cols <- readRDS(file.path(MODELS_DIR, "feature_cols.rds"))
  svd_info     <- readRDS(file.path(MODELS_DIR, "svd_model_info.rds"))
  cat("Model loaded. Features:", length(feature_cols), "\n\n")
  flush.console()

  # --- Scoring function for one year ---
  score_one_year <- function(yr) {
    outpath <- file.path(rf_scored_dir, paste0("rf_scored_", yr, ".parquet"))

    # Skip if already done (race condition safe)
    if (file.exists(outpath)) {
      return(paste0("Year ", yr, ": already done"))
    }

    sf <- file.path(scored_dir, paste0("scored_", yr, ".parquet"))
    if (!file.exists(sf)) {
      return(paste0("Year ", yr, ": source missing"))
    }

    t0 <- Sys.time()

    tryCatch({
      dt_year <- as.data.table(read_parquet(sf))
      dt_year[, p_incivil_lexicon := uncivil_score]
      dt_year[, p_incivil := NA_real_]

      n_total  <- nrow(dt_year)
      n_chunks <- ceiling(n_total / CHUNK_SIZE)

      for (ci in seq_len(n_chunks)) {
        row_start <- (ci - 1L) * CHUNK_SIZE + 1L
        row_end   <- min(ci * CHUNK_SIZE, n_total)
        chunk_rows <- row_start:row_end

        tryCatch({
          chunk_text <- dt_year$article[chunk_rows]
          corp_c <- corpus(chunk_text)
          toks_c <- tokens(corp_c, remove_punct = TRUE, remove_numbers = TRUE,
                           remove_symbols = TRUE) |>
            tokens_tolower() |>
            tokens_remove(stopwords("en")) |>
            tokens_wordstem()

          dfmat_c <- dfm(toks_c)
          dfmat_c <- dfm_tfidf(dfmat_c)
          dfmat_c <- dfm_match(dfmat_c, svd_info$vocab)

          mat_c <- as.matrix(dfmat_c)
          if (!is.null(svd_info$center)) {
            mat_c <- sweep(mat_c, 2, svd_info$center)
          }
          svd_scores <- mat_c %*% svd_info$rotation

          svd_dt <- as.data.table(svd_scores)
          names(svd_dt) <- paste0("svd_", seq_len(ncol(svd_dt)))

          meta_c <- dt_year[chunk_rows, .(front_page, headline_length, n_words,
                                           has_byline, ocr_quality, page_num,
                                           insult_score, dehumanize_score,
                                           violence_score, conspiracy_score,
                                           intolerance_score)]
          feat_c <- cbind(meta_c, svd_dt)

          for (fc in feature_cols) {
            if (!fc %in% names(feat_c)) feat_c[, (fc) := 0]
          }
          feat_c <- feat_c[, ..feature_cols]
          for (col in feature_cols) {
            set(feat_c, which(is.na(feat_c[[col]])), col, 0)
          }

          pred_c <- predict(rf_final, feat_c, num.threads = 5L)
          set(dt_year, chunk_rows, "p_incivil",
              calibrate_fn(pred_c$predictions[, "1"]))

          rm(corp_c, toks_c, dfmat_c, mat_c, svd_scores, svd_dt,
             meta_c, feat_c, pred_c, chunk_text)
          gc()
        }, error = function(e) {
          set(dt_year, chunk_rows, "p_incivil",
              dt_year$uncivil_score[chunk_rows])
          gc()
        })
      }

      # Fill remaining NAs with lexicon fallback
      dt_year[is.na(p_incivil), p_incivil := uncivil_score]

      write_parquet(
        dt_year[, .(article_id, newspaper_name, year, year_month, date,
                    front_page, n_words, page_num, ocr_quality,
                    uncivil_score, p_incivil, p_incivil_lexicon)],
        outpath
      )

      elapsed <- round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1)
      rm(dt_year)
      gc()

      paste0("Year ", yr, ": DONE (", n_total, " articles, ", elapsed, " min)")
    }, error = function(e) {
      paste0("Year ", yr, ": FAILED - ", e$message)
    })
  }

  # --- Run in parallel using PSOCK cluster (Windows-compatible) ---
  cat("Creating cluster with", N_WORKERS, "workers...\n")
  flush.console()

  cl <- makeCluster(N_WORKERS, type = "PSOCK", outfile = file.path(OUTPUT_LOGS, "cluster_workers.log"))

  # Export everything workers need
  clusterExport(cl, c("rf_final", "calibrate_fn", "feature_cols", "svd_info",
                        "scored_dir", "rf_scored_dir", "CHUNK_SIZE",
                        "MODELS_DIR", "DATA_PARQUET", "DATA_PANELS",
                        "PROJECT_ROOT"))

  # Load libraries on each worker and limit threading
  clusterEvalQ(cl, {
    # CRITICAL: Limit threads per worker to avoid 192-thread contention
    # 6 workers x 5 threads = 30, fitting in 32 logical processors
    threads_per_worker <- 5L
    Sys.setenv(
      OMP_NUM_THREADS = threads_per_worker,
      OPENBLAS_NUM_THREADS = threads_per_worker,
      MKL_NUM_THREADS = threads_per_worker
    )
    library(arrow)
    library(data.table)
    data.table::setDTthreads(threads_per_worker)
    library(ranger)
    library(quanteda)
    quanteda_options(threads = threads_per_worker)
  })

  cat("Cluster ready. Scoring", nrow(missing), "years...\n\n")
  flush.console()

  # Process years — parLapplyLB gives load-balanced distribution
  t_scoring_start <- Sys.time()
  results <- parLapplyLB(cl, missing$year, score_one_year)

  stopCluster(cl)

  # Print results
  cat("\n=== SCORING RESULTS ===\n")
  for (r in results) {
    cat(" ", r, "\n")
  }
  scoring_elapsed <- round(as.numeric(difftime(Sys.time(), t_scoring_start, units = "hours")), 1)
  cat(sprintf("\nTotal scoring time: %s hours\n\n", scoring_elapsed))
  flush.console()
}

# --- Verify all years scored ---
n_final <- length(list.files(rf_scored_dir, pattern = "\\.parquet$"))
n_target <- length(scored_files)
cat(sprintf("RF scored files: %d / %d\n\n", n_final, n_target))
flush.console()

if (n_final < n_target) {
  rf_done2 <- gsub("rf_scored_(\\d{4})\\.parquet", "\\1",
                     list.files(rf_scored_dir, pattern = "\\.parquet$"))
  all_yrs <- gsub("scored_(\\d{4})\\.parquet", "\\1",
                   list.files(scored_dir, pattern = "\\.parquet$"))
  still_missing <- setdiff(all_yrs, rf_done2)
  cat("Still missing:", paste(still_missing, collapse = ", "), "\n")
  cat("WARNING: Proceeding to pipeline steps with incomplete data.\n\n")
}

# --- Run pipeline steps 7-10 ---
cat("==========================================================\n")
cat("  RUNNING PIPELINE STEPS 7-10\n")
cat("  Started:", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n")
cat("==========================================================\n\n")
flush.console()

pipeline_steps <- list(
  list(idx = 7, rmd = "rmd/06_treatment_panel.Rmd",  name = "06_treatment_panel"),
  list(idx = 8, rmd = "rmd/07_did_estimation.Rmd",   name = "07_did_estimation"),
  list(idx = 9, rmd = "rmd/07b_did_modern.Rmd",      name = "07b_did_modern"),
  list(idx = 10, rmd = "rmd/08_figures_tables.Rmd",   name = "08_figures_tables")
)

for (step in pipeline_steps) {
  rmd_file  <- file.path(PROJECT_ROOT, step$rmd)
  timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
  log_file  <- file.path(OUTPUT_LOGS, paste0(step$name, "_", timestamp, ".log"))
  html_file <- file.path(OUTPUT_HTML, paste0(step$name, ".html"))

  cat(sprintf("--- Step %d: %s ---\n", step$idx, step$name))
  cat(sprintf("  Log: %s\n", log_file))
  flush.console()

  start_time <- Sys.time()

  result <- tryCatch({
    log_con <- file(log_file, open = "wt")
    sink(log_con, type = "message")

    rmarkdown::render(
      input = rmd_file,
      output_file = html_file,
      output_format = "html_document",
      envir = new.env(parent = globalenv()),
      quiet = FALSE
    )

    sink(type = "message")
    close(log_con)
    list(success = TRUE, error = NULL)
  }, error = function(e) {
    try(sink(type = "message"), silent = TRUE)
    try(close(log_con), silent = TRUE)
    cat(paste0("\n\nERROR:\n", conditionMessage(e), "\n"),
        file = log_file, append = TRUE)
    list(success = FALSE, error = conditionMessage(e))
  })

  elapsed <- round(as.numeric(difftime(Sys.time(), start_time, units = "mins")), 1)

  if (result$success) {
    cat(sprintf("  Status: SUCCESS (%s min)\n\n", elapsed))
  } else {
    cat(sprintf("  Status: FAILED (%s min)\n", elapsed))
    cat(sprintf("  Error: %s\n", result$error))
    cat(sprintf("  See log: %s\n\n", log_file))
    cat("Continuing to next step...\n\n")
  }
  flush.console()
}

cat("==========================================================\n")
cat("  OVERNIGHT RUN COMPLETE\n")
cat("  Finished:", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n")
cat("==========================================================\n")
