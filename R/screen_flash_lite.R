# R/screen_flash_lite.R — Gemini Flash Lite screening for antisemitism
#
# Screens ~15K candidate articles using Gemini 2.0 Flash Lite (~$1).
# Simple binary classification: antisemitic (1) or not (0).
# Resume-friendly with incremental saves.
#
# Output: data_panels/flash_lite_results.csv
#
# Usage:
#   Rscript R/screen_flash_lite.R

source("C:/Users/ammonsj/Ideas/_config.R")

library(data.table)
library(arrow)
library(httr2)
library(jsonlite)
library(parallel)

t_start <- Sys.time()
progress_file <- file.path(DATA_PANELS, ".overnight_progress.txt")
log_msg <- function(msg) {
  elapsed <- round(as.numeric(difftime(Sys.time(), t_start, units = "mins")), 1)
  full_msg <- paste0("[", format(Sys.time(), "%H:%M:%S"), "] [", elapsed, "m] FLASH_LITE: ", msg)
  message(full_msg)
  cat(full_msg, "\n", file = progress_file, append = TRUE)
}

# --- Load API key ---
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
if (nchar(GEMINI_KEY) == 0) stop("GEMINI_API_KEY not found")

MODEL <- "gemini-2.5-flash-lite"
RATE_LIMIT_DELAY <- 0.15  # Flash Lite has generous rate limits
SAVE_EVERY <- 100L
MAX_WORDS <- 1500  # Shorter truncation for Flash Lite (cheaper + faster)

# --- Load candidates ---
candidates_path <- file.path(DATA_PANELS, "flash_lite_candidates.parquet")
if (!file.exists(candidates_path)) {
  stop("Candidates not found. Run select_candidates_for_screening.R first.")
}

dt <- as.data.table(read_parquet(candidates_path))
log_msg(paste0("Loaded ", format(nrow(dt), big.mark = ","), " candidates"))

# --- Resume support ---
output_path <- file.path(DATA_PANELS, "flash_lite_results.csv")
if (file.exists(output_path)) {
  existing <- fread(output_path)
  already_done <- existing$article_id
  dt <- dt[!article_id %in% already_done]
  log_msg(paste0("Resuming: ", length(already_done), " done, ",
                 nrow(dt), " remaining"))
} else {
  existing <- data.table()
}

if (nrow(dt) == 0) {
  log_msg("All candidates already screened. Done.")
  quit(save = "no")
}

# --- Rubric (simplified for Flash Lite) ---
RUBRIC <- '
You are evaluating a US newspaper article (1774-1960) for antisemitic content.

ANTISEMITIC (1) = expresses hostility toward Jewish people, uses antisemitic tropes
(greed, conspiracy, dual loyalty), promotes Jewish conspiracy theories, uses
dehumanizing language about Jews, or approvingly amplifies antisemitic statements.

NOT ANTISEMITIC (0) = neutral reporting, mentions Jewish people without hostility,
reports on antisemitism as a problem, community events, or no Jewish reference.

Note: OCR artifacts are expected. Read through errors.

Respond with ONLY: {"label": 0 or 1, "confidence": 1-5}
'

# --- API call function ---
call_flash_lite <- function(article_text, article_id, year) {
  # Truncate
  words <- strsplit(article_text, "\\s+")[[1]]
  if (length(words) > MAX_WORDS) {
    article_text <- paste(words[1:MAX_WORDS], collapse = " ")
  }

  user_msg <- paste0("Year: ", year, "\n\n", article_text,
                      "\n\nIs this article antisemitic?")

  url <- paste0(
    "https://generativelanguage.googleapis.com/v1beta/models/",
    MODEL, ":generateContent?key=", GEMINI_KEY
  )

  resp <- tryCatch({
    req <- request(url) |>
      req_headers("Content-Type" = "application/json") |>
      req_body_json(list(
        system_instruction = list(parts = list(list(text = RUBRIC))),
        contents = list(list(parts = list(list(text = user_msg)))),
        generationConfig = list(temperature = 0.1, maxOutputTokens = 50L)
      )) |>
      req_timeout(30) |>
      req_retry(max_tries = 3, backoff = ~ 2)

    result <- req_perform(req)
    body <- resp_body_json(result)
    body$candidates[[1]]$content$parts[[1]]$text
  }, error = function(e) {
    NA_character_
  })

  if (is.na(resp)) {
    return(data.table(article_id = article_id, flash_label = NA_integer_,
                       flash_confidence = NA_integer_))
  }

  parsed <- tryCatch({
    clean <- gsub("```json\\s*", "", resp)
    clean <- gsub("```\\s*", "", clean)
    clean <- trimws(clean)
    fromJSON(clean)
  }, error = function(e) {
    list(label = NA, confidence = NA)
  })

  data.table(
    article_id = article_id,
    flash_label = as.integer(parsed$label),
    flash_confidence = as.integer(parsed$confidence)
  )
}

# --- Main loop ---
log_msg(paste0("Screening ", format(nrow(dt), big.mark = ","),
               " articles with ", MODEL))

results <- list()

for (i in seq_len(nrow(dt))) {
  if (i %% 500 == 1 || i == 1) {
    elapsed <- as.numeric(difftime(Sys.time(), t_start, units = "mins"))
    rate <- if (i > 1) round((i - 1) / elapsed, 1) else NA
    remaining <- if (!is.na(rate) && rate > 0) round((nrow(dt) - i) / rate, 0) else NA
    log_msg(paste0("[", i, "/", nrow(dt), "] ",
                   if (!is.na(rate)) paste0(rate, " articles/min") else "",
                   if (!is.na(remaining)) paste0("  ~", remaining, " min left") else ""))
  }

  result <- call_flash_lite(
    dt$article[i],
    dt$article_id[i],
    dt$year[i]
  )
  results[[i]] <- result

  # Save checkpoint
  if (i %% SAVE_EVERY == 0 || i == nrow(dt)) {
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

n_pos <- sum(all_results$flash_label == 1, na.rm = TRUE)
n_neg <- sum(all_results$flash_label == 0, na.rm = TRUE)
n_na <- sum(is.na(all_results$flash_label))

log_msg(paste0("=== Flash Lite Screening Complete ==="))
log_msg(paste0("Total screened: ", nrow(all_results)))
log_msg(paste0("Antisemitic (1): ", n_pos, " (", round(n_pos / nrow(all_results) * 100, 1), "%)"))
log_msg(paste0("Not antisemitic (0): ", n_neg))
log_msg(paste0("Failed/NA: ", n_na))
log_msg(paste0("Saved to: ", output_path))

# --- EARLY WARNING: check if positive rate is suspiciously low ---
if (n_pos < 10) {
  warning_msg <- paste0(
    "FLASH LITE WARNING: Only ", n_pos, " positives found out of ",
    nrow(all_results), " candidates.\n",
    "This is suspiciously low. Possible issues:\n",
    "  - Rubric too strict\n",
    "  - Model too conservative\n",
    "  - Candidates not actually antisemitic\n",
    "Review before proceeding to Deja Vu.\n",
    "Timestamp: ", Sys.time()
  )
  warning_file <- file.path(DATA_PANELS, ".flash_lite_warning.txt")
  writeLines(warning_msg, warning_file)
  log_msg("WARNING: Very few positives. See .flash_lite_warning.txt")
}
