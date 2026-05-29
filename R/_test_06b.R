# Smoke test for the rewritten 06b panel builder.
# Runs the REAL build_all_antisem_panels() on a small year window (1936-1938)
# for two figures, into a throwaway dir, then validates the output schema and
# reports peak memory. Does NOT touch real panels or the scoring job.

source("C:/Users/ammonsj/Ideas/_config.R")
source("C:/Users/ammonsj/Ideas/R/build_antisem_panels.R")

t0 <- Sys.time()
roberta_dir <- ROBERTA_SCORED_DIR
text_dir    <- file.path(DATA_PARQUET, "articles_antisem_scored")
test_out    <- file.path(DATA_PANELS, ".test_06b")
unlink(test_out, recursive = TRUE)
dir.create(test_out, recursive = TRUE, showWarnings = FALSE)

cat("=== article_id uniqueness check (1937) ===\n")
chk <- as.data.table(read_parquet(file.path(roberta_dir, "roberta_scored_1937.parquet"),
                                  col_select = "article_id"))
cat("  1937 rows:", nrow(chk), " duplicate article_ids:", anyDuplicated(chk$article_id), "\n")
rm(chk); gc(verbose = FALSE)

cat("\n=== running build_all_antisem_panels (1936-1938, coughlin + lindbergh) ===\n")
build_all_antisem_panels(
  roberta_dir = roberta_dir,
  text_dir    = text_dir,
  figures     = FIGURES[c("coughlin", "lindbergh")],
  out_dir     = test_out,
  year_min    = 1936L,
  year_max    = 1938L
)

cat("\n=== validating outputs ===\n")
required_cols <- c("newspaper_name", "year_month", "time_id",
                   "antisem_rate_roberta", "antisem_rate_lexicon",
                   "figure_count", "figure_share", "n_articles",
                   "n_articles_non_figure", "mean_words", "mean_ocr",
                   "front_page_share", "treat_date", "treat_time_id",
                   "treated", "treat_cohort", "newspaper_id")

saved <- list.files(test_out, pattern = "\\.parquet$", full.names = TRUE)
cat("  panels saved:", length(saved), "\n")
overall_ok <- length(saved) > 0
for (pf in saved) {
  p <- as.data.table(read_parquet(pf))
  miss <- setdiff(required_cols, names(p))
  ok <- length(miss) == 0
  overall_ok <- overall_ok && ok
  cat(sprintf("  %s: %d rows, %d newspapers, %d treated | schema %s%s\n",
              basename(pf), nrow(p), uniqueN(p$newspaper_name),
              uniqueN(p[treated == 1, newspaper_name]),
              if (ok) "OK" else "MISSING: ",
              if (ok) "" else paste(miss, collapse = ",")))
}

peak_gb <- sum(gc()[, 6]) / 1024  # max used (Mb) across Ncells+Vcells -> GB
cat(sprintf("\nElapsed: %.1f min | R peak memory this session: ~%.1f GB\n",
            as.numeric(difftime(Sys.time(), t0, units = "mins")), peak_gb))

unlink(test_out, recursive = TRUE)
cat("Cleaned up test dir.\n")
cat(if (overall_ok) "RESULT: PASS\n" else "RESULT: FAIL (see above)\n")
