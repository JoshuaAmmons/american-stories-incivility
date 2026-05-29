# DEPRECATED: Use R/_overnight_worker.R instead. This script has known bugs:
#   - dfm_tfidf() called BEFORE dfm_match() (wrong TF-IDF computation)
#   - IDF weights recomputed per-chunk instead of using saved training weights
#   - Lexicon fallback uses raw uncivil_score (not scaled to [0,1])
# See R/_overnight_worker.R for the fixed, GPU-accelerated version.
stop("DEPRECATED: Use R/_overnight_worker.R with R/_launch_parallel_scoring.ps1 instead.")

# R/score_worker.R — Score a batch of years with the trained RF model
# Usage: Rscript R/score_worker.R 1858 1859 1860 ...
#
# Each worker loads the RF model once, then iterates through its assigned years.
# Skips years already scored. Safe to run multiple workers in parallel.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) == 0) stop("Usage: Rscript R/score_worker.R <year1> <year2> ...")

worker_years <- args
worker_id <- Sys.getpid()
cat(sprintf("[Worker %d] Assigned %d years: %s\n",
            worker_id, length(worker_years),
            paste(worker_years[1], "...", tail(worker_years, 1))))

# Load config and helpers
source("C:/Users/ammonsj/Ideas/_config.R")
source("C:/Users/ammonsj/Ideas/R/helpers.R")

library(arrow)
library(data.table)
library(ranger)
library(quanteda)

# Load model artifacts (once per worker)
cat(sprintf("[Worker %d] Loading RF model...\n", worker_id))
rf_final     <- readRDS(file.path(MODELS_DIR, "rf_incivility_model.rds"))
calibrate_fn <- readRDS(file.path(MODELS_DIR, "calibration_fn.rds"))
feature_cols <- readRDS(file.path(MODELS_DIR, "feature_cols.rds"))
svd_info     <- readRDS(file.path(MODELS_DIR, "svd_model_info.rds"))
cat(sprintf("[Worker %d] Model loaded (%d features).\n", worker_id, length(feature_cols)))

scored_dir    <- file.path(DATA_PARQUET, "articles_scored")
rf_scored_dir <- file.path(DATA_PANELS, "rf_scored")
dir.create(rf_scored_dir, recursive = TRUE, showWarnings = FALSE)

chunk_size <- 200000L

for (yr in worker_years) {
  outpath <- file.path(rf_scored_dir, paste0("rf_scored_", yr, ".parquet"))

  if (file.exists(outpath)) {
    cat(sprintf("[Worker %d] Year %s already scored, skipping.\n", worker_id, yr))
    next
  }

  sf <- file.path(scored_dir, paste0("scored_", yr, ".parquet"))
  if (!file.exists(sf)) {
    cat(sprintf("[Worker %d] Year %s source file not found, skipping.\n", worker_id, yr))
    next
  }

  t0 <- Sys.time()
  cat(sprintf("[Worker %d] Scoring year %s...\n", worker_id, yr))

  dt_year <- as.data.table(read_parquet(sf))
  dt_year[, p_incivil_lexicon := uncivil_score]
  dt_year[, p_incivil := NA_real_]

  n_total  <- nrow(dt_year)
  n_chunks <- ceiling(n_total / chunk_size)
  cat(sprintf("[Worker %d]   Year %s: %d articles, %d chunks\n",
              worker_id, yr, n_total, n_chunks))

  for (ci in seq_len(n_chunks)) {
    row_start <- (ci - 1L) * chunk_size + 1L
    row_end   <- min(ci * chunk_size, n_total)
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

      cat(sprintf("[Worker %d]   Year %s chunk %d/%d done\n",
                  worker_id, yr, ci, n_chunks))
    }, error = function(e) {
      cat(sprintf("[Worker %d]   Year %s chunk %d FAILED: %s -> lexicon fallback\n",
                  worker_id, yr, ci, e$message))
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

  elapsed <- round(difftime(Sys.time(), t0, units = "mins"), 1)
  cat(sprintf("[Worker %d]   Year %s DONE — %d articles in %s min. Saved to %s\n",
              worker_id, yr, n_total, elapsed, basename(outpath)))

  rm(dt_year)
  gc()
}

cat(sprintf("[Worker %d] All assigned years complete.\n", worker_id))
