/*==============================================================================
	BANKING SOLVENCY STRESS TEST
	------------------------------------------------------------------------------
	Purpose
	  Project bank-level NPL, loan-loss provisions, securities mark-to-market
	  (MTM) losses, profit and capital (CAR / Tier 1) under three macro
	  scenarios, then summarise results at industry, KBMI and bank level.

	Scenarios
	  1 = Baseline, 2 = Adverse 1, 3 = Adverse 2

	Inputs (all in $base\Stata)
	  Solvency ST.xlsx
	    - "Parameters"   adjustable assumptions (columns: parameter, value)
	    - "Macro"        historical macro series by quarter
	    - "Scenario 1-3" forecast macro path for each scenario
	  Stress Testing Manual - Excel Template.xlsx
	    - "Output Sheet (Copy)"  bank-level balance sheet and P&L
	  kbmi.dta           bank ticker (4 letters) -> KBMI group (1-4), one row per bank

	Outputs
	  $base\Stata    macro.dta, scen#.dta, comb#.dta, bank.dta
	  $base\Result   charts (*.png, *.gph) and stress_test_summary.xlsx

	Requirements
	  Stata 17 or later (bookmarks; nested Navigator view needs Stata 19)
	  lgraph (SSC; installed automatically if missing)

	How to run
	  1. Set your project folder in section 0.1.
	  2. Review the run settings in section 0.2.
	  3. Close the Excel inputs and run the whole do-file.

	Navigation
	  Lines starting with **# are bookmarks. Open the Navigator in the
	  Do-file Editor to jump between sections (**#), subsections (**##)
	  and steps (**###).

	Sections
	  0. Settings
	  1. Raw data extraction
	  2. Forecast setup
	  3. Ratio assumptions
	  4. Scenario simulations
	  5. Diagnostic charts
	  6. Results: industry, KBMI, failed banks
	  7. Excel summary
==============================================================================*/

version 17
clear all
set more off



**# 0. SETTINGS ================================================================

**## 0.1 Project folder
* Option A: define $base before running this file (e.g. in your profile.do).
* Option B: add your Stata username and folder below.
* Use forward slashes. Do not put "//" comments at the end of "global" lines.

**## 0.1 Project folder
* Add your Stata username and project folder below (forward slashes).
* Other users can instead set global base before running (e.g. in profile.do).
* Do not put "//" comments at the end of "global" lines.

if "`c(username)'" == "LENOVO05" {
	global base "C:/Users/LENOVO05/OneDrive/Desktop/20260827_0301060601_W5_Banking Stress Test Materials (1)/20260827_0301060601_W5_Banking Stress Test Materials"
}
else if "`c(username)'" == "setde" {
		 global base "C:/Users/setde/OneDrive/Documents/GitHub/banking-stress-test"
		*global base "C:/Users/setde/OneDrive/Documents/GitHub/stress_test"
}
else if "$base" == "" {
	di as error "Project folder not set for user `c(username)'."
	di as error "Set global base before running, or add your path in section 0.1."
	exit 198
}

cap cd "$base"
if _rc {
	di as error "Folder not found: $base"
	di as error "Check the path in section 0.1 (folder name, OneDrive vs local Documents)."
	exit 170
}
di as text "Project folder: $base"

cd "$base"
di as text "Project folder: $base"


**## 0.2 Run settings

* Forecast horizon, in quarters after the last actual quarter
global horizon 4

* RWA growth path in adverse scenarios:
*   scenario = RWA grows with each scenario's own nominal GDP (same as total assets)
*   baseline = RWA grows with baseline nominal GDP in every scenario
global rwa_growth "scenario"

* CAR threshold used to flag failing banks (%)
global car_min 8


**## 0.3 Folders

* Raw macro data (Solvency ST.xlsx)
global input  "$base/data/input"
* Stata datasets created by this file
global data    "$base/data/stata"
* Charts and Excel summary
global results "$base/result"

cap mkdir "$results"


**## 0.4 Packages

cap which lgraph
if _rc ssc install lgraph


**## 0.5 Load model parameters from Excel
* Each row of sheet "Parameters" becomes a global: global <parameter> = <value>
* Expected: tax_rate, payout, w_srbi, D_sbn, k_stress (see section 3.5)

cap import excel "$input/Solvency ST.xlsx", sheet("Parameters") firstrow case(lower) clear
if _rc {
	di as error "Cannot read Solvency ST.xlsx (sheet Parameters). Close the file in Excel and re-run."
	exit 603
}

forval r = 1/`=_N' {
	global `=parameter[`r']' = value[`r']
	di as text "`=parameter[`r']' = ${`=parameter[`r']'}"
}



**# 1. RAW DATA EXTRACTION =====================================================
* Convert macro history, macro scenarios and bank-level data from Excel to .dta

**## 1.1 Macroeconomic history

import excel "$input/Solvency ST.xlsx", sheet("Macro") firstrow case(lower) clear
format quarter %tq
save "$data/macro.dta", replace


**## 1.2 Macroeconomic scenarios
* One file per scenario: history followed by the scenario path.
* Where a quarter appears in both, the scenario value is kept.

forval i = 1/3 {
	* Scenario path
	import excel "$input/Solvency ST.xlsx", sheet("Scenario `i'") case(lower) firstrow clear
	save "$data/scen`i'.dta", replace

	* History + scenario, one row per quarter
	use "$data/macro.dta", clear
	append using "$data/scen`i'.dta", generate(from_scen)
	drop if missing(quarter)
	bys quarter (from_scen): keep if _n == _N
	drop from_scen
	isid quarter

	gen ln_forex = log(forex)
	save "$data/comb`i'.dta", replace
}


**## 1.3 Bank-level data

**### 1.3.1 Import and clean variable names

import excel "$input/Stress Testing Manual - Excel Template.xlsx", sheet("Output Sheet (Copy)") firstrow case(lower) clear
rename *fill* *
rename is_*_benefit* is_*_benefit


**### 1.3.2 Quarter and bank identifiers; drop duplicates

rename bs_sh_out dates
gen quarter = qofd(dates)
format quarter %tq
drop if missing(quarter)

* Bank ticker = first 4 letters of the Bloomberg ID (e.g. "BBRI IJ Equity")
cap rename a id
gen bank = substr(id, 1, 4)

* Keep the first record per bank-quarter
bys bank quarter: gen dup = cond(_N==1, 0, _n)
drop if dup > 1
isid bank quarter
drop dup


**### 1.3.3 Attach KBMI group
* Banks without a KBMI group are dropped.

merge m:1 bank using "$data/kbmi.dta"
keep if _merge == 3
drop _merge


**### 1.3.4 Panel setup and outlier exclusions

encode bank, gen(bank_id)
xtset bank_id quarter

* Placeholder row in the Excel template
drop if bank == "BANK"
* MCOR: simulated interest expense ~9x interest income (saving_r data issue),
* which produces a spurious failure
drop if bank == "MCOR"


**### 1.3.5 Balance the panel and refill identifiers

tsfill, full
decode bank_id, generate(bank2)
replace bank = bank2
drop bank2
replace id = bank + " IJ Equity" if id == ""

order bank bank_id quarter *
drop if quarter < tq(2010q1)


**### 1.3.6 Labels and save

* Replace Excel "(fill=...)" labels with the upper-case variable name
foreach v of varlist _all {
	local lab : var label `v'
	if strmatch("`lab'", "*(fill=*") {
		local newlab = strupper("`v'")
		la var `v' "`newlab'"
	}
}

la var dates   "Date"
la var bank_id "Bank ticker"

save "$data/bank.dta", replace



**# 2. FORECAST SETUP ===========================================================

use "$data/bank.dta", clear

**## 2.1 Last actual quarter and forecast horizon

* max = last actual quarter (constant across the dataset)
egen max = max(quarter)
format max %tq
label variable max "Last actual quarter"
global base_q = max[1]

tsappend, add($horizon)
replace max = l.max if missing(max)

gen year = yofd(dofq(quarter))
label variable year "Year"
xtset bank_id quarter

di as text "Last actual quarter: " %tq $base_q "; forecast horizon: $horizon quarters"


**## 2.2 Historical NPL ratio

gen npl_r = bs_non_perform_loans/bs_tot_loan*100
label variable npl_r "NPL ratio (%)"



**# 3. RATIO ASSUMPTIONS ========================================================
* Bank-level ratios estimated from history and held over the forecast

**## 3.1 Provision ratio and provision response to NPL

gen prov_r = is_prov_for_loan_loss/bs_tot_loan*100
la var prov_r "Provisions to loans (%)"

* Response of provisions to NPL increases in the same and previous quarter.
* Bank FE, all years pooled; NPL jumps larger than 5pp excluded.
gen dnpl_pos = max(d.npl_r, 0) if !missing(d.npl_r) & abs(d.npl_r) < 5 & quarter <= max
qui xtreg prov_r dnpl_pos l.dnpl_pos, fe vce(cluster bank_id)
global npl_b0 = _b[dnpl_pos]
global npl_b1 = _b[l.dnpl_pos]
di as text "Provision response to +1pp NPL: t = " %5.3f $npl_b0 ", t+1 = " %5.3f $npl_b1 ", total = " %5.3f $npl_b0+$npl_b1
drop dnpl_pos


**## 3.2 Balance sheet structure (bank averages, % of total assets)

gen c_loan_r = bs_tot_loan/bs_tot_asset*100
gen c_dep_r  = bs_customer_deposits/bs_tot_asset*100
gen c_nii_r  = non_int_inc/bs_tot_asset*100
gen c_nie_r  = non_int_exp/bs_tot_asset*100

foreach j in loan_r dep_r nii_r nie_r {
	egen `j' = mean(c_`j'), by(bank_id)
	drop c_`j'
}

la var loan_r "Loans to assets, bank mean (%)"
la var dep_r  "Deposits to assets, bank mean (%)"
la var nii_r  "Non-interest income to assets, bank mean (%)"
la var nie_r  "Non-interest expense to assets, bank mean (%)"


**## 3.3 Lending and funding rates (bank averages)

* Lending rate = interest income / loans
gen c_lending_r = is_int_inc/bs_tot_loan*100
egen lending_r  = mean(c_lending_r), by(bank_id)
label variable lending_r "Lending rate (%)"

* Funding rate = interest expense / deposits
gen c_saving_r = (is_int_inc - net_int_inc)/bs_customer_deposits*100
replace c_saving_r = 0 if c_saving_r < 0
egen saving_r = mean(c_saving_r), by(bank_id)
label variable saving_r "Funding rate (%)"

* Leave forecast quarters empty; section 4.6 fills them
foreach j in lending_r saving_r {
	replace `j' = . if quarter > max
	drop c_`j'
}


**## 3.4 Tradeable securities (FVOCI + FVTPL, % of loans)

gen afs_r = av_sa_fa_at_fv_thru_ot_comp_inc/bs_tot_loan*100
la var afs_r "FVOCI (AFS) securities to loans (%)"

gen tra_r = trading_secs_fa_at_fv_thru_pl/bs_tot_loan*100
la var tra_r "Trading securities to loans (%)"

egen sec_r = rowtotal(afs_r tra_r), missing
replace sec_r = 100 if sec_r > 100 & !missing(sec_r)
* No reported securities -> zero (otherwise the bank drops out of the forecast)
replace sec_r = 0 if missing(sec_r) & quarter <= max
la var sec_r "Tradeable securities to loans (%)"


**## 3.5 Tax rate and Excel parameters

gen tax_rate = $tax_rate
la var tax_rate "Tax rate"

/* Parameters loaded in section 0.5 (Solvency ST.xlsx, sheet Parameters):

   tax_rate  Corporate tax rate applied to positive pre-tax profit.

   payout    Dividend payout on positive profit. Losses hit capital in full.

   w_srbi    SRBI share of bank securities
             = (bank SRBI + SRBI repo) / (bank SRBI + SRBI repo + bank SBN),
             computed in Excel from BI (Ownership of SRBI) and DJPPR
             (Kepemilikan SBN). FVOCI + trading balances exceed banks' total
             SBN holdings, so they also contain SRBI. SRBI is treated as held
             to maturity (no MTM loss), so only the SBN share is revalued.

   D_sbn     Modified duration of the SBN book, priced off the SBN 10Y yield.

   k_stress  Stress provision add-on per quarter:
             k x (baseline GDP growth - scenario GDP growth, pp) x bank NPL ratio.
             Calibrated so Adverse 2 cumulative credit loss ~ 2021 peak (11.5%
             of capital). The estimated NPL/provision models alone gave ~4.8%
             (a normal year), because front-loaded PSAK 71 / COVID reserves bias
             the regressions down. Baseline gets no add-on (gap = 0).
*/

save "$data/bank.dta", replace



**# 4. SCENARIO SIMULATIONS =====================================================
* Loop over the three scenarios. Scenario variables carry the suffix _b`i'.
* Forecast quarters are those with quarter > max.

use "$data/bank.dta", clear
xtset bank_id quarter

* RWA growth rate expression (see section 0.2)
if "$rwa_growth" == "baseline" local rwa_g "(gdp_b1+cpi_b1)"
else                           local rwa_g "(gdp+cpi)"

forval i = 1/3 {

	di as text _n "---------- Scenario `i' ----------"

**## 4.1 Attach scenario macro path

	merge m:1 quarter using "$data/comb`i'.dta"
	keep if _merge == 3
	drop _merge

	foreach j in gdp reporate cpi forex d_property ln_forex d_price ust10y sbn10y {
		gen `j'_b`i' = `j'
	}
	sort bank_id quarter
	xtset bank_id quarter

	* Securities price change (%) = -(SBN share) x duration x change in SBN 10Y yield.
	* Replaces the d_price column from the Excel sheet.
	replace d_price_b`i' = -(1-$w_srbi)*$D_sbn*d.sbn10y_b`i'


**## 4.2 Balance sheet projection

**### 4.2.1 Total assets: grow with scenario nominal GDP
	* (real yoy growth + CPI inflation) / 4 = quarterly growth rate
	gen asset_b`i' = bs_tot_asset
	bys bank_id (quarter): replace asset_b`i' = asset_b`i'[_n-1] * (1+(gdp+cpi)/400) if missing(asset_b`i') & quarter > max
	label variable asset_b`i' "Total assets, scenario `i'"

**### 4.2.2 Risk-weighted assets: growth path set by $rwa_growth
	gen rwa_b`i' = bs_risk_weighted_assets
	bys bank_id (quarter): replace rwa_b`i' = rwa_b`i'[_n-1] * (1+`rwa_g'/400) if missing(rwa_b`i') & quarter > max
	label variable rwa_b`i' "RWA, scenario `i'"

**### 4.2.3 Size, loans, deposits, securities (constant shares of assets)
	gen size_b`i' = log(asset_b`i')
	label variable size_b`i' "Log total assets, scenario `i'"

	gen loan_b`i' = loan_r/100*asset_b`i'
	label variable loan_b`i' "Loans, scenario `i'"

	gen dep_b`i' = dep_r/100*asset_b`i'
	label variable dep_b`i' "Deposits, scenario `i'"

	gen sec_b`i' = sec_r
	bys bank_id (quarter): replace sec_b`i' = sec_b`i'[_n-1] if missing(sec_b`i') & quarter > max
	label variable sec_b`i' "Securities to loans (%), scenario `i'"

**### 4.2.4 Non-interest income and expense: held at last actual value
	gen nii_b`i' = non_int_inc
	replace nii_b`i' = l.nii_b`i' if missing(nii_b`i') & quarter > max

	gen nie_b`i' = non_int_exp
	replace nie_b`i' = l.nie_b`i' if missing(nie_b`i') & quarter > max


**## 4.3 NPL model and recursive forecast
	* Dynamic FE model: lagged NPL + 4 lags of GDP growth + 4 lags of BI rate.
	* House prices are excluded: IHPR never fell in-sample (min d_property +0.04),
	* so its coefficient had the wrong sign and adverse shocks lowered NPL.

**### 4.3.1 Estimate
	* Only point estimates are used in the forecast; the bootstrap affects SEs only.
	gen npl_b`i' = npl_r
	qui xtreg npl_b`i' l.npl_b`i' l(1/4).gdp l(1/4).reporate, fe vce(bootstrap, rep(10) seed(1234))

**### 4.3.2 Recursive forecast
	* Each quarter uses the previous quarter's forecast NPL. Bank fixed effects
	* (u_i) exist only in-sample, so they are carried forward explicitly.
	predict double npl_u, u
	bys bank_id: egen double npl_ui = max(npl_u)

	qui sum quarter
	forval q = `=$base_q+1'/`r(max)' {
		predict double npl_tmp, xb
		replace npl_b`i' = npl_tmp + npl_ui if quarter == `q'
		drop npl_tmp
	}
	drop npl_u npl_ui

	* Linear prediction without FE, used for the fit chart in section 5.1
	predict npl_i`i', xb
	label variable npl_b`i' "NPL ratio (%), scenario `i'"


**## 4.4 Provision forecast
	* provisions / loans = normal credit cost (bank mean of last 8 actual quarters)
	*                    + response to NPL increases this and last quarter
	*                    + stress add-on (k_stress x GDP gap vs baseline x NPL)

	gen prov_b`i' = prov_r

	* Normal credit cost; industry median for banks with no recent history
	bys bank_id: egen prov_base`i' = mean(cond(quarter > max-8 & quarter <= max, prov_r, .))
	egen prov_med`i' = median(prov_base`i')
	replace prov_base`i' = prov_med`i' if missing(prov_base`i')

	* Response to NPL increases
	replace prov_b`i' = prov_base`i' + $npl_b0*max(npl_b`i'-l.npl_b`i', 0) + $npl_b1*max(l.npl_b`i'-l2.npl_b`i', 0) if quarter > max
	replace prov_b`i' = 0 if prov_b`i' < 0 & quarter > max

	* Stress add-on
	replace prov_b`i' = prov_b`i' + $k_stress*max(gdp_b1-gdp, 0)*npl_b`i' if quarter > max
	label variable prov_b`i' "Provisions to loans (%), scenario `i'"
	drop prov_base`i' prov_med`i'


**## 4.5 Securities MTM losses
	* sec_b is securities to loans (%); convert to an amount, then apply the price change
	gen sec_amt_b`i' = sec_b`i'/100*loan_b`i'

	gen loss_b`i' = -(d_price_b`i'/100)*sec_amt_b`i'
	label variable loss_b`i' "Securities MTM loss, scenario `i'"

	gen loss_r_b`i' = loss_b`i'/loan_b`i'*100
	label variable loss_r_b`i' "Securities MTM loss to loans (%), scenario `i'"


**## 4.6 Income statement projection

**### 4.6.1 Interest rates: full pass-through of BI rate changes
	gen lending_r_b`i' = lending_r
	bys bank_id (quarter): replace lending_r_b`i' = lending_r_b`i'[_n-1] + d.reporate if missing(lending_r_b`i') & quarter > max

	gen saving_r_b`i' = saving_r
	bys bank_id (quarter): replace saving_r_b`i' = saving_r_b`i'[_n-1] + d.reporate if missing(saving_r_b`i') & quarter > max

**### 4.6.2 Interest income, expense and NIM
	gen int_inc_b`i' = lending_r_b`i'/100*loan_b`i'
	gen int_exp_b`i' = saving_r_b`i'/100*dep_b`i'
	gen nim_b`i'     = (int_inc_b`i' - int_exp_b`i')/asset_b`i'

**### 4.6.3 Profit before and after tax
	gen ebt_b`i' = int_inc_b`i' - int_exp_b`i' + nii_b`i' - nie_b`i' - (prov_b`i'/100)*loan_b`i' - loss_b`i'

	* No tax credit on losses
	gen tax_b`i' = ebt_b`i'*tax_rate
	replace tax_b`i' = 0 if tax_b`i' < 0

	gen eat_b`i' = ebt_b`i' - tax_b`i'
	label variable eat_b`i' "Net profit, scenario `i'"


**## 4.7 Capital and CAR projection

**### 4.7.1 Retained earnings (dividends paid only on positive profit)
	gen ret_b`i' = cond(eat_b`i' > 0, (1-$payout)*eat_b`i', eat_b`i') if !missing(eat_b`i')
	label variable ret_b`i' "Retained earnings, scenario `i'"

**### 4.7.2 Tier 1 and total regulatory capital
	gen tier1_b`i' = bs_tier1_capital
	replace tier1_b`i' = l.tier1_b`i' + ret_b`i' if quarter > max
	label variable tier1_b`i' "Tier 1 capital, scenario `i'"

	gen cap_b`i' = bs_tot_cap_fund
	replace cap_b`i' = l.cap_b`i' + ret_b`i' if quarter > max
	label variable cap_b`i' "Regulatory capital, scenario `i'"

**### 4.7.3 Capital ratios
	gen t1r_b`i' = tier1_b`i'/rwa_b`i'*100
	label variable t1r_b`i' "Tier 1 ratio (%), scenario `i'"

	gen car_b`i' = cap_b`i'/rwa_b`i'*100
	label variable car_b`i' "CAR (%), scenario `i'"


**## 4.8 Drop scenario macro variables before the next scenario
	drop gdp reporate cpi forex property d_property ln_forex d_price ust10y sbn10y
}

save "$data/bank.dta", replace



**# 5. DIAGNOSTIC CHARTS ========================================================
* The dashed vertical line marks the last actual quarter in all charts.

use "$data/bank.dta", clear
xtset bank_id quarter
global base_q = max[1]
global xl "xline($base_q, lcolor(maroon) lpattern(shortdash))"

**## 5.1 NPL: actual vs model prediction (in-sample fit)

replace npl_i3 = npl_r if quarter > max
rename npl_i3 npl_i
label variable npl_i "Predicted NPL (%)"

lgraph npl_r npl_i quarter if year > 2011 & year < 2023, wide ///
	ytitle("NPL (%)") xtitle("Quarter") legend(pos(6) row(1) size(small))
graph export "$results/npl_predict.png", as(png) name("Graph") replace


**## 5.2 Securities MTM losses by scenario

lgraph loss_r_b1 loss_r_b2 loss_r_b3 quarter, wide ///
	ytitle("Losses from MTM securities to loans (%)") xtitle("Quarter") ///
	legend(order(1 "Scenario 1" 2 "Scenario 2" 3 "Scenario 3") pos(6) row(1) size(small)) ///
	$xl
graph export "$results/securities.png", as(png) name("Graph") replace


**## 5.3 Loss composition: credit vs market losses over the forecast horizon

preserve
	keep if quarter > $base_q
	gen str6 qlab = string(quarter, "%tq")

	forval x = 1/3 {
		graph bar prov_b`x' loss_r_b`x', stack over(qlab) ///
			legend(order(1 "Credit losses" 2 "Market losses") pos(6) row(1) size(medium)) ///
			ytitle("Losses to total loans (%)") title("Scenario `x'")
		graph save "$results/comp_`x'.gph", replace
	}
	graph combine "$results/comp_1.gph" "$results/comp_2.gph" "$results/comp_3.gph", iscale(0.5) row(1)
	graph export "$results/composition.png", as(png) name("Graph") replace
restore

save "$data/bank.dta", replace



**# 6. RESULTS ==================================================================
* Charts from 2014 onward. Industry and KBMI ratios are aggregated
* (sum of numerators / sum of denominators).

drop if year < 2014

**## 6.1 Industry

**### 6.1.1 NPL and provisions

lgraph npl_b1 npl_b2 npl_b3 quarter, wide ///
	ytitle("Industry NPL (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) $xl
graph export "$results/npl_scenario.png", as(png) name("Graph") replace

lgraph prov_b1 prov_b2 prov_b3 quarter, wide ///
	ytitle("Industry provisions (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) $xl
graph export "$results/prov_scenario.png", as(png) name("Graph") replace


**### 6.1.2 CAR, Tier 1 ratio and net income to assets

preserve
	collapse (sum) rwa_b? tier1_b? cap_b? eat_b? asset_b?, by(quarter)

	forval i = 1/3 {
		gen car_`i' = cap_b`i'/rwa_b`i'*100
		label variable car_`i' "CAR scenario `i'"
		gen tr1_`i' = tier1_b`i'/rwa_b`i'*100
		label variable tr1_`i' "Tier 1 capital ratio scenario `i'"
		gen eat_`i' = eat_b`i'/asset_b`i'*100
		label variable eat_`i' "Net income to assets scenario `i'"
	}

	lgraph car_1 car_2 car_3 quarter, wide ///
		ytitle("CAR (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) $xl
	graph export "$results/car_scenario.png", as(png) name("Graph") replace

	lgraph tr1_1 tr1_2 tr1_3 quarter, wide ///
		ytitle("Tier 1 Capital (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) $xl
	graph export "$results/tr1_scenario.png", as(png) name("Graph") replace

	lgraph eat_1 eat_2 eat_3 quarter, wide ///
		ytitle("Net income (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) $xl
	graph export "$results/eat_scenario.png", as(png) name("Graph") replace
restore


**## 6.2 By KBMI group

* Carry KBMI group into forecast quarters
bys bank_id (quarter): replace kbmi = kbmi[_n-1] if missing(kbmi)

**### 6.2.1 Charts per group (saved as .gph)

forval b = 1/4 {

	* NPL
	lgraph npl_b1 npl_b2 npl_b3 quarter if kbmi == `b', wide ///
		ytitle("NPL (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) ///
		title("KBMI `b'") $xl
	graph save "$results/npl_scenario_kbmi`b'.gph", replace

	* CAR, Tier 1 ratio and net income to assets
	preserve
		keep if kbmi == `b'
		collapse (sum) rwa_b? tier1_b? cap_b? eat_b? asset_b?, by(quarter)

		forval i = 1/3 {
			gen car_`i' = cap_b`i'/rwa_b`i'*100
			label variable car_`i' "CAR scenario `i'"
			gen tr1_`i' = tier1_b`i'/rwa_b`i'*100
			label variable tr1_`i' "Tier 1 capital ratio scenario `i'"
			gen eat_`i' = eat_b`i'/asset_b`i'*100
			label variable eat_`i' "Net income to assets scenario `i'"
		}

		lgraph car_1 car_2 car_3 quarter, wide ///
			ytitle("CAR (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) ///
			title("KBMI `b'") $xl
		graph save "$results/car_scenario_kbmi`b'.gph", replace

		lgraph tr1_1 tr1_2 tr1_3 quarter, wide ///
			ytitle("Tier 1 Capital (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) ///
			title("KBMI `b'") $xl
		graph save "$results/tr1_scenario_kbmi`b'.gph", replace

		lgraph eat_1 eat_2 eat_3 quarter, wide ///
			ytitle("Net income (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) ///
			title("KBMI `b'") $xl
		graph save "$results/eat_scenario_kbmi`b'.gph", replace
	restore
}

**### 6.2.2 Combine group charts into one panel per indicator

foreach ind in npl car tr1 eat {
	graph combine "$results/`ind'_scenario_kbmi1.gph" "$results/`ind'_scenario_kbmi2.gph" ///
		"$results/`ind'_scenario_kbmi3.gph" "$results/`ind'_scenario_kbmi4.gph", iscale(0.5)
	graph export "$results/`ind'_kbmi.png", as(png) name("Graph") replace
}


**## 6.3 Failing banks
* A bank fails in a scenario if its CAR falls below $car_min% at any point
* from the last actual quarter to the end of the horizon.

preserve
	forval i = 1/3 {
		gen fail_`i' = car_b`i' < $car_min & quarter >= max & !missing(car_b`i')
		egen fail_b`i' = max(fail_`i'), by(bank_id)

		qui count if fail_b`i' == 1
		if r(N) == 0 {
			di as text "Scenario `i': no bank with CAR < $car_min%"
			continue
		}

		xtline car_b`i' if fail_b`i' == 1, $xl
		graph save   "$results/fail_bank_scenario`i'.gph", replace
		graph export "$results/fail_bank_scenario`i'.png", as(png) name("Graph") replace
	}
restore



**# 7. EXCEL SUMMARY ============================================================
* Writes $results/stress_test_summary.xlsx (overwritten on every run):
*   Summary        headline results by scenario
*   Industry_path  industry ratios by quarter
*   Bank           bank-level CAR and cumulative losses
*   Assumptions    parameter values used in this run
*
* Only banks with a complete forecast in all three scenarios are included.
* Losses are cumulative over the forecast horizon, in % of regulatory capital
* at the last actual quarter.

**## 7.1 Prepare the sample

global xls "$results/stress_test_summary.xlsx"
cap erase "$xls"

use "$data/bank.dta", clear
xtset bank_id quarter

bys bank_id (quarter): replace bank = bank[_n-1] if bank == ""
bys bank_id (quarter): replace kbmi = kbmi[_n-1] if missing(kbmi)

local base = max[1]
qui sum quarter
local last = r(max)

* Keep banks with a full forecast; keep last actual quarter onward
gen full = !missing(car_b1, car_b2, car_b3) if quarter > max
egen nfull = total(full), by(bank_id)
keep if nfull == `last'-`base' & quarter >= `base'

* Credit losses and NPL stock in amounts
forval i = 1/3 {
	gen cl_b`i'     = prov_b`i'/100*loan_b`i'
	gen nplamt_b`i' = npl_b`i'/100*loan_b`i'
}


**## 7.2 Sheet "Industry_path"

preserve
	collapse (sum) cap_b? tier1_b? rwa_b? eat_b? asset_b? loan_b? cl_b? loss_b? nplamt_b? ///
		(count) banks=bank_id, by(quarter)
	gen str6 qtr = string(quarter, "%tq")

	forval i = 1/3 {
		gen car_s`i'         = cap_b`i'/rwa_b`i'*100
		gen t1_s`i'          = tier1_b`i'/rwa_b`i'*100
		gen npl_s`i'         = nplamt_b`i'/loan_b`i'*100
		gen roa_s`i'         = eat_b`i'/asset_b`i'*100
		gen credit_loss_s`i' = cl_b`i'/loan_b`i'*100
		gen market_loss_s`i' = loss_b`i'/loan_b`i'*100
	}

	* Start/end ratios and cumulative losses, stored for the Summary sheet
	* (row 1 = last actual quarter, row _N = end of horizon)
	local K0 = cap_b1[1]
	forval i = 1/3 {
		local car0_`i' = car_s`i'[1]
		local car1_`i' = car_s`i'[_N]
		local t10_`i'  = t1_s`i'[1]
		local t11_`i'  = t1_s`i'[_N]
		local npl0_`i' = npl_s`i'[1]
		local npl1_`i' = npl_s`i'[_N]

		qui sum cl_b`i' if _n > 1
		local cl_`i' = r(sum)/`K0'*100
		qui sum loss_b`i' if _n > 1
		local ml_`i' = r(sum)/`K0'*100
		qui sum eat_b`i' if _n > 1
		local ni_`i' = r(sum)/`K0'*100
	}
	local nbanks = banks[1]

	keep  qtr banks car_s* t1_s* npl_s* roa_s* credit_loss_s* market_loss_s*
	order qtr banks car_s* t1_s* npl_s* roa_s* credit_loss_s* market_loss_s*
	export excel using "$xls", sheet("Industry_path", replace) firstrow(variables)
restore


**## 7.3 Sheet "Bank"

preserve
	* Values at the last actual quarter
	bys bank_id (quarter): gen cap0      = cap_b1[1]
	bys bank_id (quarter): gen car_start = car_b1[1]
	bys bank_id (quarter): gen npl_start = npl_r[1]
	bys bank_id (quarter): gen sec_cap   = sec_r[1]/100*bs_tot_loan[1]/cap0*100

	* Cumulative losses over the forecast horizon
	forval i = 1/3 {
		bys bank_id (quarter): egen cum_cl`i' = total(cond(quarter > `base', cl_b`i', .))
		bys bank_id (quarter): egen cum_ml`i' = total(cond(quarter > `base', loss_b`i', .))
	}

	* End of horizon; losses in % of the bank's own starting capital
	keep if quarter == `last'
	forval i = 1/3 {
		gen credit_loss_cap_s`i' = cum_cl`i'/cap0*100
		gen market_loss_cap_s`i' = cum_ml`i'/cap0*100
		rename car_b`i' car_end_s`i'
	}

	keep  bank kbmi car_start car_end_s* npl_start sec_cap credit_loss_cap_s* market_loss_cap_s*
	order bank kbmi car_start car_end_s1 car_end_s2 car_end_s3 npl_start sec_cap credit_loss_cap_s* market_loss_cap_s*
	sort car_end_s3

	* Banks below the CAR threshold at end of horizon
	forval i = 1/3 {
		qui count if car_end_s`i' < $car_min
		local fail_`i' = r(N)
	}

	export excel using "$xls", sheet("Bank", replace) firstrow(variables)
restore


**## 7.4 Sheet "Summary"

preserve
	clear
	set obs 3
	gen str10 scenario = cond(_n==1, "Baseline", cond(_n==2, "Adverse 1", "Adverse 2"))

	foreach v in car_start car_end t1_start t1_end npl_start npl_end credit_loss_cap ///
		market_loss_cap net_income_cap credit_share banks_car_below_min {
		gen double `v' = .
	}

	forval i = 1/3 {
		replace car_start           = `car0_`i''  in `i'
		replace car_end             = `car1_`i''  in `i'
		replace t1_start            = `t10_`i''   in `i'
		replace t1_end              = `t11_`i''   in `i'
		replace npl_start           = `npl0_`i''  in `i'
		replace npl_end             = `npl1_`i''  in `i'
		replace credit_loss_cap     = `cl_`i''    in `i'
		replace market_loss_cap     = `ml_`i''    in `i'
		replace net_income_cap      = `ni_`i''    in `i'
		replace credit_share        = 100*`cl_`i''/(`cl_`i''+max(`ml_`i'',0)) in `i'
		replace banks_car_below_min = `fail_`i''  in `i'
	}

	gen str6 base_quarter = string(`base', "%tq")
	gen str6 end_quarter  = string(`last', "%tq")
	gen banks = `nbanks'
	export excel using "$xls", sheet("Summary", replace) firstrow(variables)
restore


**## 7.5 Sheet "Assumptions"

preserve
	clear
	set obs 0
	gen str60 parameter = ""
	gen str20 value     = ""

	local params payout k_stress npl_b0 npl_b1 w_srbi D_sbn tax_rate car_min
	foreach p of local params {
		local n = _N + 1
		set obs `n'
		replace parameter = "`p'"                       in `n'
		replace value     = string(${`p'}, "%9.4f")     in `n'
	}

	local n = _N + 1
	set obs `n'
	replace parameter = "rwa_growth"                    in `n'
	replace value     = "$rwa_growth"                   in `n'

	local n = _N + 1
	set obs `n'
	replace parameter = "last actual quarter"           in `n'
	replace value     = string(`base', "%tq")           in `n'

	local n = _N + 1
	set obs `n'
	replace parameter = "forecast quarters"             in `n'
	replace value     = string(`last'-`base')           in `n'

	export excel using "$xls", sheet("Assumptions", replace) firstrow(variables)
restore

di as text "Excel summary written to $xls"

*==================================== END =====================================
