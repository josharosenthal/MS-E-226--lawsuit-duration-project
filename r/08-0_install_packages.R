# =============================================================================
# 08-0_install_packages.R — install the R packages the 08 regression scripts need, into your
# own R library (Josh, 1 Nov 2026; change 91). Run ONCE, on the login node (compute nodes
# may not reach CRAN), in the FarmShare shell:
#   module load r && Rscript ~/scales_setup/r/08-0_install_packages.R
#   glmnet    ridge and lasso (08-b, 08-f, 08-g)
#   doParallel  runs glmnet's inner cross-validation folds in parallel (change 93); also installs foreach
#   grpreg    group lasso (08-c)
#   quantreg  quantile regression (08-d1, 08-d2); also installs SparseM
# Matrix comes with R. Packages already installed are left alone.
# =============================================================================

lib <- Sys.getenv("R_LIBS_USER")
if (!nzchar(lib)) stop("R_LIBS_USER is not set - can't tell where your own R library is.")
dir.create(lib, showWarnings = FALSE, recursive = TRUE)
need <- c("glmnet", "doParallel", "grpreg", "quantreg", "Matrix")
missing <- need[!vapply(need, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) {
  cat("Installing:", paste(missing, collapse = ", "), "into", lib, "\n")
  install.packages(missing, lib = lib, repos = "https://cloud.r-project.org")
} else cat("All installed already.\n")
for (p in c(need, "foreach", "SparseM")) cat(sprintf("  %-10s %s\n", p, if (requireNamespace(p, quietly = TRUE)) as.character(packageVersion(p)) else "NOT INSTALLED"))
