# run_results_summary.R — Generate results tables from saved fect models
source("C:/Users/ammonsj/Ideas/_config.R")
library(data.table)

extract_att <- function(model, label) {
  att <- as.numeric(model[["att.avg"]])
  se  <- sd(model[["att.avg.boot"]])
  data.table(
    Model = label,
    ATT = round(att, 4),
    SE = round(se, 4),
    CI_lower = round(att - 1.96 * se, 4),
    CI_upper = round(att + 1.96 * se, 4),
    p_value = round(2 * pnorm(-abs(att / se)), 4)
  )
}

message("Loading models one at a time...")

out_ife <- readRDS(file.path(MODELS_DIR, "fect_ife.rds"))
r1 <- extract_att(out_ife, "IFE (primary)")
rm(out_ife); gc()

out_mc <- readRDS(file.path(MODELS_DIR, "fect_mc.rds"))
r2 <- extract_att(out_mc, "Matrix Completion")
rm(out_mc); gc()

out_fe <- readRDS(file.path(MODELS_DIR, "fect_fe.rds"))
r3 <- extract_att(out_fe, "Two-Way FE")
rm(out_fe); gc()

out_ife_lex <- readRDS(file.path(MODELS_DIR, "fect_ife_lexicon.rds"))
r4 <- extract_att(out_ife_lex, "IFE (lexicon outcome)")
rm(out_ife_lex); gc()

results <- rbindlist(list(r1, r2, r3, r4))
print(results)

# Save main results table
tex <- knitr::kable(results, format = "latex", booktabs = TRUE,
                    caption = "Average Treatment Effect on the Treated (ATT) Estimates",
                    col.names = c("Model", "ATT", "SE", "CI Lower", "CI Upper", "p-value"))
save_table(tex, "main_results")
message("Saved main results table to tables/ and Overleaf.")

# Save robustness table
rob_results <- rbindlist(list(r1, r4))
tex_rob <- knitr::kable(rob_results, format = "latex", booktabs = TRUE,
                         caption = "Robustness: Alternative Outcome Measures")
save_table(tex_rob, "robustness")
message("Saved robustness table.")
