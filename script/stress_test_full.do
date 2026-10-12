*******************************************************************************
* Indonesian Banking Solvency Stress Test — MASTER
*
* Top-down, bank-level solvency stress test (Prospera Stress Test Handbook):
*   macro scenarios -> NPL & provision satellite models + MTM securities losses
*   -> income statement -> capital -> CAR / Tier 1 -> failed banks (CAR < 8%)
*
* Folder layout (relative to $root):
*   input/         raw inputs only (never written by the code)
*   intermediate/  Stata datasets produced by the pipeline
*   output/        figures/, tables/, logs/
*   script/        this pipeline (do-files)
*
* Single-file version of 00_master.do + 01..05 (same results).
* Run:  do "<project root>/script/stress_test_full.do"
*******************************************************************************

clear all
set more off
version 17

*----------------------------------------------------------------------------
* 1. Paths  (edit $root if the project folder moves)
*----------------------------------------------------------------------------
global root   "C:/Users/LENOVO05/github/banking-stress-test"
global input  "$root/input"
global inter  "$root/intermediate"
global output "$root/output"
global code   "$root/script"

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


*******************************************************************************
*******************************************************************************
*****  PART: 01_import.do
*******************************************************************************
*******************************************************************************

*******************************************************************************
* 01_import.do — raw Excel inputs -> intermediate datasets
*   intermediate/parameters.dta   model parameters (also set as globals $P_*)
*   intermediate/macro.dta        long: scen x quarter (history + scenario path)
*   intermediate/bank_raw.dta     bank-quarter panel from Bloomberg BQL
*******************************************************************************

*----------------------------------------------------------------------------
* 1. Parameters sheet -> globals $P_<name>
*----------------------------------------------------------------------------
import excel "$macro_xlsx", sheet("Parameters") firstrow case(lower) clear
keep parameter value description
drop if missing(parameter)
destring value, replace
forval i = 1/`=_N' {
    global P_`=parameter[`i']' = value[`i']
}
foreach p in tax_rate payout D_sbn w_srbi k_stress {
    if "${P_`p'}" == "" {
        di as err "Parameter `p' missing from the Parameters sheet"
        exit 198
    }
}
save "$inter/parameters.dta", replace

*----------------------------------------------------------------------------
* 2. Macro history + 3 scenario paths, stacked long by scenario
*    d_price is the QoQ % bond price change (= -D x change in SBN 10Y yield)
*----------------------------------------------------------------------------
local mvars gdp reporate cpi forex d_property d_price sbn10y ust10y

import excel "$macro_xlsx", sheet("Macro") firstrow case(lower) clear
keep quarter `mvars'
drop if missing(quarter)
format quarter %tq
summarize quarter, meanonly
global base_q = r(max)                      // last actual quarter
tempfile hist
save `hist'

tempfile stack
forval s = 1/3 {
    import excel "$macro_xlsx", sheet("Scenario `s'") firstrow case(lower) clear
    keep quarter `mvars'
    drop if missing(quarter)
    assert quarter > $base_q
    append using `hist'
    gen byte scen = `s'
    if `s' > 1 append using `stack'
    save `stack', replace
}
sort scen quarter
isid scen quarter
format quarter %tq
label define scen 1 "Baseline" 2 "Adverse 1" 3 "Adverse 2"
label values scen scen

* scenario sheets must cover the requested horizon
qui count if scen == 1 & quarter > $base_q
if r(N) < $horizon {
    di as err "Scenario sheets hold only " r(N) " quarters; horizon is $horizon"
    exit 198
}
drop if quarter > $base_q + $horizon

gen byte covid = inrange(quarter, tq($covid_start), tq($covid_end))
la var gdp        "Real GDP growth, YoY (%)"
la var reporate   "BI policy rate (%)"
la var d_property "Residential property price index, QoQ (%)"
la var d_price    "Bond price change, QoQ (%)"
la var covid      "Loan-restructuring forbearance period"
save "$inter/macro.dta", replace

*----------------------------------------------------------------------------
* 3. Bank-level BQL data
*    Column names come from the BQL item labels: keep the text before "(".
*----------------------------------------------------------------------------
import excel "$bank_xlsx", sheet("$bank_sheet") firstrow case(lower) clear
foreach v of varlist _all {
    if "`v'" == "id" continue
    local lab : variable label `v'
    local p = strpos(`"`lab'"', "(")
    if `p' <= 1 {
        drop `v'                            // empty spill-over columns
        continue
    }
    local new = lower(substr(`"`lab'"', 1, `p' - 1))
    capture confirm new variable `new'      // "new": no abbreviation matching
    if !_rc rename `v' `new'
    else    drop `v'                        // duplicate query of the same item
}
drop if missing(id) | missing(bs_sh_out)
rename bs_sh_out dates                      // PERIOD_END_DATE placeholder
gen quarter = qofd(dates)
format quarter %tq
gen bank = substr(id, 1, 4)

* fill=prev repeats the last statement when a period is unreported: keep first
bysort bank quarter: keep if _n == 1

merge m:1 bank using "$input/kbmi.dta", keep(match) keepusing(kbmi) nogen
foreach t of global exclude {
    drop if bank == "`t'"
}
la var kbmi "KBMI group (capital-based bank class)"
save "$inter/bank_raw.dta", replace


*******************************************************************************
*******************************************************************************
*****  PART: 02_prepare.do
*******************************************************************************
*******************************************************************************

*******************************************************************************
* 02_prepare.do — bank panel cleaning and financial ratios
*   intermediate/bank_panel.dta   balanced bank-quarter panel + macro + ratios
*
* Units: stocks and flows in IDR million; flows are quarterly (FA_PERIOD_TYPE=Q).
* Ratios in %, quarterly flows NOT annualised unless the name ends in _ann.
*******************************************************************************

use "$inter/bank_raw.dta", clear

rename (bs_tot_asset bs_tot_loan bs_non_perform_loans bs_customer_deposits    ///
        bs_risk_weighted_assets bs_tier1_capital bs_tot_cap_fund              ///
        is_int_inc is_prov_for_loan_loss non_int_inc non_int_exp net_int_inc  ///
        net_income trading_secs_fa_at_fv_thru_pl av_sa_fa_at_fv_thru_ot_comp_inc) ///
       (asset loan npl_amt dep rwa tier1 cap int_inc prov nonii nonie nii     ///
        ni fvtpl fvoci)

encode bank, gen(bank_id)
xtset bank_id quarter
tsfill, full                                 // gaps left by de-duplication
bysort bank_id (bank): replace bank = bank[_N]
bysort bank_id (kbmi): replace kbmi = kbmi[1]

* macro history (identical across scenarios: take the baseline copy)
preserve
use "$inter/macro.dta" if scen == 1 & quarter <= $base_q, clear
keep quarter gdp reporate d_property d_price covid
tempfile hist
save `hist'
restore
merge m:1 quarter using `hist', keep(master match) nogen
xtset bank_id quarter

*----------------------------------------------------------------------------
* Ratios
*----------------------------------------------------------------------------
gen npl_r  = npl_amt / loan * 100
gen prov_r = prov / loan * 100               // quarterly provision charge, % loans
gen nim    = nii / asset * 100               // quarterly, % assets
gen nonii_r = nonii / asset * 100
gen nonie_r = nonie / asset * 100
gen car    = cap / rwa * 100
gen t1r    = tier1 / rwa * 100
gen roa_ann = ni / asset * 400

* NPL ratio in logit space keeps forecasts inside (0,100%)
gen npl_c = min(max(npl_r, 0.1), 50)
gen lnpl  = logit(npl_c / 100)

*----------------------------------------------------------------------------
* Securities exposed to mark-to-market (FVTPL + FVOCI)
* Bloomberg returns mis-scaled values for some small banks (> total assets):
* replace those with the KBMI median share and flag them.
*----------------------------------------------------------------------------
replace fvtpl = 0 if missing(fvtpl) & !missing(fvoci)
replace fvoci = 0 if missing(fvoci) & !missing(fvtpl)
gen sec_amt = fvtpl + fvoci
gen sec_sh  = sec_amt / asset * 100
gen byte sec_flag = sec_sh > 100 & !missing(sec_sh)
replace sec_sh = . if sec_flag
bysort kbmi quarter: egen sec_med = median(sec_sh)
replace sec_sh = sec_med if missing(sec_sh)
replace sec_sh = 0 if missing(sec_sh)
gen fvtpl_sh = cond(sec_amt > 0 & !sec_flag, fvtpl / sec_amt, 0.5)
drop sec_med
xtset bank_id quarter                        // restore panel sort order
la var sec_sh   "MTM securities (FVTPL+FVOCI), % assets"
la var fvtpl_sh "FVTPL share of MTM securities"
la var sec_flag "Securities value mis-scaled in source; KBMI median used"

*----------------------------------------------------------------------------
* Trailing 4-quarter averages: starting point for flow items (removes
* seasonality and one-offs in the last reported quarter)
*----------------------------------------------------------------------------
foreach v in nim nonii_r nonie_r prov_r {
    gen `v'_4q = (`v' + L.`v' + L2.`v' + L3.`v') / 4
    replace `v'_4q = `v' if missing(`v'_4q)
}

gen year = yofd(dofq(quarter))
la var npl_r   "NPL ratio (%)"
la var prov_r  "Provision charge, % loans (quarterly)"
la var nim     "Net interest income, % assets (quarterly)"
la var car     "Capital adequacy ratio (%)"
la var t1r     "Tier 1 capital ratio (%)"
la var lnpl    "logit(NPL ratio)"
order bank bank_id kbmi quarter year
compress
save "$inter/bank_panel.dta", replace


*******************************************************************************
*******************************************************************************
*****  PART: 03_satellite.do
*******************************************************************************
*******************************************************************************

*******************************************************************************
* 03_satellite.do — credit-risk satellite models
*
* NPL (dynamic, logit, bank FE, asset-weighted):
*   logit(NPL)_it = a_i + rho*logit(NPL)_i,t-1 + bg*gdp4_t + br*rep4_t
*                   + bp*prp4_t + bc*covid_t + e_it
*   gdp4/rep4/prp4 = average of lags 1-4 of GDP growth, BI rate, property prices.
*
* Provision charge (% loans, quarterly, bank FE, asset-weighted):
*   prov_it = c_i + g1*NPL_it + g2*dNPL_it + gc*covid_t + u_it
*
* Design choices vs the handbook specification (12 separate lags, unweighted):
*   - handbook spec explains ~2% of within-bank NPL variation; the dynamic
*     logit explains ~90% and every macro sign is economically correct
*   - asset weights: the policy object is the industry, dominated by KBMI 3-4
*   - observations with |dlogit NPL| > 1 are reporting breaks (small banks),
*     excluded from estimation
*   - covid dummy absorbs the 2020-22 OJK restructuring forbearance
*   - forecasts are anchored with a bank-specific intercept correction
*     (mean residual of the last 4 quarters) so paths start at the actual level
*
* Outputs: intermediate/sat_coefs.dta, intermediate/bank_anchor.dta,
*          intermediate/backtest.dta, output/tables/satellite_models.xlsx
*******************************************************************************

use "$inter/bank_panel.dta", clear
xtset bank_id quarter

replace lnpl = . if npl_amt <= 0
gen byte brk = abs(D.lnpl) > 1 & !missing(D.lnpl)
gen npl_m = npl_r if !brk & !missing(lnpl)  // NPL ratio cleaned of breaks

gen gdp4 = (L.gdp + L2.gdp + L3.gdp + L4.gdp) / 4
gen rep4 = (L.reporate + L2.reporate + L3.reporate + L4.reporate) / 4
gen prp4 = (L.d_property + L2.d_property + L3.d_property + L4.d_property) / 4
gen w    = L.asset

gen byte est = quarter >= tq($est_start) & quarter <= $base_q
_pctile prov_r if est, p(1 99)
gen prov_w = min(max(prov_r, r(r1)), r(r2)) if !missing(prov_r)

*----------------------------------------------------------------------------
* 1. Estimation
*----------------------------------------------------------------------------
areg lnpl L.lnpl gdp4 rep4 prp4 covid [aw=w] if est & !brk & !L.brk,          ///
     absorb(bank_id) vce(cluster bank_id)
estimates store npl
estimates save "$inter/est_npl", replace
foreach v in gdp4 rep4 prp4 covid {
    scalar b_`v' = _b[`v']
}
scalar rho = _b[L.lnpl]
local npl_n = e(N)
local npl_r2 = e(r2)

areg prov_w npl_m D.npl_m covid [aw=w] if est,                                 ///
     absorb(bank_id) vce(cluster bank_id)
estimates store prov
estimates save "$inter/est_prov", replace
scalar g1 = _b[npl_m]
scalar g2 = _b[D.npl_m]
scalar gc = _b[covid]

* coefficient table
foreach m in npl prov {
    estimates restore `m'
    quietly areg                             // replay to post r(table)
    matrix `m'_b = r(table)
}
preserve
    clear
    local rows "npl:L.lnpl npl:gdp4 npl:rep4 npl:prp4 npl:covid prov:npl_m prov:D.npl_m prov:covid"
    local n : word count `rows'
    set obs `n'
    gen str12 model = ""
    gen str14 regressor = ""
    gen coef = .
    gen se = .
    gen pvalue = .
    forval i = 1/`n' {
        local r : word `i' of `rows'
        gettoken m v : r, parse(":")
        local v = substr("`v'", 2, .)
        replace model = cond("`m'" == "npl", "logit NPL", "Provision") in `i'
        replace regressor = "`v'" in `i'
        local c = colnumb(`m'_b, "`v'")
        replace coef   = `m'_b[1, `c'] in `i'
        replace se     = `m'_b[2, `c'] in `i'
        replace pvalue = `m'_b[4, `c'] in `i'
    }
    export excel using "$output/tables/satellite_models.xlsx",                ///
           sheet("Coefficients", replace) firstrow(variables)
    save "$inter/sat_coefs.dta", replace
restore

*----------------------------------------------------------------------------
* 2. Bank anchors: intercept correction from the last 4 quarters
*    c_npl  = mean[ lnpl - rho*L.lnpl - Xb ]           (covid term = 0 ahead)
*    c_prov = mean[ prov_w - g1*NPL - g2*dNPL ]
*----------------------------------------------------------------------------
gen r_npl  = lnpl - rho*L.lnpl - b_gdp4*gdp4 - b_rep4*rep4 - b_prp4*prp4      ///
             - b_covid*covid if !brk
gen r_prov = prov_w - g1*npl_m - g2*D.npl_m - gc*covid

foreach r in npl prov {
    bysort bank_id (quarter): egen c_`r' = mean(r_`r')                         ///
        if quarter > $base_q - 4 & quarter <= $base_q
    bysort bank_id (c_`r'): replace c_`r' = c_`r'[1]
    bysort bank_id: egen c_`r'_all = mean(r_`r') if est
    bysort bank_id (c_`r'_all): replace c_`r'_all = c_`r'_all[1]
    replace c_`r' = c_`r'_all if missing(c_`r')    // no clean recent quarter
}
preserve
    keep if quarter == $base_q
    keep bank_id c_npl c_prov
    save "$inter/bank_anchor.dta", replace
restore

*----------------------------------------------------------------------------
* 3. Out-of-sample back-test of the NPL model
*    Re-estimate up to origin = base - 8, forecast 8 quarters with ACTUAL
*    macro, compare loan-weighted industry NPL with the outturn.
*----------------------------------------------------------------------------
local origin = $base_q - 8
xtset bank_id quarter
areg lnpl L.lnpl gdp4 rep4 prp4 covid [aw=w]                                    ///
     if quarter >= tq($est_start) & quarter <= `origin' & !brk & !L.brk,       ///
     absorb(bank_id) vce(cluster bank_id)
local bt_rho = _b[L.lnpl]
gen bt_r = lnpl - `bt_rho'*L.lnpl - _b[gdp4]*gdp4 - _b[rep4]*rep4             ///
           - _b[prp4]*prp4 - _b[covid]*covid if !brk
bysort bank_id: egen bt_c = mean(bt_r) if inrange(quarter, `origin' - 3, `origin')
bysort bank_id (bt_c): replace bt_c = bt_c[1]
xtset bank_id quarter
gen bt_lnpl = lnpl if quarter == `origin'
forval t = `=`origin' + 1'/$base_q {
    replace bt_lnpl = bt_c + `bt_rho'*L.bt_lnpl + _b[gdp4]*gdp4                ///
        + _b[rep4]*rep4 + _b[prp4]*prp4 + _b[covid]*covid if quarter == `t'
}
gen bt_npl_amt = invlogit(bt_lnpl) * loan
keep if quarter >= `origin' - 8
gen act_amt = npl_amt if !missing(bt_npl_amt) | quarter <= `origin'
gen loan_bt = loan if !missing(bt_npl_amt) | quarter <= `origin'
collapse (sum) act_amt bt_npl_amt loan_bt, by(quarter)
gen npl_actual   = act_amt / loan_bt * 100
gen npl_forecast = bt_npl_amt / loan_bt * 100 if quarter >= `origin'
keep quarter npl_actual npl_forecast
format quarter %tq
gen origin = `origin'
save "$inter/backtest.dta", replace
export excel using "$output/tables/satellite_models.xlsx",                    ///
       sheet("NPL_backtest", replace) firstrow(variables)

* parameters handed to the projection
global b_rho = rho
foreach v in gdp4 rep4 prp4 {
    global b_`v' = b_`v'
}
global g1 = g1
global g2 = g2
di as res "NPL model: N=`npl_n'  R2=" %5.3f `npl_r2' "  rho=" %5.3f rho


*******************************************************************************
*******************************************************************************
*****  PART: 04_projection.do
*******************************************************************************
*******************************************************************************

*******************************************************************************
* 04_projection.do — scenario projection of P&L and capital, bank by bank
*   intermediate/projection.dta   bank x scenario x quarter (base .. base+H)
*
* Each forecast quarter t (balance sheet grows with the scenario):
*   growth      g      = (1 + GDP yoy/100)^(1/4) - 1   assets, loans, deposits,
*                                                     RWA, securities
*   NPL         logit  = c_npl + rho*L.logit + b'X    -> NPL ratio, NPL stock
*   provisions  prov   = max(0, c_prov + g1*NPL + g2*dNPL) % loans
*               + overlay = k_stress * max(0, GDP_base - GDP_s) * NPL stock
*   NII                = NIM(4q avg)*assets
*                        + (beta_loan*loans - beta_dep*deposits)*d(BI rate)/400
*   MTM loss           = -d_price/100 * securities * (1 - w_srbi)
*                        FVTPL share -> P&L, FVOCI share -> OCI (capital)
*   EBT = NII + non-int income - non-int expense - provisions - FVTPL loss
*   EAT = EBT - tax_rate * max(EBT, 0);  dividends = payout * max(EAT, 0)
*   capital_t = capital_t-1 + EAT - dividends - OCI loss   (Tier 1 and total)
*******************************************************************************

*----------------------------------------------------------------------------
* 1. Scenario macro with 4-quarter lag averages, plus baseline GDP for the gap
*----------------------------------------------------------------------------
use "$inter/macro.dta", clear
xtset scen quarter
gen gdp4 = (L.gdp + L2.gdp + L3.gdp + L4.gdp) / 4
gen rep4 = (L.reporate + L2.reporate + L3.reporate + L4.reporate) / 4
gen prp4 = (L.d_property + L2.d_property + L3.d_property + L4.d_property) / 4
gen repo_base = reporate if quarter == $base_q
bysort scen (repo_base): replace repo_base = repo_base[1]
preserve
    keep if scen == 1
    keep quarter gdp
    rename gdp gdp_bl
    tempfile bl
    save `bl'
restore
merge m:1 quarter using `bl', nogen
keep if quarter >= $base_q
keep scen quarter gdp reporate d_price gdp4 rep4 prp4 gdp_bl repo_base
tempfile mac
save `mac'

*----------------------------------------------------------------------------
* 2. Starting balance sheet (base quarter) x scenario x horizon
*----------------------------------------------------------------------------
use "$inter/bank_panel.dta" if quarter == $base_q, clear
merge 1:1 bank_id using "$inter/bank_anchor.dta", nogen
keep bank bank_id kbmi quarter asset loan dep rwa tier1 cap sec_amt sec_sh     ///
     fvtpl_sh sec_flag npl_r lnpl nim_4q nonii_r_4q nonie_r_4q c_npl c_prov   ///
     ni prov                                 // actual base-quarter flows

* securities: use the cleaned share where the raw amount was mis-scaled
replace sec_amt = sec_sh / 100 * asset if sec_flag | missing(sec_amt)

* banks lacking a usable starting point are dropped (and reported)
gen byte ok = !missing(asset, loan, dep, rwa, tier1, cap, lnpl, nim_4q, c_npl, c_prov)
qui levelsof bank if !ok, clean local(dropped)
global dropped "`dropped'"
if "`dropped'" != "" di as txt "No usable base data, excluded: `dropped'"
keep if ok
drop ok

expand 3
bysort bank_id: gen byte scen = _n
expand $horizon + 1
bysort bank_id scen: replace quarter = $base_q + _n - 1
merge m:1 scen quarter using `mac', keep(match) nogen

gen pid = bank_id * 10 + scen
xtset pid quarter
gen byte h = quarter - $base_q

* forecast-quarter variables start empty
foreach v in asset loan dep rwa sec_amt tier1 cap lnpl {
    replace `v' = . if h > 0
}
foreach v in npl_r npl_amt prov prov_r overlay nii nonii nonie mtm fvtpl_loss ///
             oci_loss ebt tax eat div {
    cap gen double `v' = .
    replace `v' = . if h > 0
}
replace npl_amt = npl_r / 100 * loan if h == 0
replace eat     = ni if h == 0
foreach v in overlay mtm fvtpl_loss oci_loss {
    replace `v' = 0 if h == 0
}
drop ni

*----------------------------------------------------------------------------
* 3. Recursion over forecast quarters
*----------------------------------------------------------------------------
local tax = $P_tax_rate
local pay = $P_payout
local w   = $P_w_srbi
local k   = $P_k_stress * $use_overlay

forval t = `=$base_q + 1'/`=$base_q + $horizon' {
    local q "quarter == `t'"
    gen double _g = (1 + gdp/100)^0.25 - 1 if `q'
    foreach v in asset loan dep rwa sec_amt {
        replace `v' = L.`v' * (1 + _g) if `q'
    }
    drop _g

    * credit risk
    replace lnpl    = c_npl + $b_rho*L.lnpl + $b_gdp4*gdp4 + $b_rep4*rep4     ///
                      + $b_prp4*prp4 if `q'
    replace npl_r   = 100 * invlogit(lnpl) if `q'
    replace npl_amt = npl_r / 100 * loan if `q'
    replace prov_r  = max(0, c_prov + $g1*npl_r + $g2*(npl_r - L.npl_r)) if `q'
    replace overlay = `k' * max(0, gdp_bl - gdp) * npl_amt if `q'
    replace prov    = prov_r / 100 * loan + overlay if `q'

    * market risk on MTM securities held at the start of the quarter
    replace mtm        = -d_price / 100 * L.sec_amt * (1 - `w') if `q'
    replace fvtpl_loss = fvtpl_sh * mtm if `q'
    replace oci_loss   = (1 - fvtpl_sh) * mtm if `q'

    * income statement
    replace nii   = nim_4q / 100 * asset                                       ///
                    + ($beta_loan*loan - $beta_dep*dep) * (reporate - repo_base) / 400 if `q'
    replace nonii = nonii_r_4q / 100 * asset if `q'
    replace nonie = nonie_r_4q / 100 * asset if `q'
    replace ebt   = nii + nonii - nonie - prov - fvtpl_loss if `q'
    replace tax   = `tax' * max(ebt, 0) if `q'
    replace eat   = ebt - tax if `q'
    replace div   = `pay' * max(eat, 0) if `q'

    * capital
    replace tier1 = L.tier1 + eat - div - oci_loss if `q'
    replace cap   = L.cap   + eat - div - oci_loss if `q'
}

gen car  = cap / rwa * 100
gen t1r  = tier1 / rwa * 100
gen credit_loss = prov
gen roa_ann = eat / asset * 400
gen byte fail = car < $car_min if h > 0

label define scen 1 "Baseline" 2 "Adverse 1" 3 "Adverse 2", replace
label values scen scen
la var car     "CAR (%)"
la var t1r     "Tier 1 ratio (%)"
la var npl_r   "NPL ratio (%)"
la var overlay "Stress provision overlay (IDR mn)"
la var mtm     "MTM securities loss, + = loss (IDR mn)"
la var fail    "CAR below minimum"
order bank bank_id kbmi scen quarter h
sort bank_id scen quarter
compress
save "$inter/projection.dta", replace


*******************************************************************************
*******************************************************************************
*****  PART: 05_results.do
*******************************************************************************
*******************************************************************************

*******************************************************************************
* 05_results.do — tables and figures
*   output/tables/stress_test_results.xlsx
*     Summary, Industry_path, KBMI_path, Bank, Failed_banks, Assumptions
*   output/figures/ (PNG charts)
*******************************************************************************

local xlsx "$output/tables/stress_test_results.xlsx"
cap erase "`xlsx'"
local fig  "$output/figures"
local bq   = $base_q
local col1 "navy"
local col2 "orange"
local col3 "maroon"
local xl   "xline(`bq', lcolor(gs10) lpattern(dash))"
local leg  `"legend(order(1 "Baseline" 2 "Adverse 1" 3 "Adverse 2") rows(1) pos(6))"'
local gopt "graphregion(color(white)) plotregion(color(white)) ylabel(, angle(0) format(%4.1f))"

* sums of levels / flows -> ratios (same formulas at every aggregation level)
capture program drop _ratios
program define _ratios
    gen car     = cap / rwa * 100
    gen t1r     = tier1 / rwa * 100
    gen npl_r   = npl_amt / loan * 100
    gen roa_ann = eat / asset * 400
    gen credit_a = prov / asset * 100
    gen market_a = (fvtpl_loss + oci_loss) / asset * 100
end
local sums cap tier1 rwa npl_amt loan eat asset prov fvtpl_loss oci_loss overlay

*----------------------------------------------------------------------------
* 1. Industry path (history from 2022 for the same banks + projection)
*----------------------------------------------------------------------------
use "$inter/projection.dta", clear
qui levelsof bank_id, local(banks)
collapse (sum) `sums' (count) banks = bank_id, by(scen quarter)
_ratios
tempfile ind
save `ind'

use "$inter/bank_panel.dta" if quarter >= tq(2022q1) & quarter < `bq', clear
gen keepb = 0
foreach b of local banks {
    replace keepb = 1 if bank_id == `b'
}
keep if keepb
rename ni eat
gen fvtpl_loss = 0
gen oci_loss = 0
gen overlay = 0
collapse (sum) `sums' (count) banks = bank_id, by(quarter)
_ratios
replace credit_a = .
replace market_a = .
expand 3
bysort quarter: gen byte scen = _n
append using `ind'
sort scen quarter
label define scen 1 "Baseline" 2 "Adverse 1" 3 "Adverse 2", replace
label values scen scen
format quarter %tq
save "$inter/industry_path.dta", replace

preserve
    keep if quarter >= `bq'
    keep scen quarter banks car t1r npl_r roa_ann credit_a market_a
    export excel using "`xlsx'", sheet("Industry_path", replace) firstrow(variables)
restore

* figures: industry ratios
foreach v in car t1r npl_r roa_ann {
    if "`v'" == "car"     local yt "CAR (% of RWA)"
    if "`v'" == "t1r"     local yt "Tier 1 capital (% of RWA)"
    if "`v'" == "npl_r"   local yt "NPL ratio (% of loans)"
    if "`v'" == "roa_ann" local yt "Net income (% of assets, annualised)"
    twoway (line `v' quarter if scen == 1, lcolor(`col1') lwidth(medthick))   ///
           (line `v' quarter if scen == 2, lcolor(`col2') lwidth(medthick))   ///
           (line `v' quarter if scen == 3, lcolor(`col3') lwidth(medthick)),  ///
           `xl' `leg' `gopt' ytitle("`yt'") xtitle("")                          ///
           title("Industry: `yt'", size(medium))
    graph export "`fig'/industry_`v'.png", replace width(1600)
}

* figure: cumulative loss composition over the horizon (% of assets)
preserve
    keep if quarter > `bq'
    graph bar (sum) credit_a market_a, over(scen) stack                        ///
          bar(1, color(`col1')) bar(2, color(`col3'))                          ///
          legend(order(1 "Credit losses (provisions)" 2 "Market losses (MTM)") rows(1) pos(6)) ///
          ytitle("Cumulative, % of total assets") `gopt'                       ///
          title("Credit and market losses over the stress horizon", size(medium))
    graph export "`fig'/loss_composition.png", replace width(1600)
restore

*----------------------------------------------------------------------------
* 2. Summary by scenario
*----------------------------------------------------------------------------
use "$inter/projection.dta", clear
gen cap0  = cap if h == 0
gen asset0 = asset if h == 0
bysort pid (cap0): replace cap0 = cap0[1]
bysort pid (asset0): replace asset0 = asset0[1]
bysort pid: egen fail_any = max(fail)
tempfile proj
save `proj'

keep if h > 0
collapse (sum) prov overlay mtm eat (first) cap0, by(bank_id scen)
collapse (sum) prov overlay mtm eat cap0, by(scen)
gen credit_loss_cap = prov / cap0 * 100
gen overlay_cap     = overlay / cap0 * 100
gen market_loss_cap = mtm / cap0 * 100
gen net_income_cap  = eat / cap0 * 100
gen credit_share    = prov / (prov + max(mtm, 0)) * 100
keep scen *_cap credit_share
tempfile cum
save `cum'

use "$inter/industry_path.dta" if quarter >= `bq', clear
bysort scen (quarter): gen car_start = car[1]
bysort scen (quarter): gen car_end   = car[_N]
bysort scen: egen car_min = min(car)
bysort scen (quarter): gen t1_start  = t1r[1]
bysort scen (quarter): gen t1_end    = t1r[_N]
bysort scen (quarter): gen npl_start = npl_r[1]
bysort scen (quarter): gen npl_end   = npl_r[_N]
bysort scen: keep if _n == 1
keep scen car_start car_end car_min t1_start t1_end npl_start npl_end
merge 1:1 scen using `cum', nogen
preserve
    use `proj' if h == $horizon, clear
    gen fail_asset = asset * fail_any
    collapse (sum) banks_fail = fail_any fail_asset asset (count) banks = bank_id, by(scen)
    gen fail_asset_sh = fail_asset / asset * 100
    keep scen banks banks_fail fail_asset_sh
    tempfile f
    save `f'
restore
merge 1:1 scen using `f', nogen
gen base_quarter = string(`bq', "%tq")
gen end_quarter  = string(`bq' + $horizon, "%tq")
decode scen, gen(scenario)
order scenario
drop scen
export excel using "`xlsx'", sheet("Summary", replace) firstrow(variables)
list scenario car_start car_end car_min npl_end credit_loss_cap market_loss_cap ///
     net_income_cap banks_fail, clean noobs abbrev(14)

*----------------------------------------------------------------------------
* 3. KBMI paths + figure
*----------------------------------------------------------------------------
use "$inter/projection.dta", clear
collapse (sum) `sums', by(kbmi scen quarter)
_ratios
keep kbmi scen quarter car t1r npl_r roa_ann credit_a market_a
export excel using "`xlsx'", sheet("KBMI_path", replace) firstrow(variables)
forval b = 1/4 {
    twoway (line car quarter if scen == 1 & kbmi == `b', lcolor(`col1') lwidth(medthick)) ///
           (line car quarter if scen == 2 & kbmi == `b', lcolor(`col2') lwidth(medthick)) ///
           (line car quarter if scen == 3 & kbmi == `b', lcolor(`col3') lwidth(medthick)), ///
           `leg' `gopt' ytitle("CAR (%)") xtitle("") title("KBMI `b'", size(medium)) ///
           name(k`b', replace) nodraw
}
graph combine k1 k2 k3 k4, rows(2) graphregion(color(white))
graph export "`fig'/car_kbmi.png", replace width(1800)

*----------------------------------------------------------------------------
* 4. Bank table, failed banks, bank-level figure
*----------------------------------------------------------------------------
use `proj', clear
gen credit_cap = .
gen market_cap = .
bysort pid: egen cum_prov = total(prov * (h > 0))
bysort pid: egen cum_mtm  = total(mtm * (h > 0))
replace credit_cap = cum_prov / cap0 * 100
replace market_cap = cum_mtm / cap0 * 100
bysort pid: egen car_min = min(car)
gen car_start = car if h == 0
bysort pid (car_start): replace car_start = car_start[1]
keep if h == $horizon
keep bank kbmi scen car_start car npl_r car_min credit_cap market_cap fail_any sec_flag
rename (car npl_r) (car_end npl_end)
reshape wide car_end npl_end car_min credit_cap market_cap fail_any, i(bank) j(scen)
sort car_end3
order bank kbmi car_start car_end1 car_end2 car_end3 car_min3 npl_end1 npl_end2 npl_end3
export excel using "`xlsx'", sheet("Bank", replace) firstrow(variables)

preserve
    keep if fail_any1 | fail_any2 | fail_any3
    keep bank kbmi car_start car_end1 car_end2 car_end3 car_min3 credit_cap3 market_cap3
    if _N == 0 {
        set obs 1
        replace bank = "none"
    }
    export excel using "`xlsx'", sheet("Failed_banks", replace) firstrow(variables)
    list, clean noobs
restore

twoway (scatter car_end3 car_start if car_end3 >= $car_min, mcolor(`col1'%70) msize(small)) ///
       (scatter car_end3 car_start if car_end3 <  $car_min, mcolor(`col3') msize(medium) ///
            mlabel(bank) mlabcolor(`col3') mlabsize(vsmall))                   ///
       (function y = x, range(5 95) lcolor(gs10) lpattern(dot)),               ///
       yline($car_min, lcolor(`col3') lpattern(dash))                          ///
       legend(order(1 "Pass" 2 "CAR < $car_min%") rows(1) pos(6)) `gopt'       ///
       xtitle("CAR `=string(`bq', "%tq")' (%)") ytitle("CAR end of Adverse 2 (%)") ///
       title("Bank CAR: start vs end of Adverse 2", size(medium))
graph export "`fig'/bank_car_adverse2.png", replace width(1600)

*----------------------------------------------------------------------------
* 5. NPL back-test and macro scenario figures
*----------------------------------------------------------------------------
use "$inter/backtest.dta", clear
local o = origin[1]
twoway (line npl_actual quarter, lcolor(black) lwidth(medthick))              ///
       (line npl_forecast quarter, lcolor(`col3') lpattern(dash) lwidth(medthick)), ///
       xline(`o', lcolor(gs10) lpattern(dash)) `gopt'                          ///
       legend(order(1 "Actual" 2 "Model forecast (actual macro)") rows(1) pos(6)) ///
       ytitle("Industry NPL ratio (%)") xtitle("")                             ///
       title("Out-of-sample NPL back-test", size(medium))
graph export "`fig'/npl_backtest.png", replace width(1600)

use "$inter/macro.dta" if quarter >= tq(2023q1), clear
foreach v in gdp reporate d_property d_price {
    local t : variable label `v'
    twoway (line `v' quarter if scen == 1, lcolor(`col1') lwidth(medthick))   ///
           (line `v' quarter if scen == 2, lcolor(`col2') lwidth(medthick))   ///
           (line `v' quarter if scen == 3, lcolor(`col3') lwidth(medthick)),  ///
           `xl' `leg' `gopt' ytitle("") xtitle("") title("`t'", size(medsmall)) ///
           name(m_`v', replace) nodraw
}
graph combine m_gdp m_reporate m_d_property m_d_price, rows(2) graphregion(color(white))
graph export "`fig'/macro_scenarios.png", replace width(1800)

*----------------------------------------------------------------------------
* 6. Assumptions sheet
*----------------------------------------------------------------------------
tempname pf
tempfile asm
postfile `pf' str24 parameter str40 value using `asm'
post `pf' ("base_quarter")      ("`=string(`bq', "%tq")'")
post `pf' ("horizon_quarters")  ("$horizon")
post `pf' ("tax_rate")          ("$P_tax_rate")
post `pf' ("payout")            ("$P_payout")
post `pf' ("k_stress")          ("$P_k_stress")
post `pf' ("use_overlay")       ("$use_overlay")
post `pf' ("w_srbi")            ("$P_w_srbi")
post `pf' ("beta_loan")         ("$beta_loan")
post `pf' ("beta_dep")          ("$beta_dep")
post `pf' ("car_min")           ("$car_min")
post `pf' ("est_start")         ("$est_start")
post `pf' ("excluded_banks")    ("$exclude")
post `pf' ("covid_window")      ("$covid_start-$covid_end")
post `pf' ("npl_rho")           ("$b_rho")
post `pf' ("npl_gdp4")          ("$b_gdp4")
post `pf' ("npl_rep4")          ("$b_rep4")
post `pf' ("npl_prp4")          ("$b_prp4")
post `pf' ("prov_npl")          ("$g1")
post `pf' ("prov_dnpl")         ("$g2")
postclose `pf'
use `asm', clear
export excel using "`xlsx'", sheet("Assumptions", replace) firstrow(variables)


log close main
