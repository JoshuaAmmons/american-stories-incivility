# _config.R — Shared project configuration
# Source this file at the top of every Rmd

# Paths
PROJECT_ROOT  <- "C:/Users/ammonsj/Ideas"
DATA_RAW      <- file.path(PROJECT_ROOT, "data_raw")
DATA_PARQUET  <- file.path(PROJECT_ROOT, "data_parquet")
DATA_PANELS   <- file.path(PROJECT_ROOT, "data_panels")
MODELS_DIR    <- file.path(PROJECT_ROOT, "models")
FIGURES_DIR   <- file.path(PROJECT_ROOT, "figures")
TABLES_DIR    <- file.path(PROJECT_ROOT, "tables")
OUTPUT_HTML   <- file.path(PROJECT_ROOT, "output", "html")
OUTPUT_LOGS   <- file.path(PROJECT_ROOT, "output", "logs")

# Overleaf output paths
OVERLEAF_FIGURES <- "C:/Users/ammonsj/Dropbox/Apps/Overleaf/Ideas Have Consequences/Figures"
OVERLEAF_TABLES  <- "C:/Users/ammonsj/Dropbox/Apps/Overleaf/Ideas Have Consequences/Tables"

# R executable
R_EXE <- "C:/Program Files/R/R-4.4.1/bin/Rscript.exe"

# Python executable (for reticulate)
PYTHON_EXE <- "C:/Users/ammonsj/AppData/Local/Programs/Python/Python313/python.exe"

# Ensure directories exist
for (d in c(DATA_RAW, DATA_PARQUET, DATA_PANELS, MODELS_DIR,
            FIGURES_DIR, TABLES_DIR, OUTPUT_HTML, OUTPUT_LOGS,
            OVERLEAF_FIGURES, OVERLEAF_TABLES)) {
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
}

# Data parameters
YEARS_ALL   <- as.character(1774:1960)
YEARS_STUDY <- as.character(1926:1942)  # Coughlin window with buffer

# Random seed
SEED <- 42
set.seed(SEED)

# Helper to save figure to both local and Overleaf
save_figure <- function(plot_obj, filename, width = 7, height = 5, dpi = 300) {
  for (dir in c(FIGURES_DIR, OVERLEAF_FIGURES)) {
    ggsave(
      filename = file.path(dir, paste0(filename, ".pdf")),
      plot = plot_obj, width = width, height = height, dpi = dpi
    )
    ggsave(
      filename = file.path(dir, paste0(filename, ".png")),
      plot = plot_obj, width = width, height = height, dpi = dpi
    )
  }
}

# Helper to save table to both local and Overleaf
save_table <- function(tex_string, filename) {
  for (dir in c(TABLES_DIR, OVERLEAF_TABLES)) {
    writeLines(tex_string, file.path(dir, paste0(filename, ".tex")))
  }
}

message("Config loaded. Project root: ", PROJECT_ROOT)
