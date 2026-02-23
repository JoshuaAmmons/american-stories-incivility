# R/helpers.R — Shared utility functions

#' Count words in a character vector
count_words <- function(x) {
  stringi::stri_count_words(x)
}

#' Compute share of non-alphabetic characters (OCR quality proxy)
share_nonalpha <- function(x) {
  total <- nchar(x)
  alpha <- nchar(gsub("[^a-zA-Z]", "", x))
  ifelse(total > 0, 1 - alpha / total, NA_real_)
}

#' Parse page field (e.g., "p1" -> 1, "3" -> 3)
parse_page <- function(x) {
  as.integer(gsub("[^0-9]", "", x))
}

#' Score text against a lexicon (count of matching terms per 1000 words)
lexicon_score <- function(text, lexicon, ignore_case = TRUE) {
  if (ignore_case) {
    text <- tolower(text)
    lexicon <- tolower(lexicon)
  }
  pattern <- paste0("\\b(", paste(lexicon, collapse = "|"), ")\\b")
  matches <- stringi::stri_count_regex(text, pattern)
  words <- stringi::stri_count_words(text)
  ifelse(words > 0, matches / words * 1000, 0)
}

#' Simple isotonic calibration
#' Fits isotonic regression on (predicted, actual) and returns a calibration function
fit_isotonic <- function(predicted, actual) {
  # Remove NAs
  keep <- !is.na(predicted) & !is.na(actual)
  predicted <- predicted[keep]
  actual <- actual[keep]

  ord <- order(predicted)
  iso_fit <- isoreg(predicted[ord], actual[ord])

  # Deduplicate x values for approx (average yf at duplicate x)
  fit_df <- data.frame(x = iso_fit$x, y = iso_fit$yf)
  fit_df <- aggregate(y ~ x, data = fit_df, FUN = mean)
  fit_df <- fit_df[order(fit_df$x), ]

  if (nrow(fit_df) < 2) {
    # Degenerate case: return identity or constant
    const_val <- mean(actual)
    message("Warning: isotonic calibration degenerate, using constant = ", round(const_val, 4))
    return(function(new_pred) rep(const_val, length(new_pred)))
  }

  function(new_pred) {
    approx(fit_df$x, fit_df$y, xout = new_pred, rule = 2)$y
  }
}

message("Helpers loaded.")
