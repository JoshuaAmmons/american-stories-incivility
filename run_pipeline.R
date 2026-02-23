# run_pipeline.R — Master script to render all Rmds with logging
#
# Usage:
#   Rscript run_pipeline.R              # Run all steps
#   Rscript run_pipeline.R 3            # Start from step 3
#   Rscript run_pipeline.R 3 5          # Run steps 3 through 5

source("C:/Users/ammonsj/Ideas/_config.R")

# Define pipeline steps
steps <- c(
  "rmd/00_setup_python.Rmd",
  "rmd/01_download_data.Rmd",
  "rmd/02_parse_articles.Rmd",
  "rmd/03_build_lexicon.Rmd",
  "rmd/04_feature_engineering.Rmd",
  "rmd/05_random_forest.Rmd",
  "rmd/06_treatment_panel.Rmd",
  "rmd/07_did_estimation.Rmd",
  "rmd/07b_did_modern.Rmd",
  "rmd/08_figures_tables.Rmd"
)

# Parse command-line args for step range
args <- commandArgs(trailingOnly = TRUE)
start_step <- 1L
end_step <- length(steps)

if (length(args) >= 1) start_step <- as.integer(args[1])
if (length(args) >= 2) end_step <- as.integer(args[2])

message("========================================")
message("Pipeline: steps ", start_step, " to ", end_step)
message("========================================\n")

for (i in start_step:end_step) {
  rmd_file <- file.path(PROJECT_ROOT, steps[i])
  step_name <- gsub("\\.Rmd$", "", basename(steps[i]))
  timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")

  log_file <- file.path(OUTPUT_LOGS, paste0(step_name, "_", timestamp, ".log"))
  html_file <- file.path(OUTPUT_HTML, paste0(step_name, ".html"))

  message("\n--- Step ", i, "/", length(steps), ": ", step_name, " ---")
  message("  Rmd: ", rmd_file)
  message("  Log: ", log_file)
  message("  HTML: ", html_file)

  # Render with logging
  start_time <- Sys.time()

  result <- tryCatch({
    # Redirect messages to log file
    log_con <- file(log_file, open = "wt")
    sink(log_con, type = "message")

    rmarkdown::render(
      input = rmd_file,
      output_file = html_file,
      output_format = "html_document",
      envir = new.env(parent = globalenv()),
      quiet = FALSE
    )

    sink(type = "message")
    close(log_con)

    list(success = TRUE, error = NULL)
  }, error = function(e) {
    try(sink(type = "message"), silent = TRUE)
    try(close(log_con), silent = TRUE)

    # Write error to log
    cat(paste0("\n\nERROR:\n", conditionMessage(e), "\n\n",
               paste(conditionCall(e), collapse = "\n")),
        file = log_file, append = TRUE)

    list(success = FALSE, error = conditionMessage(e))
  })

  elapsed <- difftime(Sys.time(), start_time, units = "mins")
  message("  Time: ", round(as.numeric(elapsed), 1), " min")

  if (result$success) {
    message("  Status: SUCCESS")
  } else {
    message("  Status: FAILED")
    message("  Error: ", result$error)
    message("  See log: ", log_file)
    message("\nPipeline stopped at step ", i, ". Fix the error and re-run from this step:")
    message('  Rscript run_pipeline.R ', i)
    quit(status = 1)
  }
}

message("\n========================================")
message("Pipeline complete! All steps succeeded.")
message("HTML reports: ", OUTPUT_HTML)
message("Logs: ", OUTPUT_LOGS)
message("========================================")
