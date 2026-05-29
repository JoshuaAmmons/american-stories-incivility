# Extra parallel workers for 03b antisemitism scoring
# Safe to run alongside existing 03b — file.exists() skip logic prevents duplication
# Each worker reads a file, scores it, writes output. If output already exists, skips.

source("C:/Users/ammonsj/Ideas/_config.R")
source("C:/Users/ammonsj/Ideas/R/helpers.R")
library(parallel)

scored_dir  <- file.path(DATA_PARQUET, "articles_scored")
antisem_dir <- file.path(DATA_PARQUET, "articles_antisem_scored")

# Get ALL source files — worker will skip any already done
all_files <- list.files(scored_dir, pattern = "\\.parquet$", full.names = TRUE)

# Sort by file size DESCENDING so big files get picked up first
# (the original workers got them alphabetically; we want to hit unclaimed big ones)
sizes <- file.size(all_files)
all_files <- all_files[order(sizes, decreasing = TRUE)]

todo_files <- all_files[!sapply(all_files, function(sf) {
  yr <- gsub(".*scored_(\\d{4})\\.parquet", "\\1", sf)
  file.exists(file.path(antisem_dir, paste0("antisem_scored_", yr, ".parquet")))
})]

message(length(all_files) - length(todo_files), " already done. ",
        length(todo_files), " candidates for extra workers.")

if (length(todo_files) == 0) {
  message("Nothing to do!")
  quit(save = "no")
}

score_one_year <- function(sf, antisem_dir, lexicon, terms_all, helpers_path) {
  library(arrow)
  library(data.table)
  source(helpers_path)

  yr <- gsub(".*scored_(\\d{4})\\.parquet", "\\1", sf)
  outpath <- file.path(antisem_dir, paste0("antisem_scored_", yr, ".parquet"))

  # Skip if another worker already finished this file
  if (file.exists(outpath)) return(paste0("Year ", yr, ": already exists, skipped"))

  # Use a temp file + rename to prevent partial-read by other workers
  tmppath <- paste0(outpath, ".tmp")

  t0 <- Sys.time()
  dt <- as.data.table(arrow::read_parquet(sf))
  n_rows <- nrow(dt)

  dt[, antisem_score := lexicon_score(article, terms_all)]
  for (cat_name in names(lexicon)) {
    col_name <- paste0("antisem_", cat_name, "_score")
    dt[, (col_name) := lexicon_score(article, lexicon[[cat_name]])]
  }

  arrow::write_parquet(dt, tmppath)
  file.rename(tmppath, outpath)
  rm(dt); gc()

  elapsed <- round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1)
  paste0("Year ", yr, ": ", format(n_rows, big.mark = ","), " articles in ", elapsed, " min")
}

N_EXTRA <- 2L
message("Launching ", N_EXTRA, " extra workers at ", Sys.time())

cl <- makeCluster(N_EXTRA)
results <- parLapply(cl, todo_files, score_one_year,
                     antisem_dir = antisem_dir,
                     lexicon     = ANTISEM_LEXICON,
                     terms_all   = ANTISEM_TERMS_ALL,
                     helpers_path = "C:/Users/ammonsj/Ideas/R/helpers.R")
stopCluster(cl)

for (r in results) message(r)
message("\nExtra workers finished at ", Sys.time())
