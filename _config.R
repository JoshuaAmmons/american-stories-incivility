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

# Pandoc (bundled with RStudio)
Sys.setenv(RSTUDIO_PANDOC = "C:/Program Files/RStudio/resources/app/bin/quarto/bin/tools")

# Ensure directories exist
for (d in c(DATA_RAW, DATA_PARQUET, DATA_PANELS, MODELS_DIR,
            FIGURES_DIR, TABLES_DIR, OUTPUT_HTML, OUTPUT_LOGS,
            OVERLEAF_FIGURES, OVERLEAF_TABLES)) {
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
}

# Data parameters
YEARS_ALL   <- as.character(1774:1960)

# Political figures registry — each entry defines a treatment analysis
FIGURES <- list(
  coughlin = list(
    name = "Father Coughlin",
    study_start = 1926, study_end = 1960,
    keywords = c("coughlin", "father coughlin", "social justice",
                 "national union for social justice"),
    min_year = 1920  # earliest valid match (avoid pre-1900 false positives)
  ),
  smith = list(
    name = "Gerald L.K. Smith",
    study_start = 1933, study_end = 1960,
    keywords = c("gerald smith", "gerald l.k. smith",
                 "america first party", "christian nationalist",
                 "cross and the flag"),
    min_year = 1930
  ),
  lemke = list(
    name = "William Lemke",
    study_start = 1932, study_end = 1960,
    keywords = c("william lemke", "frazier.lemke"),
    min_year = 1920
  ),
  dilling = list(
    name = "Elizabeth Dilling",
    study_start = 1934, study_end = 1960,
    keywords = c("elizabeth dilling", "red network",
                 "patriotic research", "mothers. movement"),
    min_year = 1930
  ),
  long = list(
    name = "Huey Long",
    study_start = 1928, study_end = 1960,
    keywords = c("huey long", "share our wealth",
                 "every man a king", "kingfish"),
    min_year = 1920
  ),
  kearney = list(
    name = "Denis Kearney",
    study_start = 1875, study_end = 1900,
    keywords = c("denis kearney", "kearneyism", "kearneyites",
                 "workingmen.?s party", "chinese must go"),
    min_year = 1870
  ),
  ross = list(
    name = "Edward A. Ross",
    study_start = 1895, study_end = 1940,
    keywords = c("edward ross", "edward a.? ross",
                 "old world in the new", "race suicide"),
    min_year = 1890
  ),
  grant = list(
    name = "Madison Grant",
    study_start = 1910, study_end = 1940,
    keywords = c("madison grant", "passing of the great race",
                 "conquest of a continent"),
    min_year = 1905
  ),
  stoddard = list(
    name = "Lothrop Stoddard",
    study_start = 1915, study_end = 1945,
    keywords = c("lothrop stoddard", "rising tide of color",
                 "revolt against civilization"),
    min_year = 1910
  )
)

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
