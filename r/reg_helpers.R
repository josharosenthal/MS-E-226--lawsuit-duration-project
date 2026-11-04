# =============================================================================
# reg_helpers.R — shared pieces for the 08 regression scripts (08-a to 08-g; Josh, 1 Nov 2026;
# change 91). Sourced by them after 00_sample.R, not run on its own. TRAINING CASES ONLY.
#
# The specification comes from r/model_spec.csv, exported from model_spec.xlsx (one row per
# covariate or interaction; Yes / No / Sensitivity only for each model family):
#   run 1  rows with set = main and "Yes"
#   run 2  also the sensitivity rows, and rows marked "Sensitivity only"
#   run 3  run 2 without n_counsel (change 99; spec_keep() in xgb_helpers.R)
#   run 4  run 3 with the post-filing judge labels pooled (change 100; recode_run4() in xgb_helpers.R)
# Decisions (changes 85-90, DATA_DICTIONARY.md section 5):
#   - outcome log(1 + duration) for the duration models (cases that ended in court); ended
#     within 60 days for the short-case models (cases transferred out before day 60 dropped)
#   - counts as log(1 + count) in every model
#   - unpenalized models (OLS, quantile, plain logistic): each category measured against its
#     most common level; penalized models (ridge, lasso, group lasso): every level its own
#     column, dummies not standardized, logged counts (and the count x count product) scaled
#     to a standard deviation of 0.5
#   - category x category interactions cross all levels (cells involving a reference level
#     are left out of the unpenalized models, since the main effects cover them)
#   - plain logistic only: levels and interaction cells need at least 10 short and 10
#     non-short training cases (counted on ALL training cases, across folds); small levels
#     become "other (small)", which joins the reference level if it is still too small
#   - folds: as 07-c/d/e (consolidation groups kept together); penalties tuned by an inner
#     cross-validation on a second fold number (fold_inner) within each outer fold's training
#     part; the full-training fit tunes on the outer folds
# Change 93 (Josh, 1 Nov 2026): reference levels, scaling and centring from each fold's training
# part; the judge columns left out set by a rule (run 2, unpenalized; same fit); step-halving
# in the plain logistic; inner folds in parallel; lambda.min at the end of its path flagged;
# the model_spec.csv MD5 saved with each job; coefficients files mark single-court standard errors.
# Each job is one model, one run, and one outer fold (1-5) or "full" (the fit on all training
# cases, which writes the coefficients). Fold jobs save predictions for that fold's cases;
# 08-z_regression_summary.R scores them once all 5 folds of a model are in.
# Output: ~/scales_project/models/reg/
# =============================================================================

library(Matrix)
source(file.path(r_dir, "covariate_sets.R"))      # num_vars
source(file.path(r_dir, "xgb_helpers.R"))         # xgb_training_data(), outcome_data(), auc()
reg_dir <- file.path(project_dir, "models", "reg"); dir.create(reg_dir, showWarnings = FALSE, recursive = TRUE)
reg_seed <- 226; inner_seed <- 227; n_folds <- 5
n_threads <- as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", parallel::detectCores()))

# ---- The specification ------------------------------------------------------------
spec_terms <- function(family, run) {
  sp <- read.csv(file.path(r_dir, "model_spec.csv"), stringsAsFactors = FALSE)
  col <- c(duration_ols = "duration_ols", duration_quantile = "duration_quantile", short_case = "short_case")[[family]]
  sp <- sp[spec_keep(sp, col, run), ]
  main <- sp$term[sp$type != "interaction"]
  inter <- lapply(strsplit(sp$term[sp$type == "interaction"], " x ", fixed = TRUE), trimws)
  logged <- sp$term[sp$type == "count" & sp$log == "Yes"]
  list(main = main, inter = inter, logged = logged)
}

# ---- Data: training cases, the outcome, and the folds --------------------------------
reg_data <- function(family, run) {
  tm <- spec_terms(family, run)
  vars <- unique(c(tm$main, unlist(tm$inter), "court"))       # court is the cluster for standard errors
  have <- dbListFields(con, "train_fjc"); miss <- setdiff(vars, have)
  if (length(miss)) stop("Not in train_fjc: ", paste(miss, collapse = ", "))
  d_all <- xgb_training_data(list(vars), n_folds, reg_seed, inner_seed = inner_seed)
  if (run == 4) d_all <- recode_run4(d_all)
  od <- outcome_data(d_all, if (family == "short_case") "short_60" else "log_duration")
  od$terms <- tm; od
}

# ---- Design matrix ------------------------------------------------------------------
most_common <- function(f) names(which.max(table(f)))
rule10_ok <- function(g, y) { t1 <- tapply(y == 1, g, sum); t0 <- tapply(y == 0, g, sum)
                              names(t1)[!is.na(t1) & t1 >= 10 & t0 >= 10] }
# penalized: TRUE for ridge / lasso / group lasso; rule10: TRUE for the plain logistic.
# fit_rows: the rows the model is fitted on (a fold job's training part; all rows for "full").
# Reference levels, the SD-0.5 scaling and the centring of the count product come from these
# rows only (change 93), so nothing about the predicted fold is used to set them up. The 10/10
# rule still counts on ALL training cases (Josh, change 89; DATA_DICTIONARY.md section 5).
build_design <- function(od, penalized, rule10 = FALSE, fit_rows = seq_along(od$y)) {
  d <- od$d; y <- od$y; tm <- od$terms; notes <- character(0); fr <- fit_rows
  lc <- list()
  for (v in intersect(tm$main, num_vars)) {
    x <- if (v %in% tm$logged) log1p(d[[v]]) else d[[v]]
    lc[[v]] <- x
  }
  scale05 <- function(x) { m <- mean(x[fr]); s <- sd(x[fr]); if (!is.finite(s) || s == 0) x - m else (x - m) / (2 * s) }
  fac <- list()
  for (v in setdiff(tm$main, num_vars)) {
    f <- droplevels(d[[v]])
    if (rule10) {                                     # small levels -> "other (small)" -> reference
      ok <- rule10_ok(f, y); small <- setdiff(levels(f), ok)
      if (length(small)) {
        ch <- as.character(f); ch[ch %in% small] <- "other (small)"
        if (!("other (small)" %in% rule10_ok(ch, y))) ch[ch == "other (small)"] <- most_common(ch[fr])
        f <- factor(ch); notes <- c(notes, sprintf("%s: %d small level(s) merged", v, length(small)))
      }
    }
    if (nlevels(f) < 2) { notes <- c(notes, sprintf("%s: one level only, left out", v)); next }
    fac[[v]] <- if (penalized) f else relevel(f, most_common(f[fr]))
  }
  # judge_group in the unpenalized models (run 2): which judge columns are left out is set by a
  # rule (change 93) instead of by the QR step's column order. Judges are nested in courts, so
  # with court in the model some columns are exactly redundant:
  #   - in a court whose cases all have a court-specific judge, that court's judges add up to
  #     its court dummy: the court's BUSIEST judge is left out and is that court's reference;
  #   - all levels together add up to the intercept: the most common level that spans courts
  #     ("other (fewer than 20 training cases)", "unassigned", "(no judge listed)", or the plain
  #     logistic's "other (small)") is left out.
  # Only redundant columns go, so the fit is the same as before; only the labels change. Read the
  # judge coefficients as DIFFERENCES between judges of the same court: in a court that also has
  # cases in a cross-court level, the court's own judges are measured against that court's
  # cross-court cases, not its busiest judge.
  judge_drop <- character(0)
  if (!penalized && "judge_group" %in% names(fac) && "court" %in% names(d)) {
    jg <- fac$judge_group; ct <- as.character(d$court)
    n_courts <- tapply(ct[fr], jg[fr], function(z) length(unique(z)))
    nested <- names(n_courts)[!is.na(n_courts) & n_courts == 1]
    cross <- setdiff(names(n_courts)[!is.na(n_courts)], nested)
    only_nested <- tapply(jg[fr] %in% nested, ct[fr], all)
    sub <- jg[fr] %in% nested & ct[fr] %in% names(only_nested)[only_nested]
    if (any(sub)) {
      tab <- table(droplevels(jg[fr][sub]), ct[fr][sub])
      judge_drop <- rownames(tab)[apply(tab, 2, which.max)[colSums(tab) > 0]]
    }
    n_ref_courts <- length(judge_drop)
    if (length(cross)) judge_drop <- c(judge_drop, most_common(droplevels(jg[fr][jg[fr] %in% cross])))
    notes <- c(notes, sprintf("judge_group: busiest judge left out in %d court(s); cross-court reference \"%s\"",
                              n_ref_courts, if (length(cross)) tail(judge_drop, 1) else "none"))
  }
  # main effects
  df <- data.frame(fac, check.names = FALSE)
  for (v in names(lc)) df[[v]] <- if (penalized) scale05(lc[[v]]) else lc[[v]]
  ctr <- lapply(names(fac), function(v) if (penalized || (v == "judge_group" && length(judge_drop)))
                                          contrasts(fac[[v]], contrasts = FALSE) else "contr.treatment")
  names(ctr) <- names(fac)
  X <- sparse.model.matrix(reformulate(names(df), intercept = !penalized), df, contrasts.arg = ctr)
  grp <- c(if (!penalized) "(Intercept)", names(df)[attr(X, "assign")[attr(X, "assign") > 0]])
  if (length(judge_drop)) {                           # leave out the redundant judge columns
    drop <- which(grp == "judge_group" & colnames(X) %in% paste0("judge_group", judge_drop))
    X <- X[, -drop, drop = FALSE]; grp <- grp[-drop]
  }
  # interactions
  for (pr in tm$inter) {
    a <- pr[1]; b <- pr[2]; label <- paste(a, "x", b)
    if (!all(pr %in% c(names(lc), names(fac)))) { notes <- c(notes, sprintf("%s: left out (a variable has one level)", label)); next }
    if (all(pr %in% names(lc))) {                     # count x count: product of the centred logs
      z <- (lc[[a]] - mean(lc[[a]][fr])) * (lc[[b]] - mean(lc[[b]][fr]))
      if (penalized) z <- scale05(z)
      Z <- Matrix(z, ncol = 1, sparse = TRUE, dimnames = list(NULL, label))
    } else if (all(pr %in% names(fac))) {             # category x category: one column per cell
      if ("judge_group" %in% pr && length(judge_drop)) stop("judge_group interactions aren't supported with the judge reference rule")
      fa <- fac[[a]]; fb <- fac[[b]]; cell <- paste(fa, fb, sep = "\r")
      cand <- unique(cell)
      if (!penalized) {                               # cells with a reference level are covered by the main effects
        ra <- levels(fa)[1]; rb <- levels(fb)[1]
        cand <- cand[!(sub("\r.*", "", cand) == ra | sub(".*\r", "", cand) == rb)]
      }
      if (rule10) cand <- intersect(cand, rule10_ok(cell, y))
      if (!length(cand)) { notes <- c(notes, sprintf("%s: no cells kept", label)); next }
      j <- match(cell, cand); i <- which(!is.na(j))
      Z <- sparseMatrix(i = i, j = j[i], x = 1, dims = c(length(cell), length(cand)),
                        dimnames = list(NULL, paste0(label, ": ", sub("\r", " | ", cand))))
      notes <- c(notes, sprintf("%s: %d cells", label, length(cand)))
    } else stop("Interaction type not supported (only count x count and category x category): ", label)
    X <- cbind(X, Z); grp <- c(grp, rep(label, ncol(Z)))
  }
  list(X = as(X, "CsparseMatrix"), group = grp, notes = notes)
}

# ---- Fitting --------------------------------------------------------------------------
solve_sym <- function(A, b) { q <- qr(A, tol = 1e-9); cf <- qr.coef(q, b); cf[is.na(cf)] <- 0; list(coef = cf, rank = q$rank,
                              aliased = setdiff(seq_len(ncol(A)), q$pivot[seq_len(q$rank)])) }
fit_ols <- function(X, y) {
  s <- solve_sym(as.matrix(crossprod(X)), as.vector(crossprod(X, y)))
  s$fitted <- as.vector(X %*% s$coef); s
}
# IRLS on the sparse design, with step-halving as in glm() (change 93): if a step makes the
# deviance worse, it is halved (up to 25 times) before going on
logit_dev <- function(X, b, y) { mu <- plogis(as.vector(X %*% b))
  list(mu = mu, dev = -2 * sum(y * log(pmax(mu, 1e-15)) + (1 - y) * log(pmax(1 - mu, 1e-15)))) }
fit_logit <- function(X, y, maxit = 50, tol = 1e-8) {
  b <- numeric(ncol(X)); dv <- logit_dev(X, b, y); dev_old <- dv$dev; converged <- FALSE; halvings <- 0L
  for (it in seq_len(maxit)) {
    eta <- as.vector(X %*% b); mu <- dv$mu; w <- pmax(mu * (1 - mu), 1e-10)
    z <- eta + (y - mu) / w
    s <- solve_sym(as.matrix(crossprod(X, Diagonal(x = w) %*% X)), as.vector(crossprod(X, w * z)))
    b_new <- s$coef; dv <- logit_dev(X, b_new, y); h <- 0L
    while (!is.finite(dv$dev) || dv$dev > dev_old + tol * (abs(dev_old) + 0.1)) {
      if (h == 25L) break
      b_new <- (b_new + b) / 2; dv <- logit_dev(X, b_new, y); h <- h + 1L
    }
    halvings <- halvings + h; b <- b_new
    if (abs(dv$dev - dev_old) < tol * (abs(dv$dev) + 0.1)) { converged <- TRUE; break }
    dev_old <- dv$dev
  }
  s$coef <- b; s$fitted <- dv$mu; s$iterations <- it; s$converged <- converged; s$halvings <- halvings; s
}
# standard errors clustered by court (consolidation groups lie within courts).
# CAUTION (change 93): court is also in the model, so residuals add up to zero within each court
# and the court-dummy rows of the middle matrix are zero; with 94 courts the clustered variance
# has rank at most 93, far below the number of coefficients. A coefficient whose column is
# nonzero in only one court (each court dummy, each judge, a cell found in one court) rests on
# that one cluster, so its standard error isn't usable. n_courts counts these per column; the
# coefficients file marks se_usable = FALSE where n_courts < 2 (Josh: keep court clustering,
# with warnings).
# OPTION (a) (Josh, 1 Nov 2026; change 95): a second set, clustered by CONSOLIDATION GROUP
# (se_cluster_group; most groups are one case, so close to ordinary robust standard errors).
# se_reported takes the court-clustered value where it's usable (n_courts >= 2) and the
# group-clustered one otherwise (the court and judge dummies); se_type says which.
courts_per_column <- function(X, cluster) {
  X <- as(X, "CsparseMatrix"); ci <- as.integer(factor(cluster))
  vapply(seq_len(ncol(X)), function(j) { r <- X@i[seq.int(X@p[j] + 1L, length.out = X@p[j + 1L] - X@p[j])] + 1L
                                         length(unique(ci[r])) }, 1L)
}
cluster_se <- function(X, resid, cluster, bread_mat, keep) {
  Xk <- X[, keep, drop = FALSE]; B <- solve(bread_mat[keep, keep, drop = FALSE])
  G <- sparseMatrix(i = seq_along(cluster), j = as.integer(factor(cluster)), x = 1)
  U <- as.matrix(crossprod(G, Diagonal(x = resid) %*% Xk))
  n <- nrow(X); p <- length(keep); g <- ncol(G)
  if (g < 2) return(rep(NA_real_, ncol(X)))           # clustering needs at least 2 courts
  V <- (g / (g - 1)) * ((n - 1) / (n - p)) * B %*% crossprod(U) %*% B
  se <- rep(NA_real_, ncol(X)); se[keep] <- sqrt(pmax(diag(V), 0)); se
}
as_csr <- function(X) {                              # Matrix (column-compressed) -> SparseM row-compressed, for rq.fit.sfn
  tX <- as(t(X), "CsparseMatrix")
  methods::new(methods::getClass("matrix.csr", where = asNamespace("SparseM")),
               ra = as.numeric(tX@x), ja = tX@i + 1L, ia = tX@p + 1L, dimension = dim(X))
}
fit_quantile <- function(X, y, tau) {
  s <- solve_sym(as.matrix(crossprod(X)), as.vector(crossprod(X, y)))   # to find aliased columns
  keep <- setdiff(seq_len(ncol(X)), s$aliased)
  p <- length(keep)                                   # the solver's work space: its defaults assume a much sparser problem
  ctl <- quantreg::sfn.control(nsubmax = p * p, nnzlmax = p * p, tmpmax = max(6 * p, 10 * p * p), warn.mesg = FALSE)
  f <- quantreg::rq.fit.sfn(as_csr(X[, keep, drop = FALSE]), y, tau = tau, control = ctl)
  cf <- numeric(ncol(X)); cf[keep] <- f$coef
  list(coef = cf, aliased = s$aliased, fitted = as.vector(X %*% cf))
}
# Penalized fits. The inner cross-validation folds run in parallel, one process per fold
# (change 93): forked processes share the data, so memory grows by the fold subsets, not 5 full
# copies. lambda_boundary says whether lambda.min is the smallest or largest penalty tried
# ("none" otherwise); at "smallest" the best penalty may lie below the default path.
lambda_boundary <- function(lmin, lams) if (lmin <= min(lams)) "smallest" else if (lmin >= max(lams)) "largest" else "none"
n_par <- function(k) max(1L, min(k, n_threads))
# group lasso: fewer folds at once, since each forked fit needs its own dense working copies
# (the run 1 pilot ran out of 48 GB with 5 at once; Josh, 1 Nov 2026; change 96). Set
# REG_GL_WORKERS in the job's environment to change it.
gl_workers <- as.integer(Sys.getenv("REG_GL_WORKERS", "2"))
fit_glmnet <- function(X, y, family, alpha, foldid) {
  doParallel::registerDoParallel(cores = n_par(length(unique(foldid))))
  cv <- glmnet::cv.glmnet(X, y, family = family, alpha = alpha, foldid = foldid, standardize = FALSE,
                          type.measure = if (family == "binomial") "deviance" else "mse", parallel = TRUE)
  doParallel::stopImplicitCluster()
  list(model = cv, lambda = cv$lambda.min, boundary = lambda_boundary(cv$lambda.min, cv$lambda),
       predict = function(Xn) as.vector(predict(cv, newx = Xn, s = "lambda.min", type = "response")),
       coef = as.vector(coef(cv, s = "lambda.min")))
}
# grpreg's cv.grpreg can't run folds in parallel (version 3.6), so the cross-validation is done
# here the way cv.grpreg does it: the path on all rows first, then each fold refitted on the same
# lambdas; lambda.min minimizes the squared error pooled over all cases. Lambdas a fold's path
# didn't reach are left out.
fit_grpreg <- function(X, y, group, foldid) {
  Xd <- as.matrix(X); g <- factor(group, levels = unique(group))
  fit <- grpreg::grpreg(Xd, y, group = g, penalty = "grLasso", family = "gaussian")
  lam <- fit$lambda; K <- sort(unique(foldid))
  sse <- parallel::mclapply(K, function(k) {
    tr <- foldid != k
    fk <- grpreg::grpreg(Xd[tr, , drop = FALSE], y[tr], group = g, penalty = "grLasso", family = "gaussian", lambda = lam)
    p <- predict(fk, X = Xd[!tr, , drop = FALSE], type = "response")
    out <- rep(NA_real_, length(lam)); out[seq_len(ncol(p))] <- colSums((y[!tr] - p)^2); out
  }, mc.cores = min(n_par(length(K)), gl_workers))
  bad <- vapply(sse, function(e) inherits(e, "try-error") || !is.numeric(e), TRUE)
  if (any(bad)) stop("group lasso inner fold(s) ", paste(K[bad], collapse = ", "), " failed: ",   # a worker killed for memory returns NULL
                     paste(vapply(sse[bad], function(e) if (is.null(e)) "no result (the process was killed, probably out of memory)"
                                  else paste(as.character(e), collapse = " "), ""), collapse = " | "))
  E <- do.call(rbind, sse); ok <- which(apply(is.finite(E), 2, all))
  cve <- colSums(E[, ok, drop = FALSE]) / length(y); lmin <- lam[ok][which.min(cve)]
  list(model = fit, lambda = lmin, boundary = lambda_boundary(lmin, lam[ok]),
       predict = function(Xn) as.vector(predict(fit, X = as.matrix(Xn), lambda = lmin, type = "response")),
       coef = as.vector(coef(fit, lambda = lmin)))
}

# ---- One job ---------------------------------------------------------------------------
# model: ols, ridge, group_lasso, quantile_50, quantile_90, logistic, logistic_ridge, logistic_lasso
model_info <- list(
  ols            = list(family = "duration_ols",      penalized = FALSE, rule10 = FALSE),
  ridge          = list(family = "duration_ols",      penalized = TRUE,  rule10 = FALSE),
  group_lasso    = list(family = "duration_ols",      penalized = TRUE,  rule10 = FALSE),
  quantile_50    = list(family = "duration_quantile", penalized = FALSE, rule10 = FALSE),
  quantile_90    = list(family = "duration_quantile", penalized = FALSE, rule10 = FALSE),
  logistic       = list(family = "short_case",        penalized = FALSE, rule10 = TRUE),
  logistic_ridge = list(family = "short_case",        penalized = TRUE,  rule10 = FALSE),
  logistic_lasso = list(family = "short_case",        penalized = TRUE,  rule10 = FALSE))

run_reg_job <- function(model, args) {
  mi <- model_info[[model]]
  if (length(args) < 2) stop("Give the run (1-4) and the fold (1-5 or full), e.g.  Rscript 08-a_ols.R 1 3")
  run <- as.integer(args[1]); fold <- args[2]
  if (!(run %in% spec_runs) || !(fold %in% c(as.character(seq_len(n_folds)), "full"))) stop("Run must be 1-4; fold 1-5 or full.")
  need <- list(ridge = c("glmnet", "doParallel"), logistic_ridge = c("glmnet", "doParallel"),
               logistic_lasso = c("glmnet", "doParallel"), group_lasso = "grpreg",
               quantile_50 = "quantreg", quantile_90 = "quantreg")[[model]]
  for (pk in need) if (!requireNamespace(pk, quietly = TRUE))
    stop("The ", pk, " package isn't installed. Run once on the login node:  Rscript ~/scales_setup/r/08-0_install_packages.R")
  t0 <- Sys.time(); tag <- sprintf("%s_run%d_fold%s", model, run, fold)
  cat(sprintf("===== %s  started %s\n", tag, format(t0)))
  od <- reg_data(mi$family, run); n <- length(od$y)
  te <- if (fold == "full") integer(0) else which(od$d$fold == as.integer(fold))
  tr <- setdiff(seq_len(n), te)
  ds <- build_design(od, mi$penalized, mi$rule10, fit_rows = tr); X <- ds$X; y <- od$y
  cat(sprintf("%s cases, %d columns. %s\n", format(n, big.mark = ","), ncol(X), paste(ds$notes, collapse = "; ")))
  tau <- if (grepl("^quantile_", model)) as.numeric(sub("quantile_", "", model)) / 100 else NA
  used <- which(colSums(X[tr, , drop = FALSE] != 0) > 0)                # columns present in the training part
  Xtr <- X[tr, used, drop = FALSE]; ytr <- y[tr]
  inner <- if (fold == "full") od$d$fold[tr] else od$d$fold_inner[tr]
  out <- list(model = model, run = run, fold = fold, n_train = length(tr), n_test = length(te),
              n_columns = ncol(X), n_columns_used = length(used), notes = ds$notes,
              spec_md5 = unname(tools::md5sum(file.path(r_dir, "model_spec.csv"))))   # 08-z checks all folds match (change 93)
  pred_fun <- NULL
  if (model == "ols") {
    f <- fit_ols(Xtr, ytr); cf <- f$coef
    out$smear <- mean(exp(ytr - f$fitted)); pred_fun <- function(Xn) as.vector(Xn %*% cf)
  } else if (model %in% c("ridge", "logistic_ridge", "logistic_lasso")) {
    f <- fit_glmnet(Xtr, ytr, if (model == "ridge") "gaussian" else "binomial", if (model == "logistic_lasso") 1 else 0, inner)
    out$lambda <- f$lambda; out$lambda_boundary <- f$boundary; pred_fun <- f$predict; cf <- f$coef
    if (model == "ridge") out$smear <- mean(exp(ytr - f$predict(Xtr)))
  } else if (model == "group_lasso") {
    f <- fit_grpreg(Xtr, ytr, ds$group[used], inner)
    out$lambda <- f$lambda; out$lambda_boundary <- f$boundary; pred_fun <- f$predict; cf <- f$coef; out$smear <- mean(exp(ytr - f$predict(Xtr)))
  } else if (grepl("^quantile_", model)) {
    f <- fit_quantile(Xtr, ytr, tau); cf <- f$coef; out$tau <- tau
    out$null_quantile <- unname(quantile(ytr, tau)); pred_fun <- function(Xn) as.vector(Xn %*% cf)
  } else if (model == "logistic") {
    f <- fit_logit(Xtr, ytr); cf <- f$coef; out$converged <- f$converged; out$iterations <- f$iterations; out$halvings <- f$halvings
    if (!f$converged) cat("WARNING: the logistic fit did not converge in", f$iterations, "iterations\n")
    pred_fun <- function(Xn) plogis(as.vector(Xn %*% cf))
  }
  out$base_rate <- mean(ytr)
  if (fold != "full") {
    p <- pred_fun(X[te, used, drop = FALSE])
    out$pred <- data.frame(row = te, fold = as.integer(fold), y = y[te], pred = p)
    saveRDS(out, file.path(reg_dir, paste0(tag, ".rds")))
  } else {                                                              # coefficients of the full fit
    nm <- colnames(Xtr); is_pen <- mi$penalized
    if (is_pen) { nm <- c("(Intercept)", nm); se <- NA } else {
      keep <- setdiff(seq_along(cf), f$aliased)
      bread <- if (model == "ols") as.matrix(crossprod(Xtr)) else if (model == "logistic")
        as.matrix(crossprod(Xtr, Diagonal(x = f$fitted * (1 - f$fitted)) %*% Xtr)) else NULL
      if (!is.null(bread)) {
        se  <- cluster_se(Xtr, ytr - f$fitted, od$d$court[tr], bread, keep)
        seg <- cluster_se(Xtr, ytr - f$fitted, od$d$cons_group[tr], bread, keep)
      } else { se <- NA; seg <- NA }                                    # quantile: no standard errors
    }
    if (is_pen) seg <- NA
    nc <- courts_per_column(Xtr, od$d$court[tr]); if (is_pen) nc <- c(length(unique(od$d$court[tr])), nc)
    co <- data.frame(term = nm, group = if (is_pen) c("(Intercept)", ds$group[used]) else ds$group[used],
                     coefficient = cf, se_cluster_court = se, n_courts = nc,
                     se_usable = if (is_pen || model %in% c("quantile_50", "quantile_90")) NA else nc >= 2,
                     se_cluster_group = seg)
    if (model %in% c("ols", "logistic")) {
      co$se_reported <- ifelse(co$se_usable, co$se_cluster_court, co$se_cluster_group)
      co$se_type <- ifelse(co$se_usable, "court", "consolidation group")
    }
    if (!is_pen) co$aliased <- seq_along(cf) %in% f$aliased
    write.csv(co, file.path(reg_dir, paste0(tag, "_coefficients.csv")), row.names = FALSE)
    out$coefficients <- nrow(co); saveRDS(out, file.path(reg_dir, paste0(tag, ".rds")))
  }
  cat(sprintf("===== %s  finished %s (%.1f min)\n", tag, format(Sys.time()), as.numeric(difftime(Sys.time(), t0, units = "mins"))))
}
