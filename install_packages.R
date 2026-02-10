# install_packages.R — One-time package installation
# Run this before the pipeline

needed <- c(
  "arrow",
  "quanteda",
  "quanteda.textstats",
  "quanteda.textplots",
  "text2vec",
  "irlba",
  "reticulate",
  "ranger",
  "fixest",
  "fect",
  "panelView",
  "did",
  "data.table",
  "dplyr",
  "tidyr",
  "stringr",
  "lubridate",
  "ggplot2",
  "patchwork",
  "modelsummary",
  "stargazer",
  "pROC",
  "rmarkdown",
  "knitr"
)

installed <- installed.packages()[, "Package"]
to_install <- setdiff(needed, installed)

if (length(to_install) > 0) {
  message("Installing: ", paste(to_install, collapse = ", "))
  install.packages(to_install, repos = "https://cloud.r-project.org")
} else {
  message("All packages already installed.")
}

# Verify
for (pkg in needed) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    warning("Failed to install: ", pkg)
  } else {
    message("OK: ", pkg, " (", packageVersion(pkg), ")")
  }
}
