# R/extract_figure_articles.R — Extract figure-mentioning articles for all figures
#
# Per-figure extraction (high quality) with PARALLELISM across figures.
# Each figure gets its own clean extraction pass through the year files.
# Multiple figures run concurrently to maximize throughput on 128GB RAM.
#
# Output: data_panels/figure_articles/{fig_key}_articles.parquet
#         data_panels/figure_articles/high_lexicon_articles.parquet
#
# Usage:
#   Rscript R/extract_figure_articles.R

source("C:/Users/ammonsj/Ideas/_config.R")

library(data.table)
library(arrow)
library(parallel)

t_start <- Sys.time()

progress_file <- file.path(DATA_PANELS, ".overnight_progress.txt")
log_msg <- function(msg) {
  elapsed <- round(as.numeric(difftime(Sys.time(), t_start, units = "mins")), 1)
  full_msg <- paste0("[", format(Sys.time(), "%H:%M:%S"), "] [", elapsed, "m] ", msg)
  message(full_msg)
  cat(full_msg, "\n", file = progress_file, append = TRUE)
}

cat("=== Figure Article Extraction Started: ", as.character(Sys.time()), " ===\n",
    file = progress_file)

# Output directory
out_dir <- file.path(DATA_PANELS, "figure_articles")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# Source files
antisem_dir <- file.path(DATA_PARQUET, "articles_antisem_scored")
if (!dir.exists(antisem_dir)) stop("Antisemitism-scored directory not found")

KEEP_COLS <- c("article_id", "newspaper_name", "year", "date", "headline",
               "article", "n_words", "ocr_quality",
               "uncivil_score", "antisem_score")

# Identify which figures still need extraction
figures_todo <- list()
for (fig_key in names(FIGURES)) {
  out_path <- file.path(out_dir, paste0(fig_key, "_articles.parquet"))
  if (!file.exists(out_path)) {
    figures_todo[[fig_key]] <- FIGURES[[fig_key]]
  } else {
    n <- nrow(read_parquet(out_path, col_select = "article_id"))
    log_msg(paste0(fig_key, ": SKIP (already exists, ", format(n, big.mark = ","), ")"))
  }
}

log_msg(paste0(length(figures_todo), " figures remaining to extract"))

# --- Function to extract one figure ---
extract_one_figure <- function(fig_key, fig_config, antisem_dir, keep_cols, out_dir) {
  library(data.table)
  library(arrow)

  kw_pattern <- paste(fig_config$keywords, collapse = "|")
  min_year <- if (!is.null(fig_config$min_year)) fig_config$min_year else fig_config$study_start
  study_years <- min_year:fig_config$study_end

  figure_articles <- list()

  for (yr in study_years) {
    scored_file <- file.path(antisem_dir, paste0("antisem_scored_", yr, ".parquet"))
    if (!file.exists(scored_file)) next

    dt <- tryCatch({
      as.data.table(read_parquet(scored_file, col_select = keep_cols))
    }, error = function(e) {
      as.data.table(read_parquet(scored_file))
    })

    # OCR quality filter (higher = better)
    if ("ocr_quality" %in% names(dt)) {
      dt <- dt[!is.na(ocr_quality) & ocr_quality > 0.65]
    }
    if ("n_words" %in% names(dt)) {
      dt <- dt[!is.na(n_words) & n_words >= 20]
    }

    if (nrow(dt) == 0) { rm(dt); gc(verbose = FALSE); next }

    # Keyword match
    dt[, text_search := tolower(paste(
      fifelse(is.na(headline), "", headline),
      substr(fifelse(is.na(article), "", article), 1, 5000),
      sep = " "
    ))]
    hits <- dt[grepl(kw_pattern, text_search, ignore.case = TRUE, perl = TRUE)]
    hits[, text_search := NULL]

    if (nrow(hits) > 0) {
      hits[, figure_key := fig_key]
      figure_articles[[as.character(yr)]] <- hits
    }

    rm(dt, hits); gc(verbose = FALSE)
  }

  if (length(figure_articles) > 0) {
    result <- rbindlist(figure_articles, fill = TRUE)
    out_path <- file.path(out_dir, paste0(fig_key, "_articles.parquet"))
    write_parquet(result, out_path)
    return(paste0(fig_key, ": ", nrow(result), " articles"))
  } else {
    return(paste0(fig_key, ": 0 articles"))
  }
}

# --- Run figure extractions in parallel ---
if (length(figures_todo) > 0) {
  # Use 4 parallel workers — each reads multi-GB files, so RAM is the bottleneck
  # 4 workers × ~8GB peak per worker = ~32GB, well within 128GB
  N_WORKERS <- min(4L, length(figures_todo))
  log_msg(paste0("Launching ", N_WORKERS, " parallel workers for ",
                 length(figures_todo), " figures"))

  cl <- makeCluster(N_WORKERS)
  on.exit(stopCluster(cl), add = TRUE)

  # Export shared variables to workers
  clusterExport(cl, c("extract_one_figure", "figures_todo",
                       "antisem_dir", "KEEP_COLS", "out_dir"),
                envir = environment())

  results <- parLapplyLB(cl, names(figures_todo), function(fig_key) {
    extract_one_figure(
      fig_key = fig_key,
      fig_config = figures_todo[[fig_key]],
      antisem_dir = antisem_dir,
      keep_cols = KEEP_COLS,
      out_dir = out_dir
    )
  })

  stopCluster(cl)
  on.exit(NULL)

  for (r in results) {
    log_msg(r)
  }
}

# --- High-lexicon articles (sequential — one pass through all files) ---
lexicon_out <- file.path(out_dir, "high_lexicon_articles.parquet")
if (!file.exists(lexicon_out)) {
  log_msg("Extracting high antisemitism lexicon articles...")
  scored_files <- list.files(antisem_dir, pattern = "\\.parquet$", full.names = TRUE)
  lexicon_articles <- list()

  for (fi in seq_along(scored_files)) {
    f <- scored_files[fi]
    dt <- as.data.table(read_parquet(f, col_select = KEEP_COLS))
    hits <- dt[antisem_score > 0 &
               !is.na(ocr_quality) & ocr_quality > 0.65 &
               !is.na(n_words) & n_words >= 20]
    if (nrow(hits) > 0) {
      hits[, figure_key := "lexicon"]
      lexicon_articles[[basename(f)]] <- hits
    }
    rm(dt, hits); gc(verbose = FALSE)

    if (fi %% 20 == 0) {
      log_msg(paste0("  Lexicon scan: ", fi, "/", length(scored_files)))
    }
  }

  if (length(lexicon_articles) > 0) {
    lex_dt <- rbindlist(lexicon_articles, fill = TRUE)
    write_parquet(lex_dt, lexicon_out)
    log_msg(paste0("High lexicon: DONE — ", format(nrow(lex_dt), big.mark = ","), " articles"))
    rm(lex_dt, lexicon_articles)
  } else {
    log_msg("High lexicon: WARNING — 0 articles found")
  }
} else {
  log_msg("High lexicon: SKIP (already exists)")
}

gc()

elapsed <- round(as.numeric(difftime(Sys.time(), t_start, units = "mins")), 1)
log_msg(paste0("=== Figure extraction complete in ", elapsed, " minutes ==="))

# Summary
parquet_files <- list.files(out_dir, pattern = "\\.parquet$", full.names = TRUE)
for (f in parquet_files) {
  n <- nrow(read_parquet(f, col_select = "article_id"))
  log_msg(paste0("  ", basename(f), ": ", format(n, big.mark = ","), " articles"))
}
