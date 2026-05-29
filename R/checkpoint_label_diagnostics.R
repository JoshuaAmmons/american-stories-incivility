# R/checkpoint_label_diagnostics.R — Post-labeling diagnostic checkpoint
#
# Run AFTER label_antisemitism.R, BEFORE label_antisemitism_gemini.R
# Produces a diagnostic report to catch:
#   1. Severe class imbalance (base rate issues)
#   2. Lexicon gaps (zero-score articles labeled antisemitic by Claude)
#   3. Era-specific patterns that might need attention
#   4. Low-confidence clustering that suggests rubric problems
#
# If diagnostics look bad, you can:
#   - Expand the lexicon and re-sample
#   - Adjust the stratum proportions
#   - Modify the rubric
#   - Add more labeled articles to thin eras
#
# Usage:
#   Rscript R/checkpoint_label_diagnostics.R

source("C:/Users/ammonsj/Ideas/_config.R")

library(data.table)
library(arrow)

# String concatenation helper
`%+%` <- function(a, b) paste0(a, b)

# --- Load data ---
claude_path <- file.path(DATA_PANELS, "antisem_labels_raw.csv")
if (!file.exists(claude_path)) {
  stop("Claude labels not found. Run label_antisemitism.R first.")
}

labels <- fread(claude_path)
sample_dt <- as.data.table(read_parquet(
  file.path(DATA_PANELS, "antisem_labeling_sample.parquet")
))

# Merge labels with sample metadata
dt <- merge(labels, sample_dt[, .(article_id, year, newspaper_name, stratum,
                                    antisem_score, n_words, article)],
            by = "article_id", all.x = TRUE)

# Add era
era_breaks <- c(-Inf, 1830, 1860, 1900, 1930, Inf)
era_labels <- c("pre1830", "1830_1860", "1860_1900", "1900_1930", "1930_1960")
dt[, era := cut(year, breaks = era_breaks, labels = era_labels, right = FALSE)]

message("=" %+% strrep("=", 70))
message("  LABELING DIAGNOSTIC CHECKPOINT")
message("=" %+% strrep("=", 70))

# ========================================
# 1. OVERALL CLASS BALANCE
# ========================================
message("\n--- 1. CLASS BALANCE ---")
label_dist <- dt[!is.na(label), .N, by = label]
total <- sum(label_dist$N)
pos_rate <- label_dist[label == 1, N] / total * 100

message("Total labeled: ", format(total, big.mark = ","))
message("  Antisemitic (1): ", format(label_dist[label == 1, N], big.mark = ","),
        " (", round(pos_rate, 1), "%)")
message("  Not antisemitic (0): ", format(label_dist[label == 0, N], big.mark = ","),
        " (", round(100 - pos_rate, 1), "%)")

if (pos_rate < 5) {
  message("\n  *** WARNING: Very low positive rate (<5%). ***")
  message("  RoBERTa may struggle with this imbalance.")
  message("  Consider: (a) increasing high/medium stratum sizes,")
  message("            (b) expanding lexicon to capture more positives,")
  message("            (c) using class weights during training.")
} else if (pos_rate < 15) {
  message("\n  CAUTION: Low positive rate (<15%). Monitor training carefully.")
} else {
  message("\n  OK: Positive rate looks reasonable for training.")
}

# ========================================
# 2. LABEL DISTRIBUTION BY STRATUM
# ========================================
message("\n--- 2. LABELS BY STRATUM ---")
stratum_stats <- dt[!is.na(label), .(
  n = .N,
  n_pos = sum(label == 1),
  pct_pos = round(mean(label == 1) * 100, 1),
  mean_conf = round(mean(confidence, na.rm = TRUE), 1)
), by = stratum]
print(stratum_stats)

# Check for lexicon gaps: zero-score articles Claude labeled as antisemitic
zero_positives <- dt[stratum == "zero" & label == 1]
if (nrow(zero_positives) > 0) {
  message("\n  LEXICON GAP DETECTED: ", nrow(zero_positives),
          " articles with ZERO lexicon score were labeled antisemitic by Claude.")
  message("  This suggests the lexicon is missing terms/patterns.")
  message("\n  Sample articles Claude flagged despite zero lexicon score:")
  show_n <- min(10, nrow(zero_positives))
  for (i in seq_len(show_n)) {
    row <- zero_positives[i]
    preview <- substr(row$article, 1, 150)
    message("    [", row$article_id, "] Year ", row$year, " (conf=", row$confidence, ")")
    message("      Justification: ", row$justification)
    message("      Preview: ", preview, "...")
  }
  message("\n  ACTION: Review these articles. If they're truly antisemitic,")
  message("  the lexicon has gaps. Consider adding new terms and re-sampling")
  message("  to capture more of these patterns in the training data.")
} else {
  message("\n  OK: No zero-score articles labeled antisemitic. Lexicon coverage looks adequate.")
}

# ========================================
# 3. LABEL DISTRIBUTION BY ERA
# ========================================
message("\n--- 3. LABELS BY ERA ---")
era_stats <- dt[!is.na(label), .(
  n = .N,
  n_pos = sum(label == 1),
  pct_pos = round(mean(label == 1) * 100, 1),
  mean_conf = round(mean(confidence, na.rm = TRUE), 1)
), by = era][order(era)]
print(era_stats)

# Check for eras with zero or very few positives
thin_eras <- era_stats[n_pos < 10]
if (nrow(thin_eras) > 0) {
  message("\n  WARNING: These eras have <10 positive examples:")
  for (i in seq_len(nrow(thin_eras))) {
    message("    ", thin_eras$era[i], ": ", thin_eras$n_pos[i], " positives out of ",
            thin_eras$n[i], " total")
  }
  message("  RoBERTa may not learn era-specific antisemitic patterns for these periods.")
}

# ========================================
# 4. CONFIDENCE DISTRIBUTION
# ========================================
message("\n--- 4. CONFIDENCE DISTRIBUTION ---")
conf_stats <- dt[!is.na(label), .N, by = confidence][order(confidence)]
print(conf_stats)

low_conf <- dt[!is.na(label) & confidence <= 2]
message("\nLow confidence (1-2): ", nrow(low_conf), " articles (",
        round(nrow(low_conf) / total * 100, 1), "%)")

if (nrow(low_conf) > total * 0.2) {
  message("  WARNING: >20% of labels are low confidence. Consider:")
  message("    - Reviewing/refining the rubric")
  message("    - Checking if OCR quality filter is too permissive")
  message("    - Inspecting low-confidence articles for patterns")
}

# ========================================
# 5. POTENTIAL LABEL NOISE
# ========================================
message("\n--- 5. SUSPICIOUS PATTERNS ---")

# High-score articles labeled NOT antisemitic
high_negatives <- dt[stratum == "high" & label == 0]
if (nrow(high_negatives) > 0) {
  message("High lexicon score but labeled NOT antisemitic: ", nrow(high_negatives))
  message("  (Expected — these might be articles *about* antisemitism, not antisemitic)")
  show_n <- min(5, nrow(high_negatives))
  for (i in seq_len(show_n)) {
    row <- high_negatives[i]
    message("    [", row$article_id, "] Year ", row$year,
            " score=", round(row$antisem_score, 2),
            " conf=", row$confidence)
    message("      ", row$justification)
  }
}

# ========================================
# 6. TRAIN/TEST SPLIT PREVIEW
# ========================================
message("\n--- 6. TRAIN/TEST SPLIT PREVIEW ---")
message("If we hold out 20% stratified by label + era:")
dt_labeled <- dt[!is.na(label)]
test_n <- round(nrow(dt_labeled) * 0.2)
train_n <- nrow(dt_labeled) - test_n
message("  Train: ~", format(train_n, big.mark = ","), " articles")
message("  Test:  ~", format(test_n, big.mark = ","), " articles")

# Estimate class balance in each split
train_pos <- round(sum(dt_labeled$label == 1) * 0.8)
test_pos <- sum(dt_labeled$label == 1) - train_pos
message("  Train positives: ~", train_pos)
message("  Test positives:  ~", test_pos)

if (test_pos < 30) {
  message("  WARNING: <30 positives in test set may give unreliable F1 estimates.")
}

# ========================================
# SUMMARY RECOMMENDATION
# ========================================
message("\n" %+% strrep("=", 72))
message("  RECOMMENDATION")
message(strrep("=", 72))

issues <- 0L
if (pos_rate < 5) issues <- issues + 1L
if (nrow(zero_positives) > nrow(dt[stratum == "zero"]) * 0.05) issues <- issues + 1L
if (nrow(thin_eras) > 0) issues <- issues + 1L
if (nrow(low_conf) > total * 0.2) issues <- issues + 1L

if (issues == 0) {
  message("  ALL CLEAR: Diagnostics look good. Proceed to Gemini review.")
} else {
  message("  ", issues, " issue(s) detected. Review the warnings above before")
  message("  proceeding to the Gemini review step (~$3-5 in API costs).")
  message("  Fix issues now to avoid wasting budget on noisy labels.")
}

message("\nDiagnostic report complete.")
