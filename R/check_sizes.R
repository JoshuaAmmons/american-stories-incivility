scored_dir <- "C:/Users/ammonsj/Ideas/data_parquet/articles_scored"
antisem_dir <- "C:/Users/ammonsj/Ideas/data_parquet/articles_antisem_scored"

sf <- list.files(scored_dir, pattern = "\\.parquet$", full.names = TRUE)
done <- list.files(antisem_dir, pattern = "\\.parquet$")
done_yrs <- gsub("antisem_scored_(\\d{4})\\.parquet", "\\1", done)

get_yr <- function(f) gsub(".*scored_(\\d{4})\\.parquet", "\\1", f)
todo <- sf[!(sapply(sf, get_yr) %in% done_yrs)]
sizes <- file.size(todo) / 1e9

cat("Remaining files:", length(todo), "\n")
cat("Huge (>3GB):", sum(sizes > 3), "- total", round(sum(sizes[sizes > 3]), 1), "GB\n")
cat("Large (1.5-3GB):", sum(sizes >= 1.5 & sizes <= 3), "- total", round(sum(sizes[sizes >= 1.5 & sizes <= 3]), 1), "GB\n")
cat("Medium (0.5-1.5GB):", sum(sizes >= 0.5 & sizes < 1.5), "- total", round(sum(sizes[sizes >= 0.5 & sizes < 1.5]), 1), "GB\n")
cat("Small (<500MB):", sum(sizes < 0.5), "- total", round(sum(sizes[sizes < 0.5]), 1), "GB\n")

# Print the huge ones
cat("\nHuge files:\n")
huge <- todo[sizes > 3]
huge_s <- sizes[sizes > 3]
for (i in order(huge_s, decreasing = TRUE)) {
  cat("  ", basename(huge[i]), "-", round(huge_s[i], 2), "GB\n")
}
