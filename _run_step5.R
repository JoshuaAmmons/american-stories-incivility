Sys.setenv(RSTUDIO_PANDOC = "C:/Program Files/RStudio/resources/app/bin/quarto/bin/tools")
rmarkdown::render(
  "C:/Users/ammonsj/Ideas/rmd/05_random_forest.Rmd",
  output_file = "C:/Users/ammonsj/Ideas/output/html/05_random_forest.html",
  output_format = "html_document",
  envir = new.env(parent = globalenv()),
  quiet = FALSE
)
