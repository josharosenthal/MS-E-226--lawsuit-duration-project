# =============================================================================
# covariate_sets.R — the covariate sets used by 06_plots_and_correlations.R,
# 07-a_random_forest.R, 07-b_short_case_forest.R and 07-c_xgboost.R, kept in one
# place so the scripts can't drift apart (DATA_DICTIONARY.md, "Model" column).
#
#   main               covariates known at, or close to, filing. Representation is
#                      measured as follows (Josh, 28 Oct 2026; change 70):
#                        plaintiff_firm_cases     as built: "pro se / no counsel" is its own level
#                                                 (pro se is mostly known at filing)
#                        defendant_firm_appeared  defendant_firm_rank with "no counsel listed"
#                                                 folded into "not in list" (only where a lawyer appeared)
#                        defendant_pro_se         FJC PROSE says the defendant (or both) is pro se
#   main_plus_counsel  main + n_counsel, to show what n_counsel (now out: too leaky,
#                      02-g_data_checks_counsel.R) would add
#   sensitivity        main + the leaky ones kept out of main: judge_group,
#                      judge_type, any_referral, the original defense firm variable
#                      (defendant_firm_rank), pro_se and n_counsel.
#                      The gain over main is an UPPER BOUND on what they add.
# Not used: circuit and city (court instead), cause_title (cause_group instead),
# is_consolidated (consolidation_role instead) - see the redundant pairs in DATA_DICTIONARY.md.
# =============================================================================

main_vars <- c("n_parties", "n_plaintiffs", "n_defendants",
               "year_dir", "filing_month", "filing_weekday", "case_number_parity",
               "court", "nature_suit", "cause_group", "jurisdiction", "jury_demand", "arrival_route",
               "class_action_alleged", "in_forma_pauperis", "diversity_residence", "county_area_class",
               "first_plaintiff_type", "first_defendant_type",
               "plaintiff_firm_cases", "defendant_firm_appeared", "defendant_pro_se", "plaintiff_org_attorney",
               "has_related_case", "consolidation_role", "tro_pi_motion_60d", "amicus")
sens_extra <- c("judge_group", "judge_type", "any_referral",
                "defendant_firm_rank", "pro_se", "n_counsel")
num_vars   <- c("n_parties", "n_counsel", "n_plaintiffs", "n_defendants")

# make_sets(have, model_sets): the sets named in model_sets, keeping only columns in `have`
make_sets <- function(have, model_sets = c("main", "main_plus_counsel", "sensitivity")) {
  missing_vars <- setdiff(c(main_vars, sens_extra), have)
  if (length(missing_vars)) warning("Not in train_fjc (skipped): ", paste(missing_vars, collapse = ", "), call. = FALSE)
  m <- intersect(main_vars, have); s <- intersect(sens_extra, have)
  list(main = m, main_plus_counsel = c(m, intersect("n_counsel", have)),
       sensitivity = c(m, s))[model_sets]
}
