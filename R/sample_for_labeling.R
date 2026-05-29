# R/sample_for_labeling.R — Sample 4,000 articles for Claude Sonnet labeling
#
# Combines Flash Lite confirmed positives + semantic search matches
# into a stratified 4,000-article sample for labeling.
#
# Strata:
#   - Flash Lite positives (all included if <= 1000)
#   - Semantic search matches (high similarity first)
#   - High-lexicon articles not already covered
#   - Random negatives from figure articles (for training balance)
#
# Output: data_panels/labeling_sample_final.parquet
#
# Usage:
#   Rscript R/sample_for_labeling.R

source("C:/Users/ammonsj/Ideas/_config.R")

library(data.table)
library(arrow)

t_start <- Sys.time()
progress_file <- file.path(DATA_PANELS, ".overnight_progress.txt")
log_msg <- function(msg) {
  elapsed <- round(as.numeric(difftime(Sys.time(), t_start, units = "mins")), 1)
  full_msg <- paste0("[", format(Sys.time(), "%H:%M:%S"), "] [", elapsed, "m] SAMPLE: ", msg)
  message(full_msg)
  cat(full_msg, "\n", file = progress_file, append = TRUE)
}

TOTAL_SAMPLE <- 4000L
output_path <- file.path(DATA_PANELS, "labeling_sample_final.parquet")

if (file.exists(output_path)) {
  n <- nrow(read_parquet(output_path, col_select = "article_id"))
  log_msg(paste0("Sample already exists (", n, " articles). Skipping."))
  quit(save = "no")
}

set.seed(SEED)

# --- Load Flash Lite results ---
flash_path <- file.path(DATA_PANELS, "flash_lite_results.csv")
if (!file.exists(flash_path)) stop("Flash Lite results not found")
flash_dt <- fread(flash_path)
flash_positives <- flash_dt[flash_label == 1]$article_id
log_msg(paste0("Flash Lite positives: ", length(flash_positives)))

# --- Load semantic search matches ---
semantic_path <- file.path(DATA_PANELS, "semantic_matches.parquet")
has_semantic <- file.exists(semantic_path)
if (has_semantic) {
  semantic_dt <- as.data.table(read_parquet(semantic_path))
  log_msg(paste0("Semantic matches: ", nrow(semantic_dt)))
} else {
  log_msg("No semantic matches found — using Flash Lite results only")
  semantic_dt <- data.table()
}

# --- Load all figure articles for negative sampling ---
fig_dir <- file.path(DATA_PANELS, "figure_articles")
fig_files <- list.files(fig_dir, pattern = "\\.parquet$", full.names = TRUE)
# Exclude high_lexicon (those are already in candidates)
fig_files <- fig_files[!grepl("high_lexicon", fig_files)]

all_articles <- rbindlist(lapply(fig_files, function(f) {
  as.data.table(read_parquet(f))
}), fill = TRUE)
all_articles <- unique(all_articles, by = "article_id")
log_msg(paste0("Total figure articles pool: ", format(nrow(all_articles), big.mark = ",")))

# --- Build sample ---
# Tier 1: All Flash Lite positives (likely antisemitic)
tier1_ids <- flash_positives
tier1 <- all_articles[article_id %in% tier1_ids]
log_msg(paste0("Tier 1 (Flash Lite positives): ", nrow(tier1)))

# Tier 2: Semantic search matches NOT already in Tier 1
if (has_semantic && nrow(semantic_dt) > 0) {
  tier2_ids <- setdiff(semantic_dt$article_id, tier1_ids)
  tier2 <- all_articles[article_id %in% tier2_ids]
  # If too many, take highest similarity
  if (nrow(tier2) > 1500) {
    # Merge similarity scores
    tier2 <- merge(tier2, semantic_dt[, .(article_id, max_seed_similarity)],
                   by = "article_id", all.x = TRUE)
    tier2 <- tier2[order(-max_seed_similarity)][1:1500]
  }
  log_msg(paste0("Tier 2 (semantic matches): ", nrow(tier2)))
} else {
  tier2 <- data.table()
}

# Tier 3: High lexicon articles not in Tier 1 or 2
lex_path <- file.path(fig_dir, "high_lexicon_articles.parquet")
if (file.exists(lex_path)) {
  lex_dt <- as.data.table(read_parquet(lex_path))
  already_sampled <- c(tier1$article_id, tier2$article_id)
  lex_remaining <- lex_dt[!article_id %in% already_sampled]
  if (nrow(lex_remaining) > 0) {
    lex_remaining <- lex_remaining[order(-antisem_score)]
    n_lex <- min(500L, nrow(lex_remaining))
    tier3 <- lex_remaining[1:n_lex]
    log_msg(paste0("Tier 3 (high lexicon): ", nrow(tier3)))
  } else {
    tier3 <- data.table()
  }
} else {
  tier3 <- data.table()
}

# Combine tiers and count
combined <- rbindlist(list(tier1, tier2, tier3), fill = TRUE)
combined <- unique(combined, by = "article_id")

# Tier 4: Random negatives (articles with low/zero lexicon score, not in above)
n_remaining <- TOTAL_SAMPLE - nrow(combined)
if (n_remaining > 0) {
  already_in <- combined$article_id
  neg_pool <- all_articles[!article_id %in% already_in]
  # Prefer articles with zero or low antisem score
  if ("antisem_score" %in% names(neg_pool)) {
    neg_pool <- neg_pool[order(antisem_score)]
  }
  n_neg <- min(n_remaining, nrow(neg_pool))
  if (n_neg > 0) {
    tier4 <- neg_pool[sample(.N, n_neg)]
    log_msg(paste0("Tier 4 (negatives): ", nrow(tier4)))
    combined <- rbindlist(list(combined, tier4), fill = TRUE)
  }
}

# Final dedup and trim
combined <- unique(combined, by = "article_id")
if (nrow(combined) > TOTAL_SAMPLE) {
  combined <- combined[1:TOTAL_SAMPLE]
}

# Add stratum labels
combined[, stratum := fifelse(article_id %in% flash_positives, "flash_positive",
                     fifelse(article_id %in% (if (has_semantic) semantic_dt$article_id else character(0)),
                             "semantic_match",
                     fifelse(!is.na(antisem_score) & antisem_score > 0,
                             "high_lexicon", "negative")))]

log_msg(paste0("Final sample: ", nrow(combined)))
log_msg("By stratum:")
strat_summary <- combined[, .N, by = stratum]
for (i in seq_len(nrow(strat_summary))) {
  log_msg(paste0("  ", strat_summary$stratum[i], ": ", strat_summary$N[i]))
}

# Verify we have article text
n_missing <- sum(is.na(combined$article) | nchar(combined$article) < 50)
log_msg(paste0("Missing/short article text: ", n_missing))

# Save
write_parquet(combined, output_path)
log_msg(paste0("Saved: ", output_path))

# Also save CSV preview
csv_path <- file.path(DATA_PANELS, "labeling_sample_final_preview.csv")
fwrite(combined[, .(article_id, newspaper_name, year, stratum,
                     antisem_score,
                     article_preview = substr(article, 1, 200))],
       csv_path, row.names = FALSE)
log_msg(paste0("Saved preview: ", csv_path))

elapsed <- round(as.numeric(difftime(Sys.time(), t_start, units = "mins")), 1)
log_msg(paste0("Sampling complete in ", elapsed, " minutes"))
