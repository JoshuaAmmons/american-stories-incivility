###############################################################################
# 03b Tier Worker — processes a tier's file list with N parallel workers
#
# Usage: Rscript 03b_tier_worker.R <tier_number> <n_workers>
#   tier_number: 1 (huge), 2 (large), 3 (small)
#   n_workers:   how many parallel workers for this tier
###############################################################################

args <- commandArgs(trailingOnly = TRUE)
tier_num  <- as.integer(args[1])
n_workers <- as.integer(args[2])

tier_names <- c("tier1_huge", "tier2_large", "tier3_small")
tier_name  <- tier_names[tier_num]

message("=== TIER ", tier_num, " (", tier_name, ") starting with ",
        n_workers, " worker(s) at ", Sys.time(), " ===")

source("C:/Users/ammonsj/Ideas/_config.R")
source("C:/Users/ammonsj/Ideas/R/helpers.R")

antisem_dir <- file.path(DATA_PARQUET, "articles_antisem_scored")

# Load file assignments
tier_file <- file.path("output", "tier_assignments", paste0(tier_name, ".rds"))
file_list <- readRDS(tier_file)

# Re-filter to skip anything completed since assignment
get_yr <- function(f) gsub(".*scored_(\\d{4})\\.parquet", "\\1", f)
already_done <- sapply(file_list, function(f) {
  yr <- get_yr(f)
  file.exists(file.path(antisem_dir, paste0("antisem_scored_", yr, ".parquet")))
})
file_list <- file_list[!already_done]

message("Files to process: ", length(file_list),
        " (skipped ", sum(already_done), " already done)")

if (length(file_list) == 0) {
  message("Nothing to do for this tier!")
  quit(save = "no")
}

# ---- Worker function ----
score_files <- function(my_files, antisem_dir, lexicon, terms_all,
                        helpers_path, worker_id) {
  library(arrow)
  library(data.table)
  source(helpers_path)

  results <- character(0)
  for (sf in my_files) {
    yr <- gsub(".*scored_(\\d{4})\\.parquet", "\\1", sf)
    outpath <- file.path(antisem_dir, paste0("antisem_scored_", yr, ".parquet"))

    if (file.exists(outpath)) {
      results <- c(results, paste0("[W", worker_id, "] Year ", yr, ": skipped"))
      next
    }

    t0 <- Sys.time()
    dt <- as.data.table(read_parquet(sf))
    n_rows <- nrow(dt)

    dt[, antisem_score := lexicon_score(article, terms_all)]
    for (cat_name in names(lexicon)) {
      col_name <- paste0("antisem_", cat_name, "_score")
      dt[, (col_name) := lexicon_score(article, lexicon[[cat_name]])]
    }

    tmppath <- paste0(outpath, ".tmp")
    write_parquet(dt, tmppath)
    file.rename(tmppath, outpath)
    rm(dt); gc()

    elapsed <- round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1)
    msg <- paste0("[W", worker_id, "] Year ", yr, ": ",
                  format(n_rows, big.mark = ","), " articles in ", elapsed, " min")
    results <- c(results, msg)
    # Flush progress to log
    message(msg)
  }
  results
}

t_start <- Sys.time()

if (n_workers == 1L) {
  # Single worker — no cluster overhead
  results <- score_files(file_list, antisem_dir, ANTISEM_LEXICON,
                         ANTISEM_TERMS_ALL,
                         "C:/Users/ammonsj/Ideas/R/helpers.R", "1")
} else {
  library(parallel)

  # Split files round-robin across workers
  assignments <- vector("list", n_workers)
  for (i in seq_along(file_list)) {
    w <- ((i - 1) %% n_workers) + 1
    assignments[[w]] <- c(assignments[[w]], file_list[i])
  }

  for (w in seq_along(assignments)) {
    message("  Worker ", w, ": ", length(assignments[[w]]), " files")
  }

  cl <- makeCluster(n_workers)
  results <- clusterMap(cl, score_files,
    my_files  = assignments,
    worker_id = seq_len(n_workers),
    MoreArgs = list(
      antisem_dir  = antisem_dir,
      lexicon      = ANTISEM_LEXICON,
      terms_all    = ANTISEM_TERMS_ALL,
      helpers_path = "C:/Users/ammonsj/Ideas/R/helpers.R"
    ),
    SIMPLIFY = FALSE
  )
  stopCluster(cl)
}

elapsed_total <- round(as.numeric(difftime(Sys.time(), t_start, units = "mins")), 1)
message("\n=== TIER ", tier_num, " COMPLETE. Wall time: ", elapsed_total, " min ===")
