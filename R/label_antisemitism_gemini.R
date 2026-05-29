# R/label_antisemitism_gemini.R — Gemini Pro ensemble for 250 least-confident
#
# Takes the 250 least-confident articles from Claude's initial labeling and
# runs them through Gemini 2.5 Pro ensemble for independent verification.
#
# Phase 1: 250 articles × 5 runs each = 1,250 calls
# Phase 2: Any article with disagreement (not unanimous) gets 10 MORE runs
# Then Claude adjudicates remaining disagreements in reconcile_antisemitism_labels.R
#
# Resume-friendly: saves incrementally, skips already-completed runs.
# Estimated cost: ~$3-5 for full run.
#
# Usage:
#   Rscript R/label_antisemitism_gemini.R
#
# Requires: GEMINI_API_KEY in .env file

source("C:/Users/ammonsj/Ideas/_config.R")

library(data.table)
library(arrow)
library(httr2)
library(jsonlite)

# --- Load API key from .env ---
env_path <- "C:/Users/ammonsj/OneDrive - Wabash College/Desktop/Databases/dao_classification/.env"
env_lines <- readLines(env_path, warn = FALSE)
for (line in env_lines) {
  if (grepl("^[A-Z_]+=", line)) {
    eq_pos <- regexpr("=", line, fixed = TRUE)
    key <- substr(line, 1, eq_pos - 1)
    val <- substr(line, eq_pos + 1, nchar(line))
    val <- gsub('^"|"$', '', val)
    do.call(Sys.setenv, setNames(list(val), key))
  }
}

GEMINI_KEY <- Sys.getenv("GEMINI_API_KEY")
if (nchar(GEMINI_KEY) == 0) {
  stop("GEMINI_API_KEY not found in .env file: ", env_path)
}

MODEL <- "gemini-2.0-flash"
N_RUNS_PHASE1 <- 5L
N_RUNS_PHASE2 <- 10L  # escalation for disagreements
TEMPERATURE <- 0.7
RATE_LIMIT_DELAY <- 1.5  # seconds between requests (Pro rate limits)
SAVE_EVERY <- 50L  # save checkpoint every N calls
EARLY_CHECK_N <- 50L  # check disagreement rate after this many articles
EARLY_CHECK_THRESHOLD <- 0.60  # STOP if >60% of articles are split decisions
WARNING_FILE <- file.path(DATA_PANELS, ".gemini_warning.txt")

# --- Load the 250 least-confident articles from Claude's labeling ---
review_path <- file.path(DATA_PANELS, "antisem_labels_for_review.csv")
if (!file.exists(review_path)) {
  stop("Review set not found. Run label_antisemitism.R first: ", review_path)
}

dt <- fread(review_path)
# Ensure we have article text
if (!"article" %in% names(dt)) {
  # Merge with sample to get article text
  sample_path <- file.path(DATA_PANELS, "labeling_sample_final.parquet")
  if (!file.exists(sample_path)) {
    sample_path <- file.path(DATA_PANELS, "antisem_labeling_sample.parquet")
  }
  sample_dt <- as.data.table(read_parquet(sample_path))
  dt <- merge(dt, sample_dt[, .(article_id, article, year)], by = "article_id", all.x = TRUE)
}
message("Loaded ", format(nrow(dt), big.mark = ","),
        " least-confident articles for Gemini review")

# --- Output path (resume-friendly) ---
output_path <- file.path(DATA_PANELS, "antisem_gemini_reviews.csv")

if (file.exists(output_path)) {
  existing <- fread(output_path)
  message("Found existing reviews: ", format(nrow(existing), big.mark = ","), " rows")
} else {
  existing <- data.table()
}

# --- Rubric (same as Claude's for consistency) ---
RUBRIC <- '
You are an expert historian evaluating newspaper articles from the United States
(1774-1960) for antisemitic content.

## Definition
An article is ANTISEMITIC (label=1) if it:
- Expresses hostility, prejudice, or contempt toward Jewish people as a group
- Uses antisemitic tropes (greed, conspiracy, dual loyalty, world domination)
- Approvingly quotes or amplifies antisemitic statements without challenge
- Uses dehumanizing language about Jewish people
- Promotes conspiracy theories about Jewish control of finance, media, or politics
- Uses coded antisemitic language ("international bankers", "cosmopolitan elite")
  in a context that clearly targets Jewish people

An article is NOT ANTISEMITIC (label=0) if it:
- Merely reports on antisemitic incidents or statements neutrally/critically
- Mentions Jewish people, organizations, or events without hostility
- Discusses Jewish community events, religious observances, or cultural life
- Reports on antisemitism as a social problem to be opposed
- Uses terms like "international bankers" in a context with no Jewish reference

## Historical calibration
Judge by the standards of the period. Some language that is unremarkable today
(e.g., "Hebrew" as a descriptor) was standard neutral usage. Focus on whether
a contemporary reader would understand the article as hostile toward Jewish people.

## OCR artifacts
This text was digitized via OCR from historical newspaper scans. Expect some
garbled characters, missing words, and formatting artifacts. Do your best to
read through these errors.

## Response format
Respond with ONLY a JSON object, no other text:
{"label": 0 or 1, "confidence": 1-5, "justification": "one sentence"}

Where confidence is:
  5 = Certain
  4 = Very confident
  3 = Moderately confident
  2 = Somewhat unsure
  1 = Very unsure (guessing)
'

# --- Gemini API call function ---
call_gemini <- function(article_text, article_id, year, run_id, phase) {
  # Truncate very long articles
  words <- strsplit(article_text, "\\s+")[[1]]
  if (length(words) > 3000) {
    article_text <- paste(words[1:3000], collapse = " ")
  }

  user_msg <- paste0(
    "Article ID: ", article_id, "\n",
    "Year: ", year, "\n\n",
    "--- ARTICLE TEXT ---\n",
    article_text, "\n",
    "--- END ARTICLE ---\n\n",
    "Evaluate this article for antisemitic content using the rubric provided."
  )

  url <- paste0(
    "https://generativelanguage.googleapis.com/v1beta/models/",
    MODEL, ":generateContent?key=", GEMINI_KEY
  )

  resp <- tryCatch({
    req <- request(url) |>
      req_headers("Content-Type" = "application/json") |>
      req_body_json(list(
        system_instruction = list(
          parts = list(list(text = RUBRIC))
        ),
        contents = list(list(
          parts = list(list(text = user_msg))
        )),
        generationConfig = list(
          temperature = TEMPERATURE,
          maxOutputTokens = 2048L
        )
      )) |>
      req_timeout(90) |>
      req_retry(max_tries = 3, backoff = ~ 5)

    result <- req_perform(req)
    body <- resp_body_json(result)
    # Gemini 2.5 Pro uses thinking tokens — actual text may not be in parts[[1]]
    # Find the last part with a "text" field (thinking parts have "thought" field)
    parts <- tryCatch(body$candidates[[1]]$content$parts, error = function(e) list())
    txt <- NA_character_
    for (p in parts) {
      if (!is.null(p$text) && length(p$text) > 0 && nchar(p$text) > 0) {
        txt <- p$text
      }
    }
    txt
  }, error = function(e) {
    message("  API error for ", article_id, " run ", run_id, ": ", e$message)
    NA_character_
  })

  if (length(resp) == 0 || is.na(resp)) {
    return(data.table(
      article_id = article_id,
      run_id = run_id,
      phase = phase,
      label = NA_integer_,
      confidence = NA_integer_,
      justification = NA_character_,
      raw_response = NA_character_
    ))
  }

  # Parse JSON response
  parsed <- tryCatch({
    clean <- gsub("```json\\s*", "", resp)
    clean <- gsub("```\\s*", "", clean)
    clean <- trimws(clean)
    fromJSON(clean)
  }, error = function(e) {
    message("  Parse error for ", article_id, " run ", run_id, ": ", e$message)
    list(label = NA, confidence = NA, justification = NA)
  })

  data.table(
    article_id = article_id,
    run_id = run_id,
    phase = phase,
    label = as.integer(parsed$label),
    confidence = as.integer(parsed$confidence),
    justification = as.character(parsed$justification),
    raw_response = resp
  )
}

# --- Helper: run N calls for a set of articles ---
run_batch <- function(articles_dt, n_runs, phase_name, existing_dt) {
  results <- list()
  counter <- 0L
  skipped <- 0L
  total_calls <- nrow(articles_dt) * n_runs
  t_batch_start <- Sys.time()

  for (i in seq_len(nrow(articles_dt))) {
    for (run in seq_len(n_runs)) {
      # Check if already done (for resume)
      if (nrow(existing_dt) > 0 &&
          nrow(existing_dt[article_id == articles_dt$article_id[i] &
                           run_id == run & phase == phase_name]) > 0) {
        skipped <- skipped + 1L
        next
      }

      counter <- counter + 1L
      if (counter %% 100 == 1 || counter == 1) {
        elapsed <- as.numeric(difftime(Sys.time(), t_batch_start, units = "mins"))
        rate <- if (counter > 1) round((counter - 1) / elapsed, 1) else NA
        remaining <- if (!is.na(rate) && rate > 0) {
          round((total_calls - skipped - counter) / rate, 0)
        } else NA
        message("  [", counter, "/", total_calls - skipped, "] Article ",
                articles_dt$article_id[i], " (", articles_dt$year[i], ") run ", run,
                if (!is.na(remaining)) paste0("  (~", remaining, " min left)") else "")
      }

      result <- call_gemini(articles_dt$article[i], articles_dt$article_id[i],
                            articles_dt$year[i], run, phase_name)
      results[[length(results) + 1]] <- result

      # Save incrementally
      if (counter %% SAVE_EVERY == 0 && length(results) > 0) {
        batch <- rbindlist(results, fill = TRUE)
        combined <- rbindlist(list(existing_dt, batch), fill = TRUE)
        fwrite(combined, output_path)
        message("    [checkpoint] Saved ", nrow(combined), " total rows")
      }

      Sys.sleep(RATE_LIMIT_DELAY)
    }

    # --- EARLY WARNING CHECK (Phase 1 only) ---
    # After EARLY_CHECK_N articles have all runs, check disagreement rate
    if (phase_name == "phase1" && i == EARLY_CHECK_N && length(results) > 0) {
      early_batch <- rbindlist(results, fill = TRUE)
      early_agg <- early_batch[!is.na(label), .(
        votes_antisem = sum(label == 1),
        votes_not = sum(label == 0),
        n_runs = .N
      ), by = article_id]
      # Only check articles with all runs completed
      early_complete <- early_agg[n_runs >= n_runs]
      if (nrow(early_complete) > 0) {
        n_split <- sum(early_complete$votes_antisem > 0 & early_complete$votes_not > 0)
        split_rate <- n_split / nrow(early_complete)
        message("\n  *** EARLY CHECK (", nrow(early_complete), " articles complete) ***")
        message("  Unanimous: ", nrow(early_complete) - n_split,
                " | Split: ", n_split,
                " | Disagreement rate: ", round(split_rate * 100, 1), "%")

        if (split_rate > EARLY_CHECK_THRESHOLD) {
          warning_msg <- paste0(
            "GEMINI EARLY WARNING — STOPPED AT ", nrow(early_complete), " ARTICLES\n",
            "Disagreement rate: ", round(split_rate * 100, 1), "%",
            " (threshold: ", EARLY_CHECK_THRESHOLD * 100, "%)\n",
            "Split: ", n_split, " / ", nrow(early_complete), " articles\n\n",
            "This means Gemini can't agree on most articles.\n",
            "Possible causes:\n",
            "  - Rubric is ambiguous for borderline cases\n",
            "  - These 250 articles are genuinely hard (they ARE the least confident)\n",
            "  - Temperature too high (currently ", TEMPERATURE, ")\n\n",
            "Vote distribution among split articles:\n"
          )
          split_articles <- early_complete[votes_antisem > 0 & votes_not > 0]
          for (j in seq_len(min(10, nrow(split_articles)))) {
            row <- split_articles[j]
            warning_msg <- paste0(warning_msg,
              "  ", row$article_id, ": ", row$votes_antisem, "/", row$n_runs, " antisemitic\n")
          }
          warning_msg <- paste0(warning_msg,
            "\nSaved partial results. Review before continuing.\n",
            "Timestamp: ", Sys.time())

          # Save warning file and partial results
          writeLines(warning_msg, WARNING_FILE)
          combined <- rbindlist(list(existing_dt, early_batch), fill = TRUE)
          fwrite(combined, output_path)

          message("\n  !!! STOPPING: Disagreement rate ", round(split_rate * 100, 1),
                  "% exceeds threshold of ", EARLY_CHECK_THRESHOLD * 100, "% !!!")
          message("  Warning written to: ", WARNING_FILE)
          message("  Partial results saved to: ", output_path)
          message("  Review and adjust before re-running.")
          stop("Gemini disagreement rate too high. See ", WARNING_FILE)
        } else {
          message("  OK: Disagreement rate within acceptable range. Continuing.\n")
          # Clean up any old warning file
          if (file.exists(WARNING_FILE)) file.remove(WARNING_FILE)
        }
      }
    }
  }

  if (skipped > 0) message("  Skipped ", skipped, " already-completed runs")

  if (length(results) > 0) {
    rbindlist(results, fill = TRUE)
  } else {
    data.table()
  }
}

# ========================================
# PHASE 1: 5 runs per article (250 review set)
# ========================================
message("\n=== PHASE 1: ", N_RUNS_PHASE1, " runs × ",
        format(nrow(dt), big.mark = ","), " review articles = ",
        format(nrow(dt) * N_RUNS_PHASE1, big.mark = ","),
        " calls (Gemini 2.5 Pro) ===")
t_phase1 <- Sys.time()
phase1_results <- run_batch(dt, N_RUNS_PHASE1, "phase1", existing)

# Combine with existing and save
if (nrow(phase1_results) > 0) {
  all_reviews <- rbindlist(list(existing, phase1_results), fill = TRUE)
} else {
  all_reviews <- existing
}
fwrite(all_reviews, output_path)
message("Phase 1 complete in ",
        round(as.numeric(difftime(Sys.time(), t_phase1, units = "hours")), 1), " hours")

# Check for disagreements in phase 1
phase1_agg <- all_reviews[phase == "phase1" & !is.na(label), .(
  votes_antisem = sum(label == 1),
  votes_not = sum(label == 0),
  n_runs = .N
), by = article_id]

# Disagreement = not unanimous (i.e., has both 0s and 1s)
disagree_ids <- phase1_agg[votes_antisem > 0 & votes_not > 0, article_id]

message("\n--- Phase 1 Summary ---")
message("Total articles scored: ", format(nrow(phase1_agg), big.mark = ","))
message("Unanimous antisemitic: ", format(sum(phase1_agg$votes_not == 0), big.mark = ","))
message("Unanimous not antisemitic: ", format(sum(phase1_agg$votes_antisem == 0), big.mark = ","))
message("Split decisions: ", format(length(disagree_ids), big.mark = ","))
disagree_rate <- length(disagree_ids) / nrow(phase1_agg)
message("Disagreement rate: ", round(disagree_rate * 100, 1), "%")

# --- Phase 1 gate: stop if too many disagreements ---
if (disagree_rate > EARLY_CHECK_THRESHOLD) {
  warning_msg <- paste0(
    "GEMINI PHASE 1 COMPLETE — HIGH DISAGREEMENT RATE\n",
    "Disagreement rate: ", round(disagree_rate * 100, 1), "%",
    " (threshold: ", EARLY_CHECK_THRESHOLD * 100, "%)\n",
    "Split: ", length(disagree_ids), " / ", nrow(phase1_agg), " articles\n\n",
    "Phase 2 would require ", length(disagree_ids) * N_RUNS_PHASE2,
    " additional API calls for escalation.\n",
    "Review Phase 1 results before proceeding.\n",
    "Timestamp: ", Sys.time()
  )
  writeLines(warning_msg, WARNING_FILE)
  message("\n  !!! STOPPING before Phase 2: Disagreement rate too high !!!")
  message("  Warning written to: ", WARNING_FILE)
  message("  Phase 1 results saved. Review before re-running.")
  stop("Phase 1 disagreement rate too high (", round(disagree_rate * 100, 1),
       "%). See ", WARNING_FILE)
} else {
  if (file.exists(WARNING_FILE)) file.remove(WARNING_FILE)
}

# ========================================
# PHASE 2: 10 more runs for disagreements
# ========================================
if (length(disagree_ids) > 0) {
  message("\n=== PHASE 2: ", N_RUNS_PHASE2, " additional runs for ",
          format(length(disagree_ids), big.mark = ","), " split articles (",
          format(length(disagree_ids) * N_RUNS_PHASE2, big.mark = ","), " calls) ===")

  t_phase2 <- Sys.time()
  disagree_dt <- dt[article_id %in% disagree_ids]
  phase2_results <- run_batch(disagree_dt, N_RUNS_PHASE2, "phase2", all_reviews)

  if (nrow(phase2_results) > 0) {
    all_reviews <- rbindlist(list(all_reviews, phase2_results), fill = TRUE)
    fwrite(all_reviews, output_path)
  }
  message("Phase 2 complete in ",
          round(as.numeric(difftime(Sys.time(), t_phase2, units = "hours")), 1), " hours")
} else {
  message("\nNo disagreements — skipping Phase 2.")
}

# ========================================
# AGGREGATE: Combine all runs per article
# ========================================
message("\n=== Final Aggregation ===")
agg <- all_reviews[!is.na(label), .(
  gemini_mean_label = mean(label),
  gemini_votes_antisem = sum(label == 1),
  gemini_votes_not = sum(label == 0),
  gemini_mean_confidence = round(mean(confidence, na.rm = TRUE), 1),
  n_runs_total = .N,
  n_phase1 = sum(phase == "phase1"),
  n_phase2 = sum(phase == "phase2"),
  escalated = any(phase == "phase2")
), by = article_id]

agg_path <- file.path(DATA_PANELS, "antisem_gemini_aggregated.csv")
fwrite(agg, agg_path)

message("\nAggregated ", format(nrow(agg), big.mark = ","), " articles")
message("  Unanimous (phase 1 only): ",
        format(sum(!agg$escalated), big.mark = ","))
message("  Escalated to phase 2: ",
        format(sum(agg$escalated), big.mark = ","))
message("  Total API calls made: ",
        format(nrow(all_reviews), big.mark = ","))

# Show escalated article breakdown
if (any(agg$escalated)) {
  n_escalated <- sum(agg$escalated)
  message("\n  Escalated articles (", n_escalated, " total):")
  # Show summary stats, not every single one
  esc <- agg[escalated == TRUE]
  message("    Leaning antisemitic (>50% votes): ",
          sum(esc$gemini_mean_label > 0.5))
  message("    Leaning not antisemitic (<50% votes): ",
          sum(esc$gemini_mean_label < 0.5))
  message("    Perfectly split (50/50): ",
          sum(esc$gemini_mean_label == 0.5))
  message("    Mean confidence across escalated: ",
          round(mean(esc$gemini_mean_confidence), 1))

  # Show the 10 most contentious (closest to 50/50)
  most_split <- esc[order(abs(gemini_mean_label - 0.5))][1:min(10, nrow(esc))]
  message("\n  10 most contentious articles:")
  for (i in seq_len(nrow(most_split))) {
    row <- most_split[i]
    message("    ", row$article_id, ": ",
            row$gemini_votes_antisem, "/", row$n_runs_total, " antisemitic",
            " (conf=", row$gemini_mean_confidence, ")")
  }
}

message("\nSaved raw reviews: ", output_path)
message("Saved aggregated: ", agg_path)
