# R/select_candidates_for_screening.R — Select top candidates for Flash Lite screening
#
# From the extracted figure articles + high lexicon articles,
# select the ~15K most likely antisemitic candidates:
#   - Top N most uncivil articles per figure (by RF incivility score)
#   - Top N highest antisemitism lexicon score articles per figure
#   - All high-lexicon articles
#   - Deduplicate
#
# Output: data_panels/flash_lite_candidates.parquet
#
# Usage:
#   Rscript R/select_candidates_for_screening.R

source("C:/Users/ammonsj/Ideas/_config.R")

library(data.table)
library(arrow)

t_start <- Sys.time()
progress_file <- file.path(DATA_PANELS, ".overnight_progress.txt")
log_msg <- function(msg) {
  elapsed <- round(as.numeric(difftime(Sys.time(), t_start, units = "mins")), 1)
  full_msg <- paste0("[", format(Sys.time(), "%H:%M:%S"), "] [", elapsed, "m] ", msg)
  message(full_msg)
  cat(full_msg, "\n", file = progress_file, append = TRUE)
}

# Config
TOP_PER_FIGURE_INCIVIL <- 500L   # Top N by incivility per figure
TOP_PER_FIGURE_ANTISEM <- 500L   # Top N by antisem lexicon per figure
MAX_TOTAL <- 15000L              # Hard cap

fig_dir <- file.path(DATA_PANELS, "figure_articles")
out_path <- file.path(DATA_PANELS, "flash_lite_candidates.parquet")

if (file.exists(out_path)) {
  existing <- read_parquet(out_path)
  log_msg(paste0("Candidates already exist: ", nrow(existing), " articles. Skipping."))
  quit(save = "no")
}

# --- Load all figure articles ---
fig_files <- list.files(fig_dir, pattern = "\\.parquet$", full.names = TRUE)
log_msg(paste0("Loading articles from ", length(fig_files), " figure files"))

all_candidates <- list()

for (f in fig_files) {
  fig_key <- gsub("_articles\\.parquet$", "", basename(f))
  dt <- as.data.table(read_parquet(f))
  log_msg(paste0("  ", fig_key, ": ", format(nrow(dt), big.mark = ","), " articles"))

  selected <- data.table()

  # Top by incivility (check both column names)
  incivil_col <- intersect(c("p_incivil", "uncivil_score"), names(dt))[1]
  if (!is.na(incivil_col) && sum(!is.na(dt[[incivil_col]])) > 0) {
    dt[, .incivil_rank := get(incivil_col)]
    top_incivil <- dt[!is.na(.incivil_rank)][order(-.incivil_rank)][1:min(TOP_PER_FIGURE_INCIVIL, .N)]
    top_incivil[, .incivil_rank := NULL]
    dt[, .incivil_rank := NULL]
    selected <- rbindlist(list(selected, top_incivil), fill = TRUE)
  }

  # Top by antisem lexicon score (if available)
  if ("antisem_score" %in% names(dt) && sum(dt$antisem_score > 0, na.rm = TRUE) > 0) {
    top_antisem <- dt[antisem_score > 0][order(-antisem_score)][1:min(TOP_PER_FIGURE_ANTISEM, .N)]
    selected <- rbindlist(list(selected, top_antisem), fill = TRUE)
  }

  # If neither score is available, just take all (for lexicon file)
  if (fig_key == "high_lexicon" || nrow(selected) == 0) {
    selected <- dt
  }

  # Deduplicate within this figure
  selected <- unique(selected, by = "article_id")
  selected[, source_figure := fig_key]

  all_candidates[[fig_key]] <- selected
  rm(dt, selected); gc(verbose = FALSE)
}

# Combine and deduplicate across figures
candidates <- rbindlist(all_candidates, fill = TRUE)
candidates <- unique(candidates, by = "article_id")
log_msg(paste0("Total unique candidates: ", format(nrow(candidates), big.mark = ",")))

# Cap at MAX_TOTAL if needed (prioritize by score)
if (nrow(candidates) > MAX_TOTAL) {
  # Score-based priority: antisem_score first, then incivility
  # Use whichever incivility column exists
  incivil_col <- intersect(c("p_incivil", "uncivil_score"), names(candidates))[1]
  incivil_vals <- if (!is.na(incivil_col)) candidates[[incivil_col]] else 0
  candidates[, priority_score := fifelse(!is.na(antisem_score), antisem_score, 0) +
                                  fifelse(!is.na(incivil_vals), incivil_vals * 10, 0)]
  candidates <- candidates[order(-priority_score)][1:MAX_TOTAL]
  candidates[, priority_score := NULL]
  log_msg(paste0("Capped at ", MAX_TOTAL, " articles"))
}

# Save
write_parquet(candidates, out_path)
log_msg(paste0("Saved ", format(nrow(candidates), big.mark = ","),
               " candidates to: ", out_path))

# Summary by source
log_msg("By source figure:")
summary_dt <- candidates[, .N, by = source_figure][order(-N)]
for (i in seq_len(nrow(summary_dt))) {
  log_msg(paste0("  ", summary_dt$source_figure[i], ": ",
                 format(summary_dt$N[i], big.mark = ",")))
}

elapsed <- round(as.numeric(difftime(Sys.time(), t_start, units = "mins")), 1)
log_msg(paste0("Candidate selection complete in ", elapsed, " minutes"))
