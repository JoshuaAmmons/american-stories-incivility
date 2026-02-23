# score_missing_years.R — Score all years missing RF predictions
# Standalone script that can run autonomously in background
# Reuses the same logic as 05_random_forest.Rmd scoring chunk

cat("=== RF Scoring for Missing Years ===\n")
cat("Started:", format(Sys.time()), "\n\n")

source("C:/Users/ammonsj/Ideas/_config.R")
source("C:/Users/ammonsj/Ideas/R/helpers.R")

library(arrow)
library(data.table)
library(ranger)
library(quanteda)

# Load model artifacts
rf_final     <- readRDS(file.path(MODELS_DIR, "rf_incivility_model.rds"))
calibrate_fn <- readRDS(file.path(MODELS_DIR, "calibration_fn.rds"))
feature_cols <- readRDS(file.path(MODELS_DIR, "feature_cols.rds"))
svd_info     <- readRDS(file.path(MODELS_DIR, "svd_model_info.rds"))

cat("Model loaded with", length(feature_cols), "features.\n")
cat("SVD vocab size:", length(svd_info$vocab), "\n\n")

# Find scored input files
scored_dir <- file.path(DATA_PARQUET, "articles_scored")
scored_files <- list.files(scored_dir, pattern = "\\.parquet$", full.names = TRUE)

rf_scored_dir <- file.path(DATA_PANELS, "rf_scored")
dir.create(rf_scored_dir, recursive = TRUE, showWarnings = FALSE)

# Filter to only missing years
missing_files <- c()
for (sf in scored_files) {
  yr <- gsub(".*scored_(\\d{4})\\.parquet", "\\1", sf)
  outpath <- file.path(rf_scored_dir, paste0("rf_scored_", yr, ".parquet"))
  if (!file.exists(outpath)) {
    missing_files <- c(missing_files, sf)
  }
}

cat("Total scored files:", length(scored_files), "\n")
cat("Already RF-scored:", length(scored_files) - length(missing_files), "\n")
cat("Missing (to process):", length(missing_files), "\n\n")

if (length(missing_files) == 0) {
  cat("Nothing to do — all years already scored!\n")
  quit(save = "no", status = 0)
}

# Process each missing year
t_start <- Sys.time()
for (i in seq_along(missing_files)) {
  sf <- missing_files[i]
  yr <- gsub(".*scored_(\\d{4})\\.parquet", "\\1", sf)
  outpath <- file.path(rf_scored_dir, paste0("rf_scored_", yr, ".parquet"))

  # Double-check (in case of concurrent runs)
  if (file.exists(outpath)) {
    cat("[", i, "/", length(missing_files), "] Year", yr, "already done, skipping.\n")
    next
  }

  cat("[", i, "/", length(missing_files), "] Year", yr, "... ")
  flush.console()

  tryCatch({
    dt_year <- as.data.table(read_parquet(sf))

    dt_year[, p_incivil_lexicon := uncivil_score]
    dt_year[, p_incivil := NA_real_]

    chunk_size <- 100000L
    n_total <- nrow(dt_year)
    n_chunks <- ceiling(n_total / chunk_size)

    for (ci in seq_len(n_chunks)) {
      row_start <- (ci - 1L) * chunk_size + 1L
      row_end <- min(ci * chunk_size, n_total)
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

        pred_c <- predict(rf_final, feat_c)
        set(dt_year, chunk_rows, "p_incivil",
            calibrate_fn(pred_c$predictions[, "1"]))

        rm(corp_c, toks_c, dfmat_c, mat_c, svd_scores, svd_dt, meta_c, feat_c, pred_c)
        gc()
      }, error = function(e) {
        cat("chunk", ci, "failed:", e$message, "-> lexicon fallback. ")
        set(dt_year, chunk_rows, "p_incivil",
            dt_year$uncivil_score[chunk_rows])
      })
    }

    # Fill any remaining NAs with lexicon fallback
    dt_year[is.na(p_incivil), p_incivil := uncivil_score]

    write_parquet(
      dt_year[, .(article_id, newspaper_name, year, year_month, date,
                  front_page, n_words, page_num, ocr_quality,
                  uncivil_score, p_incivil, p_incivil_lexicon)],
      outpath
    )

    elapsed <- as.numeric(difftime(Sys.time(), t_start, units = "mins"))
    cat(nrow(dt_year), "articles scored. Elapsed:", round(elapsed, 1), "min\n")
    flush.console()

    rm(dt_year)
    gc()
  }, error = function(e) {
    cat("FAILED:", e$message, "\n")
  })
}

cat("\n=== Scoring complete ===\n")
cat("Finished:", format(Sys.time()), "\n")

# Summary
rf_files <- list.files(rf_scored_dir, pattern = "\\.parquet$")
scored_all <- list.files(scored_dir, pattern = "\\.parquet$")
cat("RF scored:", length(rf_files), "/", length(scored_all), "years\n")

still_missing <- setdiff(
  gsub("scored_(\\d{4})\\.parquet", "\\1", scored_all),
  gsub("rf_scored_(\\d{4})\\.parquet", "\\1", rf_files)
)
if (length(still_missing) > 0) {
  cat("Still missing:", paste(still_missing, collapse = ", "), "\n")
} else {
  cat("All years scored successfully!\n")
}
