# Test the USA map generation
library(usmap)
library(ggplot2)
library(data.table)
source("C:/Users/ammonsj/Ideas/_config.R")

# Load pre-parsed newspaper states
np_states <- fread(file.path(DATA_PANELS, "newspaper_states.csv"), encoding = "UTF-8")
message("Loaded ", nrow(np_states), " newspaper entries, ",
        sum(np_states$state != ""), " with state")

# For now (before treatment panel exists), show all newspapers in sample
np_with_state <- np_states[state != ""]

state_counts <- np_with_state[, .(n_newspapers = .N), by = state]
state_counts[, full := state.name[match(state, state.abb)]]
state_counts[state == "DC", full := "District of Columbia"]

message("States covered: ", nrow(state_counts))
message("\nTop 10 states by newspaper count:")
print(head(state_counts[order(-n_newspapers)], 10))

# Map: shade states by number of newspapers
p_map <- plot_usmap(
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

ggsave(file.path(FIGURES_DIR, "fig8_usa_coverage_draft.png"),
       p_map, width = 9, height = 6, dpi = 300)
ggsave(file.path(FIGURES_DIR, "fig8_usa_coverage_draft.pdf"),
       p_map, width = 9, height = 6)
message("Draft coverage map saved to figures/")
