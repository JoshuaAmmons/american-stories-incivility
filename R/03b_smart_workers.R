###############################################################################
# 03b Smart Worker Manager — Antisemitism Lexicon Scoring
#
# Strategy: Run 3 tiers concurrently as SEPARATE clusters to avoid
# one massive cluster. Each tier manages its own workers.
#   Tier 1: 1 worker  — huge files (>3GB), one at a time
#   Tier 2: 2 workers — large files (1.5-3GB)
#   Tier 3: 4 workers — small+medium files (<1.5GB)
#
# All tiers run in parallel using the 'future' pattern:
# We launch each tier's Rscript as a background process.
###############################################################################

source("C:/Users/ammonsj/Ideas/_config.R")
source("C:/Users/ammonsj/Ideas/R/helpers.R")

scored_dir  <- file.path(DATA_PARQUET, "articles_scored")
antisem_dir <- file.path(DATA_PARQUET, "articles_antisem_scored")
dir.create(antisem_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(ANTISEM_LEXICON, file.path(MODELS_DIR, "antisem_lexicon.rds"))

# ---- Identify remaining files ----
all_files <- list.files(scored_dir, pattern = "\\.parquet$", full.names = TRUE)
done_files <- list.files(antisem_dir, pattern = "\\.parquet$")
done_yrs <- gsub("antisem_scored_(\\d{4})\\.parquet", "\\1", done_files)
get_yr <- function(f) gsub(".*scored_(\\d{4})\\.parquet", "\\1", f)
todo_mask <- !(sapply(all_files, get_yr) %in% done_yrs)
todo_files <- all_files[todo_mask]
todo_sizes <- file.size(todo_files)

message(sum(!todo_mask), " / ", length(all_files), " years already done. ",
        length(todo_files), " remaining.")

if (length(todo_files) == 0) {
  message("Nothing to do!")
  quit(save = "no")
}

# ---- Categorise ----
huge_files  <- todo_files[todo_sizes > 3e9]
huge_files  <- huge_files[order(file.size(huge_files), decreasing = TRUE)]

large_files <- todo_files[todo_sizes >= 1.5e9 & todo_sizes <= 3e9]
large_files <- large_files[order(file.size(large_files), decreasing = TRUE)]

small_files <- todo_files[todo_sizes < 1.5e9]
small_files <- small_files[order(file.size(small_files), decreasing = TRUE)]

message("Huge:  ", length(huge_files), " files")
message("Large: ", length(large_files), " files")
message("Small: ", length(small_files), " files")

# ---- Save file lists for each tier ----
tier_dir <- file.path("output", "tier_assignments")
dir.create(tier_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(huge_files,  file.path(tier_dir, "tier1_huge.rds"))
saveRDS(large_files, file.path(tier_dir, "tier2_large.rds"))
saveRDS(small_files, file.path(tier_dir, "tier3_small.rds"))

message("File lists saved. Launching 3 tier scripts...")

# ---- Launch each tier as a separate background Rscript ----
rscript <- "C:/Program Files/R/R-4.4.1/bin/Rscript.exe"
log_dir <- "output/logs"

# Tier 1: 1 worker for huge files
system2(rscript, args = c("R/03b_tier_worker.R", "1", "1"),
        stdout = file.path(log_dir, "03b_tier1.log"),
        stderr = file.path(log_dir, "03b_tier1.log"),
        wait = FALSE)

# Tier 2: 2 workers for large files
system2(rscript, args = c("R/03b_tier_worker.R", "2", "2"),
        stdout = file.path(log_dir, "03b_tier2.log"),
        stderr = file.path(log_dir, "03b_tier2.log"),
        wait = FALSE)

# Tier 3: 4 workers for small files
system2(rscript, args = c("R/03b_tier_worker.R", "3", "4"),
        stdout = file.path(log_dir, "03b_tier3.log"),
        stderr = file.path(log_dir, "03b_tier3.log"),
        wait = FALSE)

message("All 3 tiers launched (7 total workers). Monitor with:")
message("  tail -f output/logs/03b_tier1.log")
message("  tail -f output/logs/03b_tier2.log")
message("  tail -f output/logs/03b_tier3.log")
message("\nParent exiting. Workers continue independently.")
