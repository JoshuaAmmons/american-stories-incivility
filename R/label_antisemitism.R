# R/label_antisemitism.R — LLM labeling of articles for antisemitism
#
# Sends each article to the Anthropic API (Claude) with a detailed rubric
# and collects: binary label, confidence (1-5), one-sentence justification.
#
# Usage:
#   Rscript R/label_antisemitism.R
#
# Requires: ANTHROPIC_API_KEY environment variable

source("C:/Users/ammonsj/Ideas/_config.R")

library(arrow)
library(data.table)
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
    val <- gsub('^"|"$', '', val)  # strip surrounding quotes
    do.call(Sys.setenv, setNames(list(val), key))
  }
}

API_KEY <- Sys.getenv("ANTHROPIC_API_KEY")
if (nchar(API_KEY) == 0) {
  stop("ANTHROPIC_API_KEY not found in .env file: ", env_path)
}

MODEL <- "claude-sonnet-4-20250514"
MAX_TOKENS <- 300
RATE_LIMIT_DELAY <- 1.3  # seconds between requests (Tier 1: 50 RPM)

# --- Load sample ---
# Try new pipeline output first (semantic search matches), fall back to old sample
sample_path <- file.path(DATA_PANELS, "labeling_sample_final.parquet")
if (!file.exists(sample_path)) {
  sample_path <- file.path(DATA_PANELS, "antisem_labeling_sample.parquet")
}
if (!file.exists(sample_path)) {
  stop("Labeling sample not found. Run the sampling pipeline first.")
}

dt <- as.data.table(read_parquet(sample_path))
message("Loaded ", nrow(dt), " articles for labeling")

# --- Output path (resume-friendly) ---
output_path <- file.path(DATA_PANELS, "antisem_labels_raw.csv")

# Load existing labels to resume from
if (file.exists(output_path)) {
  existing <- fread(output_path)
  already_labeled <- existing$article_id
  message("Resuming: ", length(already_labeled), " articles already labeled")
  dt <- dt[!article_id %in% already_labeled]
  message("Remaining: ", nrow(dt), " articles to label")
} else {
  existing <- data.table()
}

# --- Rubric ---
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

# --- Label function ---
label_article <- function(article_text, article_id, year) {
  # Truncate very long articles to ~3000 words
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

  resp <- tryCatch({
    req <- request("https://api.anthropic.com/v1/messages") |>
      req_headers(
        "x-api-key" = API_KEY,
        "anthropic-version" = "2023-06-01",
        "content-type" = "application/json"
      ) |>
      req_body_json(list(
        model = MODEL,
        max_tokens = MAX_TOKENS,
        system = RUBRIC,
        messages = list(list(role = "user", content = user_msg))
      )) |>
      req_timeout(60) |>
      req_retry(max_tries = 3, backoff = ~ 5)

    result <- req_perform(req)
    body <- resp_body_json(result)
    body$content[[1]]$text
  }, error = function(e) {
    message("  API error for ", article_id, ": ", e$message)
    NA_character_
  })

  if (is.na(resp)) {
    return(data.table(
      article_id = article_id,
      label = NA_integer_,
      confidence = NA_integer_,
      justification = NA_character_,
      raw_response = NA_character_
    ))
  }

  # Parse JSON response
  parsed <- tryCatch({
    # Strip any markdown code fences
    clean <- gsub("```json\\s*", "", resp)
    clean <- gsub("```\\s*", "", clean)
    clean <- trimws(clean)
    fromJSON(clean)
  }, error = function(e) {
    message("  Parse error for ", article_id, ": ", e$message)
    list(label = NA, confidence = NA, justification = NA)
  })

  data.table(
    article_id = article_id,
    label = as.integer(parsed$label),
    confidence = as.integer(parsed$confidence),
    justification = as.character(parsed$justification),
    raw_response = resp
  )
}

# --- Main labeling loop ---
message("\nStarting labeling...")
results <- list()

for (i in seq_len(nrow(dt))) {
  if (i %% 10 == 0 || i == 1) {
    message("  Labeling article ", i, "/", nrow(dt), " (",
            round(i / nrow(dt) * 100, 1), "%)")
  }

  result <- label_article(dt$article[i], dt$article_id[i], dt$year[i])
  results[[i]] <- result

  # Save incrementally every 25 articles
  if (i %% 25 == 0 || i == nrow(dt)) {
    batch <- rbindlist(results, fill = TRUE)
    all_results <- rbindlist(list(existing, batch), fill = TRUE)
    fwrite(all_results, output_path)
  }

  Sys.sleep(RATE_LIMIT_DELAY)
}

# --- Final save ---
batch <- rbindlist(results, fill = TRUE)
all_results <- rbindlist(list(existing, batch), fill = TRUE)
fwrite(all_results, output_path)

message("\n=== Labeling complete ===")
message("Total labeled: ", nrow(all_results))
message("Label distribution:")
print(all_results[, .N, by = label])
message("Confidence distribution:")
print(all_results[, .N, by = confidence])
message("\nSaved to: ", output_path)

# --- Extract 250 least-confident for Gemini review ---
review_path <- file.path(DATA_PANELS, "antisem_labels_for_review.csv")

# Reload full sample to get article text for all labeled articles
sample_dt <- as.data.table(read_parquet(sample_path))
review_dt <- merge(all_results, sample_dt[, .(article_id, article, newspaper_name, year)],
                   by = "article_id", all.x = TRUE)

# Sort by confidence (lowest first) and take top 250
# With 4000 articles, ~6% review rate gives good coverage of borderline cases
N_REVIEW <- 250L
review_dt <- review_dt[order(confidence, abs(label - 0.5))]
review_set <- review_dt[1:min(N_REVIEW, nrow(review_dt))]

fwrite(review_set[, .(article_id, newspaper_name, year, label, confidence,
                       justification, article)],
       review_path)
message("Saved ", nrow(review_set), " least-confident articles for review: ", review_path)
message("Please review, correct labels as needed, and save as:")
message("  ", file.path(DATA_PANELS, "antisem_labels_verified.csv"))
