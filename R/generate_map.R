# Generate USA map figure showing newspaper coverage
# This runs standalone (not through the pipeline) to avoid memory issues

library(usmap)
library(ggplot2)
library(data.table)

FIGURES_DIR <- "C:/Users/ammonsj/Ideas/figures"
OVERLEAF_FIGURES <- "C:/Users/ammonsj/Dropbox/Apps/Overleaf/Ideas Have Consequences/Figures"
DATA_PANELS <- "C:/Users/ammonsj/Ideas/data_panels"

dir.create(FIGURES_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(OVERLEAF_FIGURES, recursive = TRUE, showWarnings = FALSE)

# Load pre-parsed newspaper states
np_states <- fread(file.path(DATA_PANELS, "newspaper_states.csv"), encoding = "UTF-8")
np_with_state <- np_states[state != ""]
message("Newspapers with state: ", nrow(np_with_state))

# Count newspapers per state
state_counts <- np_with_state[, .(n_newspapers = .N), by = state]
message("States covered: ", nrow(state_counts))

# -- Map 1: Coverage heatmap --
p_coverage <- plot_usmap(
  data = state_counts, values = "n_newspapers",
  regions = "states", labels = FALSE
) +
  scale_fill_continuous(
    low = "#BBDEFB", high = "#0D47A1",
    name = "Number of\nNewspapers",
    na.value = "grey90"
  ) +
  labs(title = "American Stories Corpus: Newspaper Coverage by State") +
  theme(
    legend.position = "right",
    plot.title = element_text(size = 14, face = "bold", hjust = 0.5),
    legend.text = element_text(size = 9),
    legend.title = element_text(size = 10)
  )

for (dir in c(FIGURES_DIR, OVERLEAF_FIGURES)) {
  ggsave(file.path(dir, "fig8_usa_coverage.png"),
         p_coverage, width = 9, height = 6, dpi = 300)
  ggsave(file.path(dir, "fig8_usa_coverage.pdf"),
         p_coverage, width = 9, height = 6)
}
message("Coverage map saved!")

# -- Map 2: Treatment status (if panel exists) --
panel_path <- file.path(DATA_PANELS, "did_panel.parquet")
if (file.exists(panel_path)) {
  library(arrow)
  panel <- as.data.table(read_parquet(panel_path))

  np_info <- panel[, .(
    ever_treated = max(as.integer(!is.na(treat_date)), na.rm = TRUE)
  ), by = newspaper_name]

  # Merge with state info
  np_info <- merge(np_info, np_states[state != "", .(newspaper_name, state)],
                   by = "newspaper_name", all.x = TRUE)

  # Fuzzy match for short names
  unmatched <- np_info[is.na(state)]
  if (nrow(unmatched) > 0) {
    for (i in seq_len(nrow(unmatched))) {
      short_nm <- unmatched$newspaper_name[i]
      matches <- np_states[state != "" & startsWith(newspaper_name, short_nm)]
      if (nrow(matches) > 0) {
        np_info[newspaper_name == short_nm, state := matches$state[1]]
      }
    }
  }

  message("Newspapers with state (panel): ", sum(!is.na(np_info$state)),
          " / ", nrow(np_info))

  state_summary <- np_info[!is.na(state), .(
    n_treated = sum(ever_treated == 1),
    n_control = sum(ever_treated == 0),
    n_total   = .N
  ), by = state]

  state_summary[, group := fifelse(
    n_treated > 0 & n_control > 0, "Both Treated & Control",
    fifelse(n_treated > 0, "Treated Only",
            fifelse(n_control > 0, "Control Only", "No Data"))
  )]

  p_treatment <- plot_usmap(
    data = state_summary, values = "group",
    regions = "states", labels = FALSE
  ) +
    scale_fill_manual(
      values = c("Treated Only" = "#D32F2F",
                 "Control Only" = "#1976D2",
                 "Both Treated & Control" = "#7B1FA2"),
      na.value = "grey90",
      name = "Coughlin Coverage"
    ) +
    labs(title = "Geographic Distribution of Newspaper Treatment Status") +
    theme(
      legend.position = "bottom",
      plot.title = element_text(size = 14, face = "bold", hjust = 0.5),
      legend.text = element_text(size = 10),
      legend.title = element_text(size = 11)
    )

  for (dir in c(FIGURES_DIR, OVERLEAF_FIGURES)) {
    ggsave(file.path(dir, "fig8_usa_treatment_map.png"),
           p_treatment, width = 9, height = 6, dpi = 300)
    ggsave(file.path(dir, "fig8_usa_treatment_map.pdf"),
           p_treatment, width = 9, height = 6)
  }
  message("Treatment map saved!")
} else {
  message("Panel not yet available — treatment map will be generated when pipeline completes step 6.")
}
