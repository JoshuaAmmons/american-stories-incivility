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
    study_start = 1900, study_end = 1960,
    keywords = c("coughlin", "father coughlin",
                 "national union for social justice"),
    min_year = 1920  # earliest valid match (avoid pre-1900 false positives)
    # REMOVED: "social justice" — too generic, matches unrelated contexts
  ),
  smith = list(
    name = "Gerald L.K. Smith",
    study_start = 1900, study_end = 1960,
    keywords = c("gerald l.? ?k.? ?smith",
                 "(?=.*gerald smith).*christian nationalist",
                 "(?=.*gerald smith).*america first",
                 "cross and the flag"),
    min_year = 1930
    # FIXED: "gerald smith" alone too common; require co-occurrence
    # REMOVED: standalone "america first party", "christian nationalist"
  ),
  lemke = list(
    name = "William Lemke",
    study_start = 1900, study_end = 1960,
    keywords = c("william lemke", "frazier.lemke"),
    min_year = 1920
  ),
  dilling = list(
    name = "Elizabeth Dilling",
    study_start = 1900, study_end = 1960,
    keywords = c("elizabeth dilling",
                 "(?=.*dilling).*red network",
                 "(?=.*dilling).*patriotic research",
                 "(?=.*dilling).*mothers. movement"),
    min_year = 1930
    # FIXED: "red network", "patriotic research", "mothers movement"
    #   all too generic alone; require co-occurrence with "dilling"
  ),
  long = list(
    name = "Huey Long",
    study_start = 1900, study_end = 1960,
    keywords = c("huey long", "share our wealth",
                 "every man a king"),
    min_year = 1920
    # REMOVED: "kingfish" — also a common fish name
  ),
  kearney = list(
    name = "Denis Kearney",
    study_start = 1875, study_end = 1960,
    keywords = c("denis kearney", "kearneyism", "kearneyites",
                 "workingmen.?s party"),
    min_year = 1870
  ),
  ross = list(
    name = "Edward A. Ross",
    study_start = 1900, study_end = 1960,
    keywords = c("edward a.? ross",
                 "(?=.*edward ross).*sociolog",
                 "old world in the new"),
    min_year = 1890
    # FIXED: "edward ross" alone too common; require co-occurrence
    # REMOVED: "race suicide" — generic eugenics term, not specific to Ross
  ),
  grant = list(
    name = "Madison Grant",
    study_start = 1900, study_end = 1960,
    keywords = c("madison grant", "passing of the great race"),
    min_year = 1905
    # REMOVED: "conquest of a continent" — too generic
  ),
  stoddard = list(
    name = "Lothrop Stoddard",
    study_start = 1900, study_end = 1960,
    keywords = c("lothrop stoddard", "rising tide of color"),
    min_year = 1910
    # REMOVED: "revolt against civilization" — too generic
  ),

  # --- America First Committee / Noninterventionist figures ---

  stuart = list(
    name = "Robert D. Stuart Jr.",
    study_start = 1900, study_end = 1960,
    keywords = c("robert d. stuart", "robert d stuart"),
    min_year = 1920
  ),
  wood = list(
    name = "Robert E. Wood",
    study_start = 1900, study_end = 1960,
    keywords = c("robert e. wood", "robert e wood"),
    min_year = 1920
  ),
  lindbergh = list(
    name = "Charles A. Lindbergh",
    study_start = 1900, study_end = 1960,
    keywords = c("lindbergh"),
    min_year = 1920
  ),
  nye = list(
    name = "Sen. Gerald P. Nye",
    study_start = 1900, study_end = 1960,
    keywords = c("gerald nye", "gerald p. nye",
                 "senator nye"),
    min_year = 1920
  ),
  flynn = list(
    name = "John T. Flynn",
    study_start = 1900, study_end = 1960,
    keywords = c("john t. flynn", "john t flynn"),
    min_year = 1920
  ),
  wheeler = list(
    name = "Burton K. Wheeler",
    study_start = 1900, study_end = 1960,
    keywords = c("burton wheeler", "burton k. wheeler",
                 "senator wheeler"),
    min_year = 1920
  ),
  mccormick = list(
    name = "Robert R. McCormick",
    study_start = 1900, study_end = 1960,
    keywords = c("robert r. mccormick", "robert r mccormick",
                 "colonel mccormick"),
    min_year = 1920
  ),
  johnson_h = list(
    name = "Hugh S. Johnson",
    study_start = 1900, study_end = 1960,
    keywords = c("hugh s. johnson", "hugh s johnson",
                 "general hugh johnson"),
    min_year = 1920
  ),
  ford = list(
    name = "Henry Ford",
    study_start = 1900, study_end = 1960,
    keywords = c("henry ford"),
    min_year = 1920
  )
)

# Antisemitism lexicon — seed terms for stratified sampling only
# (Final classification uses fine-tuned RoBERTa Large, not lexicon)
#
# Expanded based on historical research:
#   - USHMM Holocaust Encyclopedia
#   - ADL "Antisemitism in American History"
#   - Brandeis "Antisemitism in the Gilded Age and Progressive Era"
#   - PBS "Ford's Anti-Semitism"
#   - JSTOR Daily "How 'Shoddy' Became an Anti-Semitic Slur"
#   - Wikipedia "History of antisemitism in the United States"
#   - Genome.gov "Eugenics and Scientific Racism"
#   - Migration Policy Institute on Johnson-Reed Act (1924)
#   - LOC Research Guide on Leo Frank trial
#   - NPS on General Order No. 11 (Grant, 1862)
#
ANTISEM_LEXICON <- list(
  slurs_epithets = c(
    # Direct slurs (all eras)
    "kike", "sheeny", "yid", "shylock", "jewess",
    "hook nose", "hooked nose", "jew boy", "jewboy",
    # Civil War era
    "shoddy", "mr shoddy",
    # Literary/cultural references used as slurs
    "fagin"
  ),
  stereotypes_characterization = c(
    # Greed/finance stereotypes
    "greedy jew", "jewish parasite", "jewish vermin",
    "jewish usurer", "jewish moneylender", "jewish peddler",
    "jewish sharper", "hebrew sharper",
    "jewish rag dealer", "jewish clothier",
    # Dual loyalty / unpatriotic
    "unpatriotic jew", "disloyal jew",
    # Racial characterization (post-1870s "scientific" antisemitism)
    "semitic race", "jewish race", "hebrew race",
    "racial jew", "jewish type"
  ),
  conspiracy_control = c(
    # Financial conspiracy
    "jewish bankers", "international jew", "jewish conspiracy",
    "jewish control", "jewish influence", "jewish domination",
    "jewish supremacy", "jewish dictatorship",
    "jewish money", "jewish gold", "jewish capital",
    "money power", "gold ring",
    # Protocols / world domination
    "protocols of the elders", "protocols of zion",
    "world jewry", "world jewish", "jewish world power",
    "zionist plot", "zionist conspiracy",
    # Media/culture control (Dearborn Independent themes)
    "jewish press", "jewish controlled press",
    "jewish hollywood", "jewish theater",
    # Political conspiracy
    "jewish bolshevism", "judeo-bolshevik", "judeo bolshevik",
    "jewish communism", "jewish radicalism"
  ),
  dehumanization_religious = c(
    "christ killer", "christ-killer",
    "chosen people of satan", "synagogue of satan",
    "enemy of christ", "enemies of christianity"
  ),
  coded_populist = c(
    # Gilded Age / Populist era coded language
    # These terms aren't always antisemitic, but in context often were
    "international bankers", "international financiers",
    "international gold ring", "gold conspiracy",
    "cosmopolitan elite", "rootless cosmopolitan",
    "alien influence", "alien element",
    "money trust", "money changers",
    "wall street conspiracy",
    # Rothschild as code
    "rothschild", "rothschilds",
    "house of rothschild"
  ),
  eugenics_immigration = c(
    # Eugenics movement (1890s-1930s) — deeply tied to antisemitism
    "race suicide", "racial hygiene", "racial purity",
    "undesirable races", "worthless racial types",
    "defective race", "inferior race",
    "racial degeneration", "racial contamination",
    "pollute the american", "mongrelization",
    # Immigration restriction (with antisemitic framing)
    "hebrew invasion", "jewish invasion",
    "jewish immigration menace", "jewish flood",
    "undesirable immigrant", "unassimilable",
    "eastern european jew", "russian jew menace",
    # Eugenics figures/orgs often invoked in antisemitic contexts
    "national origins quota", "immigration restriction league"
  ),
  historical_events_markers = c(
    # Historical antisemitic tropes
    "wandering jew", "blood libel", "ritual murder",
    "jewish ritual", "passover murder",
    # Civil War antisemitism
    "general order no 11", "jews as a class",
    # Leo Frank case (1913-1915) — watershed antisemitic event
    "leo frank", "frank case",
    # Exclusion / social discrimination
    "restricted clientele", "christians only",
    "no hebrews", "hebrews need not apply",
    "gentiles only", "no jews",
    # Dearborn Independent (1920-1927)
    "dearborn independent", "international jew",
    # Tom Watson's antisemitic campaigns
    "jew money has debased"
  ),
  menace_threat = c(
    # "Jewish problem/question" framing
    "jewish menace", "jewish peril", "jewish problem",
    "jewish question", "jewish danger", "jewish threat",
    "hebrew menace", "hebrew problem",
    # Persecution justification
    "jews deserve", "jews brought upon themselves",
    # Expulsion/restriction rhetoric
    "expel the jews", "rid of the jews", "drive out the jews"
  )
)
ANTISEM_TERMS_ALL <- unique(unlist(ANTISEM_LEXICON))

# RoBERTa model paths
ROBERTA_MODEL_DIR <- file.path(MODELS_DIR, "roberta_antisemitism")
ROBERTA_SCORED_DIR <- file.path(DATA_PANELS, "roberta_scored")

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
