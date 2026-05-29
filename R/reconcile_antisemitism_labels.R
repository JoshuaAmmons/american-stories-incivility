# R/reconcile_antisemitism_labels.R — Reconcile all 4,000 labels
#
# Produces verified training labels from two sources:
#   A) 3,750 high-confidence articles: Claude only (no Gemini review needed)
#      → auto-accepted if Claude confidence >= 4
#   B) 250 least-confident articles: Claude + Gemini ensemble (5-15 runs)
#      → auto-accept if Claude + Gemini unanimous agree
#      → Claude adjudicates disagreements with Gemini evidence
#      → Fallback: Gemini majority vote if Claude API fails
#
# Resume-friendly: saves incrementally, skips already-adjudicated articles.
#
# Usage:
#   Rscript R/reconcile_antisemitism_labels.R

source("C:/Users/ammonsj/Ideas/_config.R")

library(data.table)
library(arrow)
library(httr2)
library(jsonlite)

# --- Load API key ---
env_path <- "C:/Users/ammonsj/OneDrive - Wabash College/Desktop/Databases/dao_classification/.env"
env_lines <- readLines(env_path, warn = FALSE)
for (line in env_lines) {
  line <- trimws(line)
  if (nchar(line) == 0 || grepl("^#", line)) next
  if (grepl("^[A-Za-z_]+=", line)) {
    eq_pos <- regexpr("=", line, fixed = TRUE)
    key <- substr(line, 1, eq_pos - 1)
    val <- substr(line, eq_pos + 1, nchar(line))
    if (nchar(key) > 0) do.call(Sys.setenv, setNames(list(val), key))
  }
}

ANTHROPIC_KEY <- Sys.getenv("ANTHROPIC_API_KEY")
if (nchar(ANTHROPIC_KEY) == 0) stop("ANTHROPIC_API_KEY not found")

MODEL <- "claude-sonnet-4-20250514"
SAVE_EVERY <- 25L

# --- Load data ---
# Claude's initial labels (all 4,000)
claude_path <- file.path(DATA_PANELS, "antisem_labels_raw.csv")
claude_labels <- fread(claude_path)

# Gemini aggregated (250 review articles only)
gemini_path <- file.path(DATA_PANELS, "antisem_gemini_aggregated.csv")
gemini_agg <- if (file.exists(gemini_path)) fread(gemini_path) else data.table()

# Gemini raw (for justifications on disagreements)
gemini_raw_path <- file.path(DATA_PANELS, "antisem_gemini_reviews.csv")
gemini_raw <- if (file.exists(gemini_raw_path)) fread(gemini_raw_path) else data.table()

# Review set IDs (the 250 that went to Gemini)
review_path <- file.path(DATA_PANELS, "antisem_labels_for_review.csv")
review_ids <- if (file.exists(review_path)) fread(review_path)$article_id else character(0)

# Original articles (with text)
sample_path <- file.path(DATA_PANELS, "labeling_sample_final.parquet")
sample_dt <- as.data.table(read_parquet(sample_path))

message("Claude labels: ", format(nrow(claude_labels), big.mark = ","))
message("Gemini aggregated: ", format(nrow(gemini_agg), big.mark = ","),
        " (review set only)")
message("Sample articles: ", format(nrow(sample_dt), big.mark = ","))

# --- Merge all data ---
merged <- merge(
  sample_dt[, .(article_id, article, newspaper_name, year)],
  claude_labels[, .(article_id, claude_label = label, claude_confidence = confidence,
                     claude_justification = justification)],
  by = "article_id", all.x = TRUE
)
# Gemini data only exists for the 250 review articles
merged <- merge(merged, gemini_agg, by = "article_id", all.x = TRUE)

# Flag which articles went through Gemini review
merged[, in_review_set := article_id %in% review_ids]

message("Merged: ", format(nrow(merged), big.mark = ","), " articles")
message("  Claude-only (high confidence): ",
        format(sum(!merged$in_review_set), big.mark = ","))
message("  Gemini-reviewed: ",
        format(sum(merged$in_review_set), big.mark = ","))

# ========================================
# GROUP A: High-confidence Claude-only articles (~3,750)
# ========================================
# These never went to Gemini — auto-accept Claude's label
merged[in_review_set == FALSE & !is.na(claude_label),
       `:=`(final_label = claude_label,
            final_confidence = claude_confidence,
            final_source = "claude_high_confidence")]

n_claude_only <- sum(merged$final_source == "claude_high_confidence", na.rm = TRUE)
message("\nAuto-accepted (Claude high-confidence): ",
        format(n_claude_only, big.mark = ","))

# ========================================
# GROUP B: Gemini-reviewed articles (~250)
# ========================================
# "Agree" = Claude's label matches Gemini's unanimous vote
merged[in_review_set == TRUE, gemini_unanimous_label := fifelse(
  gemini_votes_not == 0, 1L,
  fifelse(gemini_votes_antisem == 0, 0L, NA_integer_)
)]
merged[in_review_set == TRUE,
       agree := !is.na(gemini_unanimous_label) &
                claude_label == gemini_unanimous_label]

n_agree <- sum(merged$agree, na.rm = TRUE)
n_disagree <- sum(merged$in_review_set & !merged$agree, na.rm = TRUE)
message("Gemini-reviewed auto-agree (Claude + Gemini unanimous): ",
        format(n_agree, big.mark = ","), " / ",
        format(sum(merged$in_review_set), big.mark = ","))
message("Need adjudication: ", format(n_disagree, big.mark = ","))

# Auto-accepted review articles where Claude + Gemini agree
merged[agree == TRUE, `:=`(final_label = claude_label,
                            final_confidence = claude_confidence,
                            final_source = "auto_agree")]

# --- Check for existing adjudication results (resume support) ---
verified_path <- file.path(DATA_PANELS, "antisem_labels_verified.csv")
if (file.exists(verified_path)) {
  prev_verified <- fread(verified_path)
  prev_adjudicated <- prev_verified[final_source %in% c("claude_adjudicated",
                                                          "gemini_majority_fallback")]
  if (nrow(prev_adjudicated) > 0) {
    message("Resuming: found ", nrow(prev_adjudicated), " previously adjudicated articles")
    for (i in seq_len(nrow(prev_adjudicated))) {
      aid <- prev_adjudicated$article_id[i]
      merged[article_id == aid, `:=`(
        final_label = prev_adjudicated$final_label[i],
        final_confidence = prev_adjudicated$final_confidence[i],
        final_source = prev_adjudicated$final_source[i],
        final_reasoning = prev_adjudicated$final_reasoning[i]
      )]
    }
  }
}

# --- Adjudicate disagreements with Claude ---
disagree_dt <- merged[is.na(final_label)]

if (nrow(disagree_dt) > 0) {
  message("\nSending ", format(nrow(disagree_dt), big.mark = ","),
          " articles to Claude for adjudication...")

  ADJUDICATION_RUBRIC <- '
You are an expert historian making a FINAL determination on whether a newspaper
article (1774-1960) contains antisemitic content.

You have been given:
1. The original article text
2. A previous Claude assessment (label + confidence + justification)
3. Results from multiple independent Gemini Pro reviews of the same article

Your task: Weigh ALL evidence and make a final call. Pay special attention to:
- CRITICAL DISTINCTION: An article that *reports on* or *quotes* antisemitic
  speech is NOT itself antisemitic unless the newspaper endorses that view.
  A news article covering a Coughlin rally and quoting his antisemitic rhetoric
  should be labeled 0 (not antisemitic) — it is journalism, not advocacy.
  Only label 1 if the newspaper or editorial voice itself promotes antisemitism.
- If Gemini unanimously disagrees with the initial label, consider whether the
  disagreement stems from Gemini labeling quoted content rather than editorial stance
- If Gemini is split, the article is genuinely ambiguous — lean toward the
  interpretation best supported by the text
- The initial Claude justification may contain insights Gemini missed
- For articles with 15 Gemini runs (escalated due to initial disagreement),
  the vote distribution is informative but does not override the reporting-vs-endorsing
  distinction

Respond with ONLY a JSON object:
{"final_label": 0 or 1, "confidence": 1-5, "reasoning": "2-3 sentences explaining your final decision and how you weighed the evidence"}
'

  t_adj_start <- Sys.time()

  for (i in seq_len(nrow(disagree_dt))) {
    row <- disagree_dt[i]
    aid <- row$article_id

    # Get Gemini justifications (sample up to 5 for context window)
    gemini_just <- gemini_raw[article_id == aid & !is.na(justification)]
    if (nrow(gemini_just) > 5) {
      # Take a mix: some from each phase if escalated
      gemini_just <- gemini_just[sample(.N, min(5, .N))]
    }
    gemini_justifications <- gemini_just[,
      paste0("  Run ", run_id, " [", phase, "] (label=", label,
             ", conf=", confidence, "): ", justification)]

    user_msg <- paste0(
      "Article ID: ", aid, "\n",
      "Year: ", row$year, "\n",
      "Newspaper: ", row$newspaper_name, "\n\n",
      "--- ARTICLE TEXT ---\n",
      substr(row$article, 1, 12000), "\n",  # cap at ~3K words
      "--- END ARTICLE ---\n\n",
      "=== PREVIOUS CLAUDE ASSESSMENT ===\n",
      "Label: ", row$claude_label, " (",
        ifelse(row$claude_label == 1, "antisemitic", "not antisemitic"), ")\n",
      "Confidence: ", row$claude_confidence, "/5\n",
      "Justification: ", row$claude_justification, "\n\n",
      "=== GEMINI ENSEMBLE (",
        row$n_runs_total, " total runs",
        ifelse(row$escalated, ", escalated due to disagreement", ""), ") ===\n",
      "Votes antisemitic: ", row$gemini_votes_antisem, "/", row$n_runs_total, "\n",
      "Votes not antisemitic: ", row$gemini_votes_not, "/", row$n_runs_total, "\n",
      "Mean confidence: ", row$gemini_mean_confidence, "\n",
      "Sample justifications:\n",
      paste(gemini_justifications, collapse = "\n"), "\n\n",
      "Make your FINAL determination."
    )

    if (i %% 25 == 1 || i == 1) {
      elapsed <- as.numeric(difftime(Sys.time(), t_adj_start, units = "mins"))
      rate <- if (i > 1) round((i - 1) / elapsed, 1) else NA
      message("  [", i, "/", nrow(disagree_dt), "] Adjudicating ", aid,
              " (Claude=", row$claude_label,
              ", Gemini=", row$gemini_votes_antisem, "/", row$n_runs_total, ")",
              if (!is.na(rate)) paste0("  [", rate, " articles/min]") else "")
    }

    resp <- tryCatch({
      req <- request("https://api.anthropic.com/v1/messages") |>
        req_headers(
          "x-api-key" = ANTHROPIC_KEY,
          "anthropic-version" = "2023-06-01",
          "content-type" = "application/json"
        ) |>
        req_body_json(list(
          model = MODEL,
          max_tokens = 400,
          system = ADJUDICATION_RUBRIC,
          messages = list(
            list(role = "user", content = user_msg),
            list(role = "assistant", content = "{")
          )
        )) |>
        req_timeout(60) |>
        req_retry(max_tries = 3, backoff = ~ 5)

      result <- req_perform(req)
      body <- resp_body_json(result)
      body$content[[1]]$text
    }, error = function(e) {
      message("    API error: ", e$message)
      NA_character_
    })

    if (!is.na(resp)) {
      parsed <- tryCatch({
        # Prepend "{" from assistant prefill
        clean <- paste0("{", resp)
        # Extract first JSON object
        json_match <- regmatches(clean, regexpr("\\{[^{}]*\\}", clean))
        if (length(json_match) == 0) stop("No JSON object found")
        fromJSON(json_match[[1]])
      }, error = function(e) {
        message("    Parse error: ", e$message)
        list(final_label = NA, confidence = NA, reasoning = NA)
      })

      merged[article_id == aid, final_label := as.integer(parsed$final_label)]
      merged[article_id == aid, final_confidence := as.integer(parsed$confidence)]
      merged[article_id == aid, final_reasoning := as.character(parsed$reasoning)]
      merged[article_id == aid, final_source := "claude_adjudicated"]
    } else {
      # Fallback: use Gemini majority vote
      merged[article_id == aid, final_label := as.integer(round(row$gemini_mean_label))]
      merged[article_id == aid, final_source := "gemini_majority_fallback"]
    }

    # Save checkpoint
    if (i %% SAVE_EVERY == 0 || i == nrow(disagree_dt)) {
      fwrite(merged[!is.na(final_label), .(
        article_id, final_label, final_confidence, final_source,
        claude_label, claude_confidence, claude_justification,
        gemini_votes_antisem, gemini_votes_not, gemini_mean_confidence,
        n_runs_total, escalated, final_reasoning
      )], verified_path)
    }

    Sys.sleep(0.5)
  }
}

# --- Final save ---
fwrite(merged[!is.na(final_label), .(
  article_id, final_label, final_confidence, final_source,
  claude_label, claude_confidence, claude_justification,
  gemini_votes_antisem, gemini_votes_not, gemini_mean_confidence,
  n_runs_total, escalated, final_reasoning
)], verified_path)

message("\n=== Reconciliation Complete ===")
message("Total articles: ", format(nrow(merged), big.mark = ","))
message("  Claude high-confidence (no Gemini): ",
        format(sum(merged$final_source == "claude_high_confidence", na.rm = TRUE), big.mark = ","))
message("  Auto-agreed (Claude + Gemini): ",
        format(sum(merged$final_source == "auto_agree", na.rm = TRUE), big.mark = ","))
message("  Claude adjudicated: ",
        format(sum(merged$final_source == "claude_adjudicated", na.rm = TRUE), big.mark = ","))
message("  Gemini fallback: ",
        format(sum(merged$final_source == "gemini_majority_fallback", na.rm = TRUE), big.mark = ","))
message("  Still missing: ",
        format(sum(is.na(merged$final_label)), big.mark = ","))

message("\nFinal label distribution:")
print(merged[!is.na(final_label), .N, by = final_label])

message("\nLabel changes from Claude's initial assessment:")
changed <- merged[!is.na(final_label) & !is.na(claude_label)]
message("  Flipped 0->1: ", sum(changed$claude_label == 0 & changed$final_label == 1))
message("  Flipped 1->0: ", sum(changed$claude_label == 1 & changed$final_label == 0))
message("  Unchanged: ", sum(changed$claude_label == changed$final_label))
message("  Flip rate: ",
        round(sum(changed$claude_label != changed$final_label) / nrow(changed) * 100, 1), "%")

# --- Save final training set for RoBERTa ---
training_path <- file.path(DATA_PANELS, "antisem_labels_all_verified.csv")
fwrite(merged[!is.na(final_label), .(article_id, label = final_label,
                                       confidence = final_confidence,
                                       source = final_source)],
       training_path)
message("\nTraining labels saved to: ", training_path)
message("  Label distribution:")
print(merged[!is.na(final_label), .N, by = final_label])
