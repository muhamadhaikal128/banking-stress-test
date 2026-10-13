*****************************
****** Global Settings ******
*****************************

* 	Notes: Fixed version of archive/old_script/dofile_old.do. Same structure and model choices;
*	corrections are marked "FIX:" in the comments. See the FIX LOG at the end of this file.
*	Do not put "//" comments at the end of "global" lines (causes r(198) if no space before "//").

global base "C:\Users\LENOVO05\github\banking-stress-test"

* Raw macro data (Solvency ST.xlsx)
global source "$base\input"
* Raw bank data (Stress Testing Manual - Excel Template.xlsx)
global bql "$base\input"
* Stata data results (macro.dta, bank.dta, etc.)
global data "$base\intermediate\fixed"
* Stress test results
global results "$base\output\fixed"
* Forecast horizon (quarters) and failure threshold
global horizon 4
global car_min 8
* Himbara group: state-owned banks (BRI, Mandiri, BNI, BTN) plus BSI (BRIS, majority state-owned via
* Mandiri/BRI/BNI; not a formal Himbara member, included by choice)
global himbara "BBRI BMRI BBNI BBTN BRIS"
* Property-price effect on NPL (JUDGMENT, borrowed from Prospera): total effect on NPL (pp) of +1pp QoQ
* property price growth, spread evenly over lags 1-4. -0.429 = sum of the d_property lag coefficients
* in Prospera's NPL regression (2014-2024Q2). Our own data cannot identify it: IHPR never fell in sample
* and the estimated sign is wrong. 0 = off (pure model).
global e_prop -0.429

cap mkdir "$data"
cap mkdir "$results"

* Adjustable assumptions: Solvency ST.xlsx, sheet Parameters (column parameter = global name, value)
cap import excel "$source\Solvency ST.xlsx", sheet("Parameters") firstrow case(lower) clear
if _rc {
	di as error "Cannot read Solvency ST.xlsx (sheet Parameters). Close the file in Excel and re-run."
	exit 603
}
forval r=1/`=_N'{
	global `=parameter[`r']' = value[`r']
	di "`=parameter[`r']' = ${`=parameter[`r']'}"
}

*****************************
**** Raw Data Extraction ****
*****************************

*1.	Macroeconomic data
	import excel "$source\Solvency ST.xlsx", sheet("Macro") firstrow case(lower) clear
	format quarter %tq
	save "$data\macro.dta", replace

*2.	Macroeconomic scenario
	forval i=1/3{
		import excel "$source\Solvency ST.xlsx", sheet("Scenario `i'") case(lower) firstrow clear
		save "$data\scen`i'.dta", replace
		use "$data\macro.dta", clear
		append using "$data\scen`i'.dta"
		gen ln_forex=log(forex)
		save "$data\comb`i'.dta", replace
	}

*3.	Bank-level data
	import excel "$bql\Stress Testing Manual - Excel Template.xlsx", sheet("Output Sheet (Copy)") firstrow case(lower) clear
	* FIX: name variables from the BQL item label (text before "("). "rename *fill* *" left names
	*      such as is_int_incfa_period_typeq, which only worked through Stata abbreviation.
	foreach v of varlist _all {
		if "`v'"=="id" continue
		local lab: variable label `v'
		local p=strpos(`"`lab'"', "(")
		if `p'<=1 {
			drop `v'
			continue
		}
		local new=lower(substr(`"`lab'"', 1, `p'-1))
		capture confirm new variable `new'
		if !_rc rename `v' `new'
		else drop `v'
	}

	rename bs_sh_out dates
	gen quarter = qofd(dates)
	format quarter %tq
	drop if quarter == . | id == ""

	gen bank = substr(id, 1, 4)
	bys bank quarter: gen dup = cond(_N==1, 0, _n)
	drop if dup > 1
	isid bank quarter
	drop dup

	* FIX: m:1 merge (one KBMI row per bank) and keep matched banks only
	merge m:1 bank using "$source\kbmi.dta", keep(match) keepusing(kbmi) nogen

	* temporary command, to exclude outlier
	drop if bank == "BANK"
	* MCOR: simulated interest expense ~9x interest income (saving_r data issue) -> spurious failure
	drop if bank == "MCOR"

	encode bank, gen(bank_id)
	xtset bank_id quarter

	tsfill, full
	decode bank_id, generate(bank2)
	replace bank = bank2
	drop bank2
	replace id = bank + " IJ Equity" if id == ""
	bys bank_id (kbmi): replace kbmi = kbmi[1]

	order bank bank_id quarter *
	drop if quarter < tq(2010q1)

	la var dates "Date"
	la var bank_id "Bank Ticker"
	la var kbmi "KBMI group"

	save "$data\bank.dta", replace


*****************************
****** NPL Forecasting ******
*****************************

use "$data\bank.dta", clear

egen max=max(quarter)
format max %tq
label variable max "Maximum period"
xtset bank_id quarter
tsappend, add($horizon)
xtset bank_id quarter
replace max=l.max if max==.
gen year=yofd(dofq(quarter))
label variable year "Year"
xtset bank_id quarter
bys bank_id (quarter): replace bank=bank[_n-1] if bank==""
bys bank_id (quarter): replace kbmi=kbmi[_n-1] if missing(kbmi)
xtset bank_id quarter
* state-owned banks (Himbara), for the Himbara vs non-Himbara results
gen byte himbara=0
foreach t of global himbara {
	replace himbara=1 if bank=="`t'"
}
la var himbara "Himbara (state-owned bank)"

gen npl_r=bs_non_perform_loans/bs_tot_loan*100
label variable npl_r "NPL ratio"
* reporting breaks (NPL = 0, or NPL jumps of 5pp+ in a quarter): flagged, left out of the fit chart
gen byte nbrk=(npl_r==0 | (abs(d.npl_r)>=5 & !missing(d.npl_r))) if quarter<=max
la var nbrk "NPL reporting break (excluded from estimation)"

*****************************
***** Ratio assumptions *****
*****************************

gen prov_r=is_prov_for_loan_loss/bs_tot_loan*100
la var prov_r "Provision to loans"

* Provision response to NPL increases (bank FE, all years pooled; extreme NPL jumps > 5pp excluded)
gen dnpl_pos=max(d.npl_r,0) if !missing(d.npl_r) & abs(d.npl_r)<5 & quarter<=max
qui xtreg prov_r dnpl_pos l.dnpl_pos, fe vce(cluster bank_id)
global npl_b0=_b[dnpl_pos]
global npl_b1=_b[l.dnpl_pos]
di "Provision response to +1pp NPL: t = " %5.3f $npl_b0 ", t+1 = " %5.3f $npl_b1 ", total = " %5.3f $npl_b0+$npl_b1
drop dnpl_pos

* FIX: starting ratios from the LAST ACTUAL quarter (stocks) or the LAST 4 QUARTERS (flows),
*      not the bank's 2014-2026 average, which made loans, deposits and income jump at the
*      start of the forecast
gen c_loan_r=bs_tot_loan/bs_tot_asset*100
gen c_dep_r=bs_customer_deposits/bs_tot_asset*100
gen c_nii_r=non_int_inc/bs_tot_asset*100
gen c_nie_r=non_int_exp/bs_tot_asset*100
foreach j in loan_r dep_r{
	egen `j'=mean(cond(quarter==max, c_`j', .)), by(bank_id)
	drop c_`j'
}
foreach j in nii_r nie_r{
	egen `j'=mean(cond(quarter>max-4 & quarter<=max, c_`j', .)), by(bank_id)
	drop c_`j'
}

* lending and saving rates are QUARTERLY rates (quarterly interest / stock)
gen c_lending_r=is_int_inc/bs_tot_loan*100
egen lending_r=mean(cond(quarter>max-4 & quarter<=max, c_lending_r, .)), by(bank_id)
label variable lending_r "Lending rate (quarterly)"
gen c_saving_r=(is_int_inc-net_int_inc)/bs_customer_deposits*100
replace c_saving_r=0 if c_saving_r<0
egen saving_r=mean(cond(quarter>max-4 & quarter<=max, c_saving_r, .)), by(bank_id)
label variable saving_r "Saving rate (quarterly)"
foreach j in lending_r saving_r{
	replace `j'=. if quarter>max
	drop c_`j'
}

* FIX: labels said "to assets" but the ratios are to loans
gen afs_r=av_sa_fa_at_fv_thru_ot_comp_inc/bs_tot_loan*100
la var afs_r "AFS (FVOCI) securities to loans"
gen tra_r=trading_secs_fa_at_fv_thru_pl/bs_tot_loan*100
la var tra_r "Trading (FVTPL) securities to loans"
egen sec_r=rowtotal(afs_r tra_r), missing
* FIX: Bloomberg returns mis-scaled securities for some small banks (larger than TOTAL ASSETS);
*      replace those with the KBMI median instead of capping at 100% of loans
gen byte sec_flag=(av_sa_fa_at_fv_thru_ot_comp_inc+trading_secs_fa_at_fv_thru_pl)>bs_tot_asset ///
	if !missing(av_sa_fa_at_fv_thru_ot_comp_inc, trading_secs_fa_at_fv_thru_pl, bs_tot_asset)
replace sec_flag=0 if missing(sec_flag)
replace sec_r=. if sec_flag
bys kbmi quarter: egen sec_med=median(sec_r)
replace sec_r=sec_med if sec_flag
drop sec_med
replace sec_r=100 if sec_r>100 & !missing(sec_r)
* no reported AFS/trading securities -> treat as zero (otherwise the bank drops out of the forecast)
replace sec_r=0 if missing(sec_r) & quarter<=max
la var sec_r "Tradeable securities to loans"
la var sec_flag "Securities mis-scaled in source, KBMI median used"
* FIX: FVTPL share, so trading losses go through P&L and FVOCI losses through OCI (capital)
gen c_tra_sh=cond(sec_flag | missing(tra_r) | sec_r==0, 0.5, tra_r/(afs_r+tra_r))
replace c_tra_sh=1 if missing(afs_r) & !missing(tra_r) & !sec_flag & sec_r>0
egen tra_sh=mean(cond(quarter==max, c_tra_sh, .)), by(bank_id)
drop c_tra_sh
la var tra_sh "FVTPL share of tradeable securities"

* TAX RATE ASSUMPTIONS ($tax_rate from Solvency ST.xlsx, sheet Parameters)
gen tax_rate=$tax_rate
la var tax_rate "Tax rate"

* Other assumptions are read from Solvency ST.xlsx, sheet Parameters (see Global Settings):
*   payout   - dividend payout on positive profit (losses hit capital in full)
*   w_srbi   - SRBI share of bank securities; SRBI is held to maturity (no MTM loss), so only the
*              SBN share is revalued
*   D_sbn    - modified duration of the SBN book (priced off the SBN 10Y yield)
*   k_stress - stress provision add-on: k x (baseline GDP - scenario GDP, pp) x bank NPL stock, per
*              quarter. Calibrated so Adverse 2 cumulative credit loss ~ 2021 peak (11.5% of capital).
*              Baseline gets no add-on (gap = 0).
save "$data\bank.dta", replace

*****************************
******** Simulations ********
*****************************

use "$data\bank.dta", clear

xtset bank_id quarter

forval i=1/3{

	*Obtaining scenario*
	* FIX: m:1 merge (comb has one row per quarter); was m:m ... force
	merge m:1 quarter using "$data\comb`i'.dta", keep(match) ///
		keepusing(gdp reporate cpi forex property d_property ln_forex d_price ust10y sbn10y) nogen
	foreach j in gdp reporate cpi forex d_property ln_forex d_price ust10y sbn10y{
		gen `j'_b`i'=`j'
	}
	sort bank_id quarter
	xtset bank_id quarter
	* securities price change (%): only the SBN share is marked to market (SRBI held to maturity);
	* overrides the sheet's d_price
	replace d_price_b`i'=-(1-$w_srbi)*$D_sbn*d.sbn10y_b`i'

	*B/S calculations*
	* balance sheet grows with nominal GDP (real yoy growth + CPI inflation)
	* FIX: exact quarterly rate (1+g)^(1/4)-1 instead of g/4
	gen double g_b`i'=(1+(gdp+cpi)/100)^0.25-1
	gen asset_b`i'=bs_tot_asset
	bys bank_id (quarter): replace asset_b`i'=asset_b`i'[_n-1] * (1+g_b`i') if missing(asset_b`i') & quarter>max
	label variable asset_b`i' "Bank assets scenario `i'"

	* FIX: RWA grows with the scenario's OWN GDP and CPI (was gdp_b1+cpi_b1, i.e. baseline, in all scenarios)
	gen rwa_b`i'=bs_risk_weighted_assets
	bys bank_id (quarter): replace rwa_b`i'=rwa_b`i'[_n-1] * (1+g_b`i') if missing(rwa_b`i') & quarter>max
	label variable rwa_b`i' "RWA scenario `i'"

	gen size_b`i'=log(asset_b`i')
	label variable size_b`i' "Bank size scenario `i'"

	* FIX: actual loans/deposits in history; forecast = last actual share x projected assets
	gen loan_b`i'=cond(quarter<=max, bs_tot_loan, loan_r/100*asset_b`i')
	label variable loan_b`i' "Bank loans scenario `i'"

	gen dep_b`i'=cond(quarter<=max, bs_customer_deposits, dep_r/100*asset_b`i')
	label variable dep_b`i' "Bank deposits scenario `i'"

	gen sec_b`i'=sec_r
	label variable sec_b`i' "Bank securities scenario `i'"
	bys bank_id (quarter): replace sec_b`i'=sec_b`i'[_n-1] if missing(sec_b`i') & quarter>max

	* FIX: non-interest income/expense grow with the balance sheet (last-4Q ratio to assets)
	*      instead of staying flat at the last quarter's level
	gen nii_b`i'=cond(quarter<=max, non_int_inc, nii_r/100*asset_b`i')
	gen nie_b`i'=cond(quarter<=max, non_int_exp, nie_r/100*asset_b`i')

	*NPL modelling and forecasting*
	* dynamic FE model: lagged NPL + GDP + BI rate. Property is not estimated: IHPR never fell in-sample
	* (min d_property +0.04), so its coefficient has the wrong sign and adverse shocks lowered NPL.
	* Instead a judgmental property term ($e_prop, Prospera elasticity) is added as a STATIC component:
	*   NPL = core + prop,  prop = e_prop/4 x (sum of d_property lags 1-4),
	*   core follows the dynamic model (so the property term is not multiplied by NPL persistence).
	* FIX: clustered SEs instead of a 10-replication bootstrap (point estimates are identical)
	gen double prop`i'=cond($e_prop==0, 0, ($e_prop/4)*(l.d_property+l2.d_property+l3.d_property+l4.d_property))
	gen double nplc`i'=npl_r-prop`i'
	gen npl_b`i'=npl_r
	qui xtreg nplc`i' l.nplc`i' l.gdp l2.gdp l3.gdp l4.gdp l.reporate l2.reporate l3.reporate l4.reporate, fe vce(cluster bank_id)
	* recursive forecast: each quarter uses the previous quarter's forecast NPL
	* (xbu is only defined in-sample, so carry each bank's fixed effect u_i forward explicitly).
	* With u_i each bank adjusts gradually (rho ~ 0.8) toward its through-the-cycle NPL; NPL is at a
	* cyclical low in 2026, so it drifts up in all scenarios, the adverse shocks come on top.
	predict double npl_fit, xb
	predict double npl_u, u
	bys bank_id: egen double npl_ui=max(npl_u)
	gen npl_u0=npl_ui
	xtset bank_id quarter
	qui sum quarter
	forval q=`=max[1]+1'/`r(max)'{
		predict double npl_tmp, xb
		* FIX: a linear model can go below zero; floor at 0
		* NPL = forecast core + property term; the core carried to the next quarter is NPL - property term
		replace npl_b`i'=cond(missing(npl_tmp+npl_ui+prop`i'), ., max(npl_tmp+npl_ui+prop`i', 0)) if quarter==`q'
		replace nplc`i'=npl_b`i'-prop`i' if quarter==`q'
		drop npl_tmp
	}
	* in-sample fitted NPL incl. bank effect (for the fit chart)
	gen npl_i`i'=npl_fit+npl_u0+prop`i' if quarter<=max
	drop npl_fit npl_u npl_ui npl_u0 nplc`i'

	label variable npl_b`i' "NPL ratio scenario `i'"

	*Provision forecasting*
	* provision/loans = bank's normal credit cost (avg of last 8 quarters)
	*                 + estimated response to NPL increases this quarter and last quarter ($npl_b0, $npl_b1)
	gen prov_b`i'=prov_r
	bys bank_id: egen prov_base`i'=mean(cond(quarter>max-8 & quarter<=max, prov_r, .))
	egen prov_med`i'=median(prov_base`i')
	replace prov_base`i'=prov_med`i' if missing(prov_base`i')
	xtset bank_id quarter
	replace prov_b`i'=prov_base`i' + $npl_b0*max(npl_b`i'-l.npl_b`i',0) + $npl_b1*max(l.npl_b`i'-l2.npl_b`i',0) if quarter>max
	replace prov_b`i'=0 if prov_b`i'<0 & quarter>max
	replace prov_b`i'=prov_b`i' + $k_stress*max(gdp_b1-gdp,0)*npl_b`i' if quarter>max
	label variable prov_b`i' "Bank provisions scenario `i'"
	drop prov_base`i' prov_med`i'

	*Losses from tradeable securities*
	* d_price = % price change of securities = -duration x change in SBN 10Y yield
	* sec_b is securities to loans (%), so convert to an amount before applying the price change
	gen sec_amt_b`i'=sec_b`i'/100*loan_b`i'
	gen loss_b`i'=-(d_price_b`i'/100)*sec_amt_b`i'
	label variable loss_b`i' "Losses from securities transactions"
	* FIX: FVTPL part through P&L (taxable), FVOCI part through OCI straight to capital
	gen loss_pl_b`i'=tra_sh*loss_b`i'
	gen loss_oci_b`i'=(1-tra_sh)*loss_b`i'
	gen loss_r_b`i'=loss_b`i'/loan_b`i'*100
	label variable loss_r_b`i' "Securities losses to loans scenario `i'"

	*I/S calculations*
	* FIX: lending/saving rates are quarterly, so add the policy-rate change divided by 4
	*      (adding the annual change overstated the repricing effect four-fold)
	gen lending_r_b`i'=lending_r
	bys bank_id (quarter): replace lending_r_b`i'=lending_r_b`i'[_n-1] + d.reporate/4 if missing(lending_r_b`i') & quarter>max

	gen saving_r_b`i'=saving_r
	bys bank_id (quarter): replace saving_r_b`i'=saving_r_b`i'[_n-1] + d.reporate/4 if missing(saving_r_b`i') & quarter>max

	gen int_inc_b`i'=lending_r_b`i'/100*loan_b`i'
	gen int_exp_b`i'=saving_r_b`i'/100*dep_b`i'

	gen nim_b`i'=(int_inc_b`i'-int_exp_b`i')/asset_b`i'

	gen ebt_b`i'=int_inc_b`i' - int_exp_b`i'+ nii_b`i' - nie_b`i' - (prov_b`i'/100)*loan_b`i' - loss_pl_b`i'
	gen tax_b`i'=ebt_b`i'*tax_rate
	replace tax_b`i'=0 if tax_b`i'<0
	gen eat_b`i'=ebt_b`i'-tax_b`i'
	* FIX: history shows reported net income, not the model's back-cast
	replace eat_b`i'=net_income if quarter<=max

	*CAR calculations*
	gen tier1_b`i'=bs_tier1_capital
	gen ret_b`i'=cond(eat_b`i'>0, (1-$payout)*eat_b`i', eat_b`i') if !missing(eat_b`i')
	label variable ret_b`i' "Retained earnings scenario `i'"
	replace tier1_b`i'=l.tier1_b`i'+ret_b`i'-loss_oci_b`i' if quarter>max
	label variable tier1_b`i' "Tier 1 capital scenario `i'"
	gen cap_b`i'=bs_tot_cap_fund
	replace cap_b`i'=l.cap_b`i'+ret_b`i'-loss_oci_b`i' if quarter>max
	label variable cap_b`i' "Regulatory capital scenario `i'"

	gen t1r_b`i'=tier1_b`i'/rwa_b`i'*100
	label variable t1r_b`i' "Tier 1 ratio scenario `i'"
	gen car_b`i'=cap_b`i'/rwa_b`i'*100
	label variable car_b`i' "CAR scenario `i'"

	drop gdp reporate cpi forex property d_property ln_forex d_price ust10y sbn10y g_b`i'
}

save "$data\bank.dta", replace

*****************************
********** Results **********
*****************************

* FIX: industry series are aggregated (sum of amounts, then ratio) instead of lgraph's simple average
*      of bank ratios; dates and reference lines come from the data instead of being hard-coded
	local base=max[1]
	local c1 navy
	local c2 orange
	local c3 maroon
	local leg legend(order(1 "Baseline" 2 "Adverse 1" 3 "Adverse 2") pos(6) row(1) size(small))
	local gop graphregion(color(white)) xline(`base', lcolor(gs10) lpattern(shortdash)) xtitle("Quarter")

	cap program drop plot3
	program define plot3
		* plot3 stub, ytitle() file() [title() save]: draws stub_1-stub_3 against quarter
		syntax name, YTitle(string) FILE(string) [TItle(string) SAVE OPTS(string asis)]
		twoway (line `namelist'_1 quarter, lcolor(navy) lwidth(medthick))     ///
		       (line `namelist'_2 quarter, lcolor(orange) lwidth(medthick))   ///
		       (line `namelist'_3 quarter, lcolor(maroon) lwidth(medthick)),  ///
		       ytitle("`ytitle'") title("`title'") `opts'
		if "`save'"!="" graph save "`file'.gph", replace
		else graph export "`file'.png", as(png) replace width(1600)
	end

	forval i=1/3{
		gen nplamt_b`i'=npl_b`i'/100*loan_b`i'
		gen provamt_b`i'=prov_b`i'/100*loan_b`i'
	}

*1.	NPL model fit (in-sample, loan-weighted)
	preserve
		keep if quarter<=`base' & year>2014
		gen nplamt_a=npl_r/100*bs_tot_loan if !nbrk
		gen nplamt_f=npl_i1/100*bs_tot_loan if !nbrk
		gen loan_a=bs_tot_loan if !nbrk & !missing(npl_i1)
		replace nplamt_a=. if missing(npl_i1)
		collapse (sum) nplamt_a nplamt_f loan_a, by(quarter)
		gen npl_actual=nplamt_a/loan_a*100
		gen npl_fitted=nplamt_f/loan_a*100
		twoway (line npl_actual quarter, lcolor(black) lwidth(medthick)) (line npl_fitted quarter, lcolor(maroon) lpattern(dash) lwidth(medthick)), ///
			ytitle("NPL (%)") xtitle("Quarter") legend(order(1 "Actual" 2 "Fitted") pos(6) row(1) size(small)) graphregion(color(white))
		graph export "$results\npl_predict.png", as(png) replace width(1600)
	restore

*2.	Industry results
	preserve
		keep if year>=2022
		collapse (sum) nplamt_b* provamt_b* loan_b* loss_b* rwa_b* tier1_b* cap_b* eat_b* asset_b*, by(quarter)
		forval i=1/3{
			gen npl_`i'=nplamt_b`i'/loan_b`i'*100
			gen prov_`i'=provamt_b`i'/loan_b`i'*100
			gen sec_`i'=loss_b`i'/loan_b`i'*100
			gen car_`i'=cap_b`i'/rwa_b`i'*100
			gen tr1_`i'=tier1_b`i'/rwa_b`i'*100
			gen eat_`i'=eat_b`i'/asset_b`i'*100
		}
		plot3 npl,  ytitle("Industry NPL (%)") file("$results\npl_scenario") opts(`leg' `gop')
		plot3 prov, ytitle("Industry provisions (% of loans, quarterly)") file("$results\prov_scenario") opts(`leg' `gop')
		plot3 sec,  ytitle("Losses from MTM securities to loans (%)") file("$results\securities") opts(`leg' `gop')
		plot3 car,  ytitle("CAR (%)") file("$results\car_scenario") opts(`leg' `gop')
		plot3 tr1,  ytitle("Tier 1 Capital (%)") file("$results\tr1_scenario") opts(`leg' `gop')
		plot3 eat,  ytitle("Net income to assets (%, quarterly)") file("$results\eat_scenario") opts(`leg' `gop')

		* loss composition per scenario (forecast quarters)
		keep if quarter>`base'
		gen qlab=string(quarter,"%tq")
		forval x=1/3{
			graph bar prov_`x' sec_`x', stack over(qlab) bar(1, color(navy)) bar(2, color(maroon)) ///
				legend(order(1 "Credit losses" 2 "Market losses") pos(6) row(1) size(medium)) ///
				ytitle("Losses to total loans (%)") title("Scenario `x'") graphregion(color(white))
			graph save "$results\comp_`x'.gph", replace
		}
		graph combine "$results\comp_1.gph" "$results\comp_2.gph" "$results\comp_3.gph", iscale(0.5) row(1) ycommon graphregion(color(white))
		graph export "$results\composition.png", as(png) replace width(1800)
	restore

*3.	KBMI results
	forval b=1/4{
		preserve
			keep if kbmi==`b' & year>=2022
			collapse (sum) nplamt_b* loan_b* rwa_b* tier1_b* cap_b* eat_b* asset_b*, by(quarter)
			forval i=1/3{
				gen npl_`i'=nplamt_b`i'/loan_b`i'*100
				gen car_`i'=cap_b`i'/rwa_b`i'*100
				gen tr1_`i'=tier1_b`i'/rwa_b`i'*100
				gen eat_`i'=eat_b`i'/asset_b`i'*100
			}
			plot3 npl, ytitle("NPL (%)") title("KBMI `b'") file("$results\npl_scenario_kbmi`b'") save opts(`leg' `gop')
			plot3 car, ytitle("CAR (%)") title("KBMI `b'") file("$results\car_scenario_kbmi`b'") save opts(`leg' `gop')
			plot3 tr1, ytitle("Tier 1 Capital (%)") title("KBMI `b'") file("$results\tr1_scenario_kbmi`b'") save opts(`leg' `gop')
			plot3 eat, ytitle("Net income (%)") title("KBMI `b'") file("$results\eat_scenario_kbmi`b'") save opts(`leg' `gop')
		restore
	}
	foreach s in npl car tr1 eat{
		graph combine "$results\\`s'_scenario_kbmi1.gph" "$results\\`s'_scenario_kbmi2.gph" ///
			"$results\\`s'_scenario_kbmi3.gph" "$results\\`s'_scenario_kbmi4.gph", iscale(0.5) graphregion(color(white))
		graph export "$results\\`s'_kbmi.png", as(png) replace width(1800)
	}

*3b. Himbara vs non-Himbara results
	forval h=1(-1)0{
		local gl=cond(`h'==1,"Himbara","Non-Himbara")
		preserve
			keep if himbara==`h' & year>=2022
			collapse (sum) nplamt_b* loan_b* rwa_b* tier1_b* cap_b* eat_b* asset_b*, by(quarter)
			forval i=1/3{
				gen npl_`i'=nplamt_b`i'/loan_b`i'*100
				gen car_`i'=cap_b`i'/rwa_b`i'*100
				gen tr1_`i'=tier1_b`i'/rwa_b`i'*100
				gen eat_`i'=eat_b`i'/asset_b`i'*100
			}
			plot3 npl, ytitle("NPL (%)") title("`gl'") file("$results\npl_scenario_him`h'") save opts(`leg' `gop')
			plot3 car, ytitle("CAR (%)") title("`gl'") file("$results\car_scenario_him`h'") save opts(`leg' `gop')
			plot3 tr1, ytitle("Tier 1 Capital (%)") title("`gl'") file("$results\tr1_scenario_him`h'") save opts(`leg' `gop')
			plot3 eat, ytitle("Net income (%)") title("`gl'") file("$results\eat_scenario_him`h'") save opts(`leg' `gop')
		restore
	}
	foreach s in npl car tr1 eat{
		graph combine "$results\\`s'_scenario_him1.gph" "$results\\`s'_scenario_him0.gph", ///
			row(1) ycommon iscale(0.7) graphregion(color(white))
		graph export "$results\\`s'_himbara.png", as(png) replace width(1800)
	}

*4.	Failed banks
	preserve
		forval i=1/3{
			* FIX: failure is judged on forecast quarters only (quarter>max; was >=max, i.e. incl. the actual)
			gen fail_`i'=car_b`i'<$car_min & quarter>max & !missing(car_b`i')
			egen fail_b`i'=max(fail_`i'),by(bank_id)
			qui count if fail_b`i'==1
			if r(N)==0 {
				di "Scenario `i': no bank with CAR < $car_min%"
				continue
			}
			xtline car_b`i' if fail_b`i'==1 & year>=2024, overlay yline($car_min, lcolor(maroon) lpattern(dash)) ///
				ytitle("CAR (%)") xline(`base', lcolor(gs10) lpattern(shortdash)) graphregion(color(white))
			graph export "$results\fail_bank_scenario`i'.png", as(png) replace width(1600)
		}
	restore

*****************************
********** Excel summary ****
*****************************

*  $results\stress_test_summary.xlsx (overwritten on every run). Industry figures use banks with a full
*  forecast in all scenarios. Losses are cumulative over the forecast horizon, in % of starting
*  (last actual quarter) regulatory capital.

	global xls "$results\stress_test_summary.xlsx"
	cap erase "$xls"

	use "$data\bank.dta", clear
	xtset bank_id quarter
	local base=max[1]
	qui sum quarter
	local last=r(max)
	gen full=!missing(car_b1,car_b2,car_b3) if quarter>max
	egen nfull=total(full), by(bank_id)
	keep if nfull==`last'-`base' & quarter>=`base'
	forval i=1/3{
		gen cl_b`i'=prov_b`i'/100*loan_b`i'
		gen nplamt_b`i'=npl_b`i'/100*loan_b`i'
	}

	* Industry path by quarter
	preserve
		collapse (sum) cap_b* tier1_b* rwa_b* eat_b* asset_b* loan_b* cl_b* loss_b* nplamt_b* (count) banks=bank_id, by(quarter)
		gen str6 qtr=string(quarter,"%tq")
		forval i=1/3{
			gen car_s`i'=cap_b`i'/rwa_b`i'*100
			gen t1_s`i'=tier1_b`i'/rwa_b`i'*100
			gen npl_s`i'=nplamt_b`i'/loan_b`i'*100
			gen roa_s`i'=eat_b`i'/asset_b`i'*100
			gen credit_loss_s`i'=cl_b`i'/loan_b`i'*100
			gen market_loss_s`i'=loss_b`i'/loan_b`i'*100
		}
		local K0=cap_b1[1]
		forval i=1/3{
			local car0_`i'=car_s`i'[1]
			local car1_`i'=car_s`i'[_N]
			local t10_`i'=t1_s`i'[1]
			local t11_`i'=t1_s`i'[_N]
			local npl0_`i'=npl_s`i'[1]
			local npl1_`i'=npl_s`i'[_N]
			qui sum cl_b`i' if _n>1
			local cl_`i'=r(sum)/`K0'*100
			qui sum loss_b`i' if _n>1
			local ml_`i'=r(sum)/`K0'*100
			qui sum eat_b`i' if _n>1
			local ni_`i'=r(sum)/`K0'*100
		}
		local nbanks=banks[1]
		keep qtr banks car_s* t1_s* npl_s* roa_s* credit_loss_s* market_loss_s*
		order qtr banks car_s* t1_s* npl_s* roa_s* credit_loss_s* market_loss_s*
		export excel using "$xls", sheet("Industry_path", replace) firstrow(variables)
	restore

	* Groups: Himbara vs non-Himbara and KBMI 1-4 (same definitions as the industry figures)
	preserve
		gen str12 group=cond(himbara==1,"Himbara","Non-Himbara")
		tempfile gsrc
		save `gsrc'
		replace group="KBMI "+string(kbmi)
		append using `gsrc'
		* a bank fails if CAR < minimum in any forecast quarter; counted once per bank (base-quarter row)
		bys group bank_id (quarter): gen byte first=_n==1
		forval i=1/3{
			bys group bank_id: egen byte fl`i'=max(car_b`i'<$car_min & quarter>`base' & !missing(car_b`i'))
			gen byte nfail`i'=fl`i'*first
		}
		collapse (sum) cap_b* tier1_b* rwa_b* eat_b* asset_b* loan_b* cl_b* loss_b* nplamt_b* nfail* ///
			(count) banks=bank_id, by(group quarter)
		gen str6 qtr=string(quarter,"%tq")
		gen byte ord=cond(group=="Himbara",1,cond(group=="Non-Himbara",2,2+real(substr(group,6,1))))
		sort ord quarter
		forval i=1/3{
			gen car_s`i'=cap_b`i'/rwa_b`i'*100
			gen t1_s`i'=tier1_b`i'/rwa_b`i'*100
			gen npl_s`i'=nplamt_b`i'/loan_b`i'*100
		}
		export excel group qtr banks car_s* t1_s* npl_s* using "$xls", sheet("Group_path", replace) firstrow(variables)

		* one row per group x scenario; losses and income cumulative, % of the group's starting capital
		bys ord (quarter): gen double K0=cap_b1[1]
		forval i=1/3{
			bys ord (quarter): gen car_start`i'=car_s`i'[1]
			bys ord (quarter): gen car_end`i'=car_s`i'[_N]
			bys ord: egen car_min`i'=min(cond(quarter>`base', car_s`i', .))
			bys ord (quarter): gen t1_end`i'=t1_s`i'[_N]
			bys ord (quarter): gen npl_start`i'=npl_s`i'[1]
			bys ord (quarter): gen npl_end`i'=npl_s`i'[_N]
			bys ord: egen credit_loss_cap`i'=total(cond(quarter>`base', cl_b`i'/K0*100, .))
			bys ord: egen market_loss_cap`i'=total(cond(quarter>`base', loss_b`i'/K0*100, .))
			bys ord: egen net_income_cap`i'=total(cond(quarter>`base', eat_b`i'/K0*100, .))
			bys ord: egen banks_car_below8`i'=total(nfail`i')
		}
		keep if quarter==`last'
		keep group ord banks car_start? car_end? car_min? t1_end? npl_start? npl_end? credit_loss_cap? market_loss_cap? net_income_cap? banks_car_below8?
		reshape long car_start car_end car_min t1_end npl_start npl_end credit_loss_cap market_loss_cap net_income_cap banks_car_below8, i(ord) j(s)
		gen str10 scenario=cond(s==1,"Baseline",cond(s==2,"Adverse 1","Adverse 2"))
		sort ord s
		order group scenario banks
		drop ord s
		export excel using "$xls", sheet("Group_summary", replace) firstrow(variables)
		list group scenario car_start car_end car_min npl_end credit_loss_cap banks_car_below8 if strpos(group,"KBMI")==0, clean noobs
	restore

	* Bank level: CAR at start and end of horizon, cumulative losses in % of own starting capital
	preserve
		bys bank_id (quarter): gen cap0=cap_b1[1]
		bys bank_id (quarter): gen car_start=car_b1[1]
		bys bank_id (quarter): gen npl_start=npl_r[1]
		bys bank_id (quarter): gen sec_cap=sec_r[1]/100*bs_tot_loan[1]/cap0*100
		forval i=1/3{
			bys bank_id (quarter): egen cum_cl`i'=total(cond(quarter>`base', cl_b`i', .))
			bys bank_id (quarter): egen cum_ml`i'=total(cond(quarter>`base', loss_b`i', .))
			bys bank_id (quarter): egen car_min_s`i'=min(cond(quarter>`base', car_b`i', .))
		}
		keep if quarter==`last'
		forval i=1/3{
			gen credit_loss_cap_s`i'=cum_cl`i'/cap0*100
			gen market_loss_cap_s`i'=cum_ml`i'/cap0*100
			rename car_b`i' car_end_s`i'
		}
		keep bank kbmi himbara car_start car_end_s* car_min_s* npl_start sec_cap sec_flag credit_loss_cap_s* market_loss_cap_s*
		order bank kbmi himbara car_start car_end_s1 car_end_s2 car_end_s3 car_min_s* npl_start sec_cap sec_flag credit_loss_cap_s* market_loss_cap_s*
		sort car_end_s3
		* FIX: a bank fails if CAR drops below the minimum in ANY forecast quarter, not only the last
		forval i=1/3{
			qui count if car_min_s`i'<$car_min
			local fail_`i'=r(N)
		}
		export excel using "$xls", sheet("Bank", replace) firstrow(variables)
	restore

	* Summary by scenario
	preserve
		clear
		set obs 3
		gen str10 scenario=cond(_n==1,"Baseline",cond(_n==2,"Adverse 1","Adverse 2"))
		foreach v in car_start car_end t1_start t1_end npl_start npl_end credit_loss_cap market_loss_cap net_income_cap credit_share banks_car_below8{
			gen double `v'=.
		}
		forval i=1/3{
			replace car_start=`car0_`i'' in `i'
			replace car_end=`car1_`i'' in `i'
			replace t1_start=`t10_`i'' in `i'
			replace t1_end=`t11_`i'' in `i'
			replace npl_start=`npl0_`i'' in `i'
			replace npl_end=`npl1_`i'' in `i'
			replace credit_loss_cap=`cl_`i'' in `i'
			replace market_loss_cap=`ml_`i'' in `i'
			replace net_income_cap=`ni_`i'' in `i'
			replace credit_share=100*`cl_`i''/(`cl_`i''+max(`ml_`i'',0)) in `i'
			replace banks_car_below8=`fail_`i'' in `i'
		}
		gen str6 base_quarter=string(`base',"%tq")
		gen str6 end_quarter=string(`last',"%tq")
		gen banks=`nbanks'
		export excel using "$xls", sheet("Summary", replace) firstrow(variables)
		list scenario car_start car_end npl_end credit_loss_cap market_loss_cap net_income_cap banks_car_below8, clean noobs

		* Assumptions used in this run
		clear
		set obs 10
		gen str60 parameter=""
		gen double value=.
		local k=0
		foreach p in payout k_stress npl_b0 npl_b1 w_srbi D_sbn e_prop{
			local ++k
			replace parameter="`p'" in `k'
			replace value=${`p'} in `k'
		}
		replace parameter="tax_rate" in 8
		replace value=$tax_rate in 8
		replace parameter="base quarter (last actual)" in 9
		replace value=`base' in 9
		replace parameter="forecast quarters" in 10
		replace value=`last'-`base' in 10
		export excel using "$xls", sheet("Assumptions", replace) firstrow(variables)
	restore
	di "Excel summary written to $xls"

*****************************
********** FIX LOG **********
*****************************
* Relative to archive/old_script/dofile_old.do:
*  1. Paths point to the project's input/, intermediate/fixed/, output/fixed/ folders.
*  2. Bank variables named from BQL labels (old rename left truncated names used via abbreviation).
*  3. merge m:m -> m:1 (KBMI and macro scenarios); unmatched KBMI rows no longer added.
*  4. Starting ratios from the last actual quarter / last 4 quarters, not the 2014-2026 bank average
*     (removed jumps in loans, deposits, interest and non-interest income at the forecast start).
*  5. Non-interest income/expense grow with assets instead of staying flat.
*  6. Policy-rate change added to QUARTERLY lending/saving rates divided by 4.
*  7. RWA grows with the scenario's own nominal GDP (was baseline GDP in every scenario).
*  8. Quarterly growth (1+g)^(1/4)-1 instead of g/4.
*  9. NPL: model and forecast rule unchanged (dynamic FE, u_i carried forward); floor at 0;
*     clustered SEs replace a 10-rep bootstrap. NPL breaks (nbrk) are flagged and excluded from
*     the NPL fit chart only.
* 10. Securities: mis-scaled Bloomberg values (> total assets) replaced by the KBMI median;
*     FVTPL losses through P&L, FVOCI losses through OCI (capital, untaxed).
* 11. History shows reported net income; industry charts use aggregated (weighted) ratios;
*     no hard-coded dates; lgraph (ssc) no longer needed.
* 12. Failure = CAR below the minimum in ANY forecast quarter (forecast quarters only).
* Model change (12 Oct 2026, not a fix):
* 13. Judgmental property-price term in NPL ($e_prop = -0.429, Prospera's summed elasticity, evenly over
*     lags 1-4), added as a static component on top of the dynamic NPL core. Set $e_prop 0 to switch off.
