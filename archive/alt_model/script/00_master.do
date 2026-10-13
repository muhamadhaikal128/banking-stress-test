*******************************************************************************
* Indonesian Banking Solvency Stress Test — ALTERNATIVE (logit) MODEL, ARCHIVED (comparison only).
*   Official results: script/dofile_fixed.do -> output/fixed/. This model reads input/ and writes
*   only inside archive/alt_model/.
*
* Top-down, bank-level solvency stress test (Prospera Stress Test Handbook):
*   macro scenarios -> NPL & provision satellite models + MTM securities losses
*   -> income statement -> capital -> CAR / Tier 1 -> failed banks (CAR < 8%)
*
* Folder layout (relative to $root):
*   input/         raw inputs only (never written by the code)
*   archive/alt_model/intermediate/  Stata datasets produced by this pipeline
*   archive/alt_model/output/        figures/, tables/, logs/
*   archive/alt_model/script/        this pipeline (do-files)
*
* Run:  do "<project root>/archive/alt_model/script/00_master.do"
*******************************************************************************

clear all
set more off
version 17

*----------------------------------------------------------------------------
* 1. Paths  (edit $root if the project folder moves)
*----------------------------------------------------------------------------
global root   "C:/Users/LENOVO05/github/banking-stress-test"
global input  "$root/input"
global inter  "$root/archive/alt_model/intermediate"
global output "$root/archive/alt_model/output"
global code   "$root/archive/alt_model/script"

global macro_xlsx "$input/Solvency ST.xlsx"
global bank_xlsx  "$input/Stress Testing Manual - Excel Template.xlsx"
global bank_sheet "Output Sheet (Copy)"   // values snapshot; "Output Sheet" holds live BQL formulas

*----------------------------------------------------------------------------
* 2. Model settings
*    Economic parameters (tax, payout, duration, SRBI share, k_stress) are read
*    from the "Parameters" sheet of Solvency ST.xlsx in 01_import.do.
*----------------------------------------------------------------------------
global horizon     4        // forecast quarters (scenario sheets may hold more)
global est_start   "2015q1" // first quarter used to estimate satellite models
global exclude     "BANK"   // tickers excluded as reporting outliers (handbook p.12)
global covid_start "2020q2" // OJK loan-restructuring forbearance window,
global covid_end   "2022q4" //   controlled for so it does not bias macro elasticities
global beta_loan   1        // pass-through of policy-rate change to loan yields
global beta_dep    1        // pass-through of policy-rate change to funding cost
global use_overlay 1        // 1 = add k_stress provision overlay (non-linearity in stress)
global car_min     8        // failure threshold, CAR (%)
global t1_min      6        // Tier 1 minimum (%), reported only

*----------------------------------------------------------------------------
* 3. Pipeline
*----------------------------------------------------------------------------
cap log close _all
log using "$output/logs/stress_test.log", replace text name(main)

do "$code/01_import.do"        // raw Excel -> intermediate datasets
do "$code/02_prepare.do"       // bank panel cleaning + financial ratios
do "$code/03_satellite.do"     // NPL & provision models (estimation)
do "$code/04_projection.do"    // scenario projection: P&L and capital
do "$code/05_results.do"       // tables & figures -> output/

log close main
