# overnight_scoring.R — Optimized parallel RF scoring + pipeline completion
# Designed for overnight unattended run on 128 GB / 32-core system
# Uses ~80% resources: 6 parallel workers, ~15 GB peak each
#
# Usage: Rscript R/overnight_scoring.R
# Monitor: type output\logs\overnight_master.log
# Check progress: dir data_panels\rf_scored\*.parquet | find /c ".parquet"

cat("==========================================================\n")
cat("  OVERNIGHT RF SCORING + PIPELINE RUN\n")
cat("  Started:", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n")
cat("==========================================================\n\n")

source("C:/Users/ammonsj/Ideas/_config.R")

library(arrow)
library(data.table)

# --- Configuration ---
N_WORKERS     <- 6L      # 6 parallel workers (~80% of 32 cores)
CHUNK_SIZE    <- 50000L   # 50K rows per chunk (safe for 15 GB peak)
POLL_INTERVAL <- 30       # seconds between progress checks

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

# Sort largest first so big jobs start early and don't become stragglers
missing <- missing[order(-missing$size_mb), ]

cat("Total source years:", length(scored_files), "\n")
cat("Already RF-scored:", length(rf_done_yrs), "\n")
cat("Missing (to process):", nrow(missing), "\n")
cat("Total data:", round(sum(missing$size_mb) / 1024, 1), "GB\n")
cat("Workers:", N_WORKERS, "\n")
cat("Chunk size:", format(CHUNK_SIZE, big.mark = ","), "\n\n")

if (nrow(missing) == 0) {
  cat("All years already scored! Skipping to pipeline.\n\n")
} else {
  # --- Distribute years to workers (round-robin, largest first) ---
  worker_assignments <- vector("list", N_WORKERS)
  for (i in seq_len(N_WORKERS)) worker_assignments[[i]] <- character(0)

  for (i in seq_len(nrow(missing))) {
    w <- ((i - 1L) %% N_WORKERS) + 1L
    worker_assignments[[w]] <- c(worker_assignments[[w]], missing$year[i])
  }

  cat("Worker assignments (largest years distributed first):\n")
  for (w in seq_len(N_WORKERS)) {
    yrs <- worker_assignments[[w]]
    total_mb <- sum(missing$size_mb[missing$year %in% yrs])
    cat(sprintf("  Worker %d: %d years (%s), %.1f GB\n",
                w, length(yrs), paste(yrs, collapse = ","),
                total_mb / 1024))
  }
  cat("\n")

  # --- Write per-worker year lists to temp files ---
  worker_files <- character(N_WORKERS)
  for (w in seq_len(N_WORKERS)) {
    tf <- file.path(OUTPUT_LOGS, sprintf("worker_%d_years.txt", w))
    writeLines(worker_assignments[[w]], tf)
    worker_files[w] <- tf
  }

  # --- Write the worker script with reduced chunk size ---
  worker_script <- file.path(PROJECT_ROOT, "R", "_overnight_worker.R")
  writeLines(c(
    '# Auto-generated overnight worker script',
    'args <- commandArgs(trailingOnly = TRUE)',
    'worker_id <- as.integer(args[1])',
    'years_file <- args[2]',
    'worker_years <- readLines(years_file)',
    '',
    'cat(sprintf("[Worker %d] Starting with %d years\\n", worker_id, length(worker_years)))',
    'flush.console()',
    '',
    'source("C:/Users/ammonsj/Ideas/_config.R")',
    'source("C:/Users/ammonsj/Ideas/R/helpers.R")',
    '',
    'library(arrow)',
    'library(data.table)',
    'library(ranger)',
    'library(quanteda)',
    '',
    '# Load model artifacts once',
    'rf_final     <- readRDS(file.path(MODELS_DIR, "rf_incivility_model.rds"))',
    'calibrate_fn <- readRDS(file.path(MODELS_DIR, "calibration_fn.rds"))',
    'feature_cols <- readRDS(file.path(MODELS_DIR, "feature_cols.rds"))',
    'svd_info     <- readRDS(file.path(MODELS_DIR, "svd_model_info.rds"))',
    'cat(sprintf("[Worker %d] Model loaded.\\n", worker_id))',
    'flush.console()',
    '',
    'scored_dir    <- file.path(DATA_PARQUET, "articles_scored")',
    'rf_scored_dir <- file.path(DATA_PANELS, "rf_scored")',
    'dir.create(rf_scored_dir, recursive = TRUE, showWarnings = FALSE)',
    '',
    sprintf('chunk_size <- %dL', CHUNK_SIZE),
    '',
    'for (yr in worker_years) {',
    '  outpath <- file.path(rf_scored_dir, paste0("rf_scored_", yr, ".parquet"))',
    '  if (file.exists(outpath)) {',
    '    cat(sprintf("[Worker %d] Year %s already done, skipping.\\n", worker_id, yr))',
    '    flush.console()',
    '    next',
    '  }',
    '',
    '  sf <- file.path(scored_dir, paste0("scored_", yr, ".parquet"))',
    '  if (!file.exists(sf)) {',
    '    cat(sprintf("[Worker %d] Year %s source missing, skipping.\\n", worker_id, yr))',
    '    flush.console()',
    '    next',
    '  }',
    '',
    '  t0 <- Sys.time()',
    '  cat(sprintf("[Worker %d] === Year %s ===\\n", worker_id, yr))',
    '  flush.console()',
    '',
    '  dt_year <- as.data.table(read_parquet(sf))',
    '  dt_year[, p_incivil_lexicon := uncivil_score]',
    '  dt_year[, p_incivil := NA_real_]',
    '',
    '  n_total  <- nrow(dt_year)',
    '  n_chunks <- ceiling(n_total / chunk_size)',
    '  cat(sprintf("[Worker %d]   %d articles, %d chunks\\n", worker_id, n_total, n_chunks))',
    '  flush.console()',
    '',
    '  for (ci in seq_len(n_chunks)) {',
    '    row_start <- (ci - 1L) * chunk_size + 1L',
    '    row_end   <- min(ci * chunk_size, n_total)',
    '    chunk_rows <- row_start:row_end',
    '',
    '    tryCatch({',
    '      chunk_text <- dt_year$article[chunk_rows]',
    '      corp_c <- corpus(chunk_text)',
    '      toks_c <- tokens(corp_c, remove_punct = TRUE, remove_numbers = TRUE,',
    '                       remove_symbols = TRUE) |>',
    '        tokens_tolower() |>',
    '        tokens_remove(stopwords("en")) |>',
    '        tokens_wordstem()',
    '',
    '      dfmat_c <- dfm(toks_c)',
    '      dfmat_c <- dfm_tfidf(dfmat_c)',
    '      dfmat_c <- dfm_match(dfmat_c, svd_info$vocab)',
    '',
    '      mat_c <- as.matrix(dfmat_c)',
    '      if (!is.null(svd_info$center)) {',
    '        mat_c <- sweep(mat_c, 2, svd_info$center)',
    '      }',
    '      svd_scores <- mat_c %*% svd_info$rotation',
    '',
    '      svd_dt <- as.data.table(svd_scores)',
    '      names(svd_dt) <- paste0("svd_", seq_len(ncol(svd_dt)))',
    '',
    '      meta_c <- dt_year[chunk_rows, .(front_page, headline_length, n_words,',
    '                                       has_byline, ocr_quality, page_num,',
    '                                       insult_score, dehumanize_score,',
    '                                       violence_score, conspiracy_score,',
    '                                       intolerance_score)]',
    '      feat_c <- cbind(meta_c, svd_dt)',
    '',
    '      for (fc in feature_cols) {',
    '        if (!fc %in% names(feat_c)) feat_c[, (fc) := 0]',
    '      }',
    '      feat_c <- feat_c[, ..feature_cols]',
    '      for (col in feature_cols) {',
    '        set(feat_c, which(is.na(feat_c[[col]])), col, 0)',
    '      }',
    '',
    '      pred_c <- predict(rf_final, feat_c)',
    '      set(dt_year, chunk_rows, "p_incivil",',
    '          calibrate_fn(pred_c$predictions[, "1"]))',
    '',
    '      rm(corp_c, toks_c, dfmat_c, mat_c, svd_scores, svd_dt, meta_c, feat_c, pred_c, chunk_text)',
    '      gc()',
    '',
    '      cat(sprintf("[Worker %d]   chunk %d/%d done\\n", worker_id, ci, n_chunks))',
    '      flush.console()',
    '    }, error = function(e) {',
    '      cat(sprintf("[Worker %d]   chunk %d/%d FAILED: %s -> lexicon fallback\\n",',
    '                  worker_id, ci, n_chunks, e$message))',
    '      flush.console()',
    '      set(dt_year, chunk_rows, "p_incivil",',
    '          dt_year$uncivil_score[chunk_rows])',
    '      gc()',
    '    })',
    '  }',
    '',
    '  dt_year[is.na(p_incivil), p_incivil := uncivil_score]',
    '',
    '  write_parquet(',
    '    dt_year[, .(article_id, newspaper_name, year, year_month, date,',
    '                front_page, n_words, page_num, ocr_quality,',
    '                uncivil_score, p_incivil, p_incivil_lexicon)],',
    '    outpath',
    '  )',
    '',
    '  elapsed <- round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1)',
    '  cat(sprintf("[Worker %d]   Year %s DONE — %d articles in %s min\\n",',
    '              worker_id, yr, n_total, elapsed))',
    '  flush.console()',
    '',
    '  rm(dt_year)',
    '  gc()',
    '}',
    '',
    'cat(sprintf("[Worker %d] All years complete!\\n", worker_id))'
  ), worker_script)

  cat("Worker script written to:", worker_script, "\n\n")

  # --- Launch workers via PowerShell (reliable background process on Windows) ---
  cat("Launching", N_WORKERS, "workers...\n")
  flush.console()

  for (w in seq_len(N_WORKERS)) {
    log_file <- file.path(OUTPUT_LOGS, sprintf("overnight_worker_%d.log", w))

    # Use PowerShell Start-Process for reliable background launching on Windows
    ps_cmd <- sprintf(
      'Start-Process -FilePath "%s" -ArgumentList @("%s", "%d", "%s") -RedirectStandardOutput "%s" -RedirectStandardError "%s.err" -NoNewWindow -WindowStyle Hidden',
      R_EXE,
      gsub("/", "\\\\", worker_script),
      w,
      gsub("/", "\\\\", worker_files[w]),
      gsub("/", "\\\\", log_file),
      gsub("/", "\\\\", log_file)
    )
    system2("powershell", args = c("-Command", shQuote(ps_cmd)),
            wait = FALSE, stdout = NULL, stderr = NULL)
    cat(sprintf("  Worker %d launched -> %s\n", w, basename(log_file)))
    Sys.sleep(3)  # stagger launches to avoid disk contention on initial model load
  }

  cat("\nAll workers launched. Monitoring progress...\n\n")
  flush.console()

  # --- Monitor progress until all years scored ---
  target <- length(scored_files)
  t_monitor_start <- Sys.time()

  repeat {
    Sys.sleep(POLL_INTERVAL)

    n_done <- length(list.files(rf_scored_dir, pattern = "\\.parquet$"))
    n_remaining <- target - n_done
    elapsed_min <- round(as.numeric(difftime(Sys.time(), t_monitor_start, units = "mins")), 1)

    cat(sprintf("[%s] Progress: %d/%d years scored (%d remaining). Elapsed: %s min\n",
                format(Sys.time(), "%H:%M:%S"), n_done, target, n_remaining, elapsed_min))
    flush.console()

    if (n_done >= target) {
      cat("\nAll years scored!\n\n")
      break
    }

    # Check if any R processes are still running (besides ourselves)
    procs <- system2("tasklist", args = c("/FI", '"IMAGENAME eq Rscript.exe"'),
                     stdout = TRUE, stderr = TRUE)
    n_rprocs <- sum(grepl("Rscript.exe", procs))
    if (n_rprocs <= 1 && n_done < target) {
      cat("\nWARNING: All workers seem to have exited but",
          target - n_done, "years still missing!\n")
      cat("Attempting to score remaining years sequentially...\n\n")
      flush.console()

      # Fallback: score remaining years sequentially in this process
      source(file.path(PROJECT_ROOT, "R", "score_missing_years.R"))
      break
    }
  }
}

# --- Verify all years scored ---
n_final <- length(list.files(rf_scored_dir, pattern = "\\.parquet$"))
n_target <- length(scored_files)
cat(sprintf("RF scored files: %d / %d\n", n_final, n_target))

if (n_final < n_target) {
  rf_done2 <- gsub("rf_scored_(\\d{4})\\.parquet", "\\1",
                     list.files(rf_scored_dir, pattern = "\\.parquet$"))
  all_yrs <- gsub("scored_(\\d{4})\\.parquet", "\\1",
                   list.files(scored_dir, pattern = "\\.parquet$"))
  still_missing <- setdiff(all_yrs, rf_done2)
  cat("Still missing:", paste(still_missing, collapse = ", "), "\n")
  cat("WARNING: Proceeding to pipeline steps anyway (may have incomplete data).\n\n")
}

# --- Run pipeline steps 7-10 ---
cat("==========================================================\n")
cat("  RUNNING PIPELINE STEPS 7-10\n")
cat("  Started:", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n")
cat("==========================================================\n\n")
flush.console()

# Steps 7-10 in run_pipeline.R are indices 7 (06_treatment_panel),
# 8 (07_did_estimation), 9 (07b_did_modern), 10 (08_figures_tables)
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
