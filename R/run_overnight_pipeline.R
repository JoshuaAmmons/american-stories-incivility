# R/run_overnight_pipeline.R — Master overnight pipeline
#
# Chains all steps from figure extraction through DiD estimation.
# Resume-friendly: each step checks for existing output before running.
# Budget cap: $50 total (Flash Lite ~$1, Claude ~$11, Gemini ensemble ~$5)
#
# Usage:
#   Rscript R/run_overnight_pipeline.R

source("C:/Users/ammonsj/Ideas/_config.R")

library(data.table)
library(arrow)

t_start <- Sys.time()
progress_file <- file.path(DATA_PANELS, ".overnight_progress.txt")
log_msg <- function(msg) {
  elapsed <- round(as.numeric(difftime(Sys.time(), t_start, units = "mins")), 1)
  full_msg <- paste0("[", format(Sys.time(), "%H:%M:%S"), "] [", elapsed, "m] PIPELINE: ", msg)
  message(full_msg)
  cat(full_msg, "\n", file = progress_file, append = TRUE)
}

run_step <- function(script_path, step_name, is_python = FALSE) {
  log_msg(paste0("=== STARTING: ", step_name, " ==="))
  t0 <- Sys.time()

  if (is_python) {
    cmd <- paste0('"', PYTHON_EXE, '" "', script_path, '"')
  } else {
    cmd <- paste0('"', R_EXE, '" "', script_path, '"')
  }

  exit_code <- system(cmd, intern = FALSE)
  elapsed <- round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1)

  if (exit_code != 0) {
    log_msg(paste0("!!! FAILED: ", step_name, " (exit code ", exit_code,
                   ") after ", elapsed, " min !!!"))
    return(FALSE)
  }
  log_msg(paste0("=== COMPLETED: ", step_name, " (", elapsed, " min) ==="))
  return(TRUE)
}

log_msg("============================================")
log_msg("=== OVERNIGHT PIPELINE STARTED ===")
log_msg("============================================")

# ====================================================================
# STEP 1: Extract figure articles (all 18 figures + high lexicon)
# ====================================================================
fig_dir <- file.path(DATA_PANELS, "figure_articles")
n_expected <- length(names(FIGURES)) + 1  # 18 figures + high_lexicon
n_existing <- length(list.files(fig_dir, pattern = "\\.parquet$"))

if (n_existing < n_expected) {
  ok <- run_step("R/extract_figure_articles.R", "Figure article extraction")
  if (!ok) { log_msg("STOPPING: Figure extraction failed"); quit(save = "no") }
} else {
  log_msg("SKIP: Figure articles already extracted")
}

# ====================================================================
# STEP 2: Select candidates for Flash Lite screening
# ====================================================================
candidates_path <- file.path(DATA_PANELS, "flash_lite_candidates.parquet")
if (!file.exists(candidates_path)) {
  ok <- run_step("R/select_candidates_for_screening.R", "Candidate selection")
  if (!ok) { log_msg("STOPPING: Candidate selection failed"); quit(save = "no") }
} else {
  log_msg("SKIP: Candidates already selected")
}

# ====================================================================
# STEP 3: Flash Lite screening (~$1)
# ====================================================================
flash_results_path <- file.path(DATA_PANELS, "flash_lite_results.csv")
if (!file.exists(flash_results_path)) {
  ok <- run_step("R/screen_flash_lite.R", "Flash Lite screening")
  if (!ok) { log_msg("STOPPING: Flash Lite screening failed"); quit(save = "no") }

  # Sanity check
  flash_dt <- fread(flash_results_path)
  n_pos <- sum(flash_dt$flash_label == 1, na.rm = TRUE)
  n_total <- nrow(flash_dt)
  pos_rate <- n_pos / n_total * 100

  log_msg(paste0("Flash Lite: ", n_pos, "/", n_total, " positive (",
                 round(pos_rate, 1), "%)"))

  if (n_pos < 10) {
    log_msg("!!! STOPPING: Too few Flash Lite positives (<10). Review rubric. !!!")
    quit(save = "no")
  }
} else {
  log_msg("SKIP: Flash Lite results already exist")
}

# ====================================================================
# STEP 4: Semantic search (GPU, ~30-60 min)
# ====================================================================
semantic_path <- file.path(DATA_PANELS, "semantic_matches.parquet")
if (!file.exists(semantic_path)) {
  ok <- run_step("R/semantic_search_seeds.py", "Semantic search", is_python = TRUE)
  if (!ok) {
    log_msg("WARNING: Semantic search failed — continuing without it")
  }
} else {
  log_msg("SKIP: Semantic matches already exist")
}

# ====================================================================
# STEP 5: Sample 4,000 for labeling
# ====================================================================
sample_path <- file.path(DATA_PANELS, "labeling_sample_final.parquet")
if (!file.exists(sample_path)) {
  ok <- run_step("R/sample_for_labeling.R", "Sample for labeling")
  if (!ok) { log_msg("STOPPING: Sampling failed"); quit(save = "no") }

  # Check class balance
  dt <- as.data.table(read_parquet(sample_path))
  strat <- dt[, .N, by = stratum]
  log_msg("Sample strata:")
  for (i in seq_len(nrow(strat))) {
    log_msg(paste0("  ", strat$stratum[i], ": ", strat$N[i]))
  }
} else {
  log_msg("SKIP: Labeling sample already exists")
}

# ====================================================================
# STEP 6: Claude Sonnet labeling (~$11)
# ====================================================================
labels_path <- file.path(DATA_PANELS, "antisem_labels_raw.csv")
if (!file.exists(labels_path)) {
  ok <- run_step("R/label_antisemitism.R", "Claude Sonnet labeling")
  if (!ok) { log_msg("STOPPING: Claude labeling failed"); quit(save = "no") }

  # Sanity check
  labels <- fread(labels_path)
  n_pos <- sum(labels$label == 1, na.rm = TRUE)
  pos_rate <- n_pos / nrow(labels) * 100
  log_msg(paste0("Claude labels: ", n_pos, "/", nrow(labels),
                 " positive (", round(pos_rate, 1), "%)"))

  if (pos_rate < 2) {
    log_msg("WARNING: Very low positive rate from Claude (<2%)")
  }
} else {
  # Check if labeling is complete
  labels <- fread(labels_path)
  sample_dt <- as.data.table(read_parquet(sample_path))
  if (nrow(labels) < nrow(sample_dt)) {
    log_msg(paste0("RESUMING Claude labeling: ", nrow(labels), "/",
                   nrow(sample_dt), " done"))
    ok <- run_step("R/label_antisemitism.R", "Claude Sonnet labeling (resume)")
    if (!ok) { log_msg("WARNING: Claude labeling failed on resume") }
  } else {
    log_msg("SKIP: Claude labeling already complete")
  }
}

# ====================================================================
# STEP 7: Gemini ensemble (250 least-confident, ~$3-5)
# ====================================================================
gemini_path <- file.path(DATA_PANELS, "antisem_labels_gemini.csv")
if (!file.exists(gemini_path)) {
  if (file.exists("R/label_antisemitism_gemini.R")) {
    ok <- run_step("R/label_antisemitism_gemini.R", "Gemini ensemble")
    if (!ok) { log_msg("WARNING: Gemini ensemble failed — continuing without it") }
  } else {
    log_msg("SKIP: Gemini ensemble script not found")
  }
} else {
  log_msg("SKIP: Gemini labels already exist")
}

# ====================================================================
# STEP 8: Reconciliation
# ====================================================================
reconciled_path <- file.path(DATA_PANELS, "antisem_labels_reconciled.csv")
if (!file.exists(reconciled_path)) {
  if (file.exists("R/reconcile_labels.R")) {
    ok <- run_step("R/reconcile_labels.R", "Label reconciliation")
    if (!ok) { log_msg("WARNING: Reconciliation failed — using raw labels") }
  } else {
    # If no reconciliation script, just use raw labels
    log_msg("No reconciliation script — copying raw labels as final")
    if (file.exists(labels_path)) {
      labels <- fread(labels_path)
      labels[, final_label := label]
      fwrite(labels, reconciled_path)
    }
  }
} else {
  log_msg("SKIP: Reconciled labels already exist")
}

# ====================================================================
# STEP 9: RoBERTa fine-tuning (~20 min GPU)
# ====================================================================
roberta_model_path <- file.path(MODELS_DIR, "roberta_antisemitism")
if (!dir.exists(roberta_model_path) || length(list.files(roberta_model_path)) < 3) {
  # Check for enough positive examples
  if (file.exists(reconciled_path)) {
    labels <- fread(reconciled_path)
    label_col <- if ("final_label" %in% names(labels)) "final_label" else "label"
    n_pos <- sum(labels[[label_col]] == 1, na.rm = TRUE)
    n_neg <- sum(labels[[label_col]] == 0, na.rm = TRUE)
    pos_rate <- n_pos / (n_pos + n_neg) * 100

    log_msg(paste0("Training data: ", n_pos, " positive, ", n_neg, " negative (",
                   round(pos_rate, 1), "% positive)"))

    if (n_pos < 20) {
      log_msg("!!! STOPPING: Too few positive examples for RoBERTa (<20) !!!")
      quit(save = "no")
    }
  }

  # Try calling Python directly for fine-tuning
  if (file.exists("R/finetune_roberta.py")) {
    ok <- run_step("R/finetune_roberta.py", "RoBERTa fine-tuning",
                   is_python = TRUE)
    if (!ok) { log_msg("WARNING: RoBERTa training failed") }
  } else {
    log_msg("SKIP: RoBERTa training script not found")
  }
} else {
  log_msg("SKIP: RoBERTa model already trained")
}

# ====================================================================
# STEP 10: RoBERTa corpus scoring (~2-3 hrs GPU)
# ====================================================================
scored_dir <- file.path(DATA_PANELS, "roberta_scored")
if (!dir.exists(scored_dir) || length(list.files(scored_dir, pattern = "\\.parquet$")) < 10) {
  if (file.exists("R/score_roberta.py")) {
    ok <- run_step("R/score_roberta.py", "RoBERTa corpus scoring",
                   is_python = TRUE)
    if (!ok) { log_msg("WARNING: Corpus scoring failed") }
  } else {
    log_msg("SKIP: RoBERTa scoring script not found")
  }
} else {
  log_msg("SKIP: RoBERTa scoring already done")
}

# ====================================================================
# STEP 11: Treatment panels (06b)
# ====================================================================
rmd_06b <- file.path(PROJECT_ROOT, "rmd", "06b_build_treatment_panels.Rmd")
if (file.exists(rmd_06b)) {
  # Check if panels already exist for all figures
  panel_files <- list.files(DATA_PANELS, pattern = "^did_panel_.*\\.parquet$")
  if (length(panel_files) < length(FIGURES)) {
    log_msg("Rendering 06b treatment panels...")
    cmd <- paste0('"', R_EXE, '" -e "rmarkdown::render(\'',
                  gsub("\\\\", "/", rmd_06b), '\')"')
    exit_code <- system(cmd, intern = FALSE)
    if (exit_code != 0) {
      log_msg("WARNING: 06b treatment panels failed")
    } else {
      log_msg("06b treatment panels complete")
    }
  } else {
    log_msg("SKIP: Treatment panels already built")
  }
}

# ====================================================================
# STEP 12: DiD estimation (07c)
# ====================================================================
rmd_07 <- file.path(PROJECT_ROOT, "rmd", "07c_did_estimation_antisemitism.Rmd")
if (!file.exists(rmd_07)) {
  rmd_07 <- file.path(PROJECT_ROOT, "rmd", "07_did_estimation.Rmd")
}
if (file.exists(rmd_07)) {
  model_files <- list.files(MODELS_DIR, pattern = "^did_.*\\.rds$")
  if (length(model_files) < length(FIGURES)) {
    log_msg("Rendering DiD estimation...")
    cmd <- paste0('"', R_EXE, '" -e "rmarkdown::render(\'',
                  gsub("\\\\", "/", rmd_07), '\')"')
    exit_code <- system(cmd, intern = FALSE)
    if (exit_code != 0) {
      log_msg("WARNING: DiD estimation failed")
    } else {
      log_msg("DiD estimation complete")
    }
  } else {
    log_msg("SKIP: DiD models already estimated")
  }
}

# ====================================================================
# STEP 13: Figures and tables (08)
# ====================================================================
rmd_08 <- file.path(PROJECT_ROOT, "rmd", "08_figures_tables.Rmd")
if (file.exists(rmd_08)) {
  log_msg("Rendering figures and tables...")
  cmd <- paste0('"', R_EXE, '" -e "rmarkdown::render(\'',
                gsub("\\\\", "/", rmd_08), '\')"')
  exit_code <- system(cmd, intern = FALSE)
  if (exit_code != 0) {
    log_msg("WARNING: Figures/tables generation failed")
  } else {
    log_msg("Figures and tables complete")
  }
}

# ====================================================================
# DONE
# ====================================================================
total_elapsed <- round(as.numeric(difftime(Sys.time(), t_start, units = "hours")), 1)
log_msg("============================================")
log_msg(paste0("=== OVERNIGHT PIPELINE COMPLETE (", total_elapsed, " hours) ==="))
log_msg("============================================")

# Summary of what exists
log_msg("Output summary:")
for (f in c("flash_lite_results.csv", "semantic_matches.parquet",
            "labeling_sample_final.parquet", "antisem_labels_raw.csv",
            "antisem_labels_gemini.csv", "antisem_labels_reconciled.csv")) {
  path <- file.path(DATA_PANELS, f)
  if (file.exists(path)) {
    size <- file.size(path)
    log_msg(paste0("  ", f, ": ", round(size / 1024, 0), " KB"))
  } else {
    log_msg(paste0("  ", f, ": NOT FOUND"))
  }
}
