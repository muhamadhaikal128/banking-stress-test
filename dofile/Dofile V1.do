*****************************
****** Global Settings ******
*****************************

* 	Notes: The first phase is to determine global paths. We define the path for data source, Stata storage, and results storage.
*	Paths below are set for Haikal's computer. Do not put "//" comments at the end of "global" lines (causes r(198) if no space before "//").

global base "C:\Users\LENOVO05\OneDrive\Desktop\20260827_0301060601_W5_Banking Stress Test Materials (1)\20260827_0301060601_W5_Banking Stress Test Materials"

* Raw macro data (Solvency ST.xlsx)
global source "$base\Stata"
* Raw bank data (Stress Testing Manual - Excel Template.xlsx)
global bql "$base\Stata"
* Stata data results (macro.dta, kbmi.dta, bank.dta, etc.)
global data "$base\Stata"
* Stress test results
global results "$base\Result"

cap mkdir "$results"

cap ssc install lgraph, replace

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

* 	Notes: The second phase is to import macroeconomic data, macroeconomic scenarios, and bank-level data from excel raw data into Stata format (dta).

*1.	Macroeconomic data
	* Import macroeconomic data
	import excel "$source\Solvency ST.xlsx", sheet("Macro") firstrow case(lower) clear
	format quarter %tq
	save "$data\macro.dta", replace

*2.	Macroeconomic scenario
	forval i=1/3{
		* Import stress test macro scenario
		import excel "$source\Solvency ST.xlsx", sheet("Scenario `i'") case(lower) firstrow clear
		save "$data\scen`i'.dta", replace
		use "$data\macro.dta", clear
		append using "$data\scen`i'.dta"
		gen ln_forex=log(forex)
		save "$data\comb`i'.dta", replace
	}

*3.	Bank-level data
	import excel "$bql\Stress Testing Manual - Excel Template.xlsx", sheet("Output Sheet (Copy)") firstrow case(lower) clear
	rename *fill* *
	rename is_*_benefit* is_*_benefit

	rename bs_sh_out dates
	gen quarter = qofd(dates)
	format quarter %tq
	drop if quarter == .

	cap rename a id
	gen bank = substr(id, 1, 4)
	bys bank quarter: gen dup = cond(_N==1, 0, _n)
	drop if dup > 1
	isid bank quarter
	drop dup

	merge m:m bank using "$data\kbmi.dta"
	drop if _merge == 1
	drop _merge

	encode bank, gen(bank_id)
	xtset bank_id quarter

	* temporary command, to exclude outlier
	drop if bank == "BANK"
	* MCOR: simulated interest expense ~9x interest income (saving_r data issue) -> spurious failure
	drop if bank == "MCOR"

	tsfill, full
	decode bank_id, generate(bank2)
	replace bank = bank2
	drop bank2
	replace id = bank + " IJ Equity" if id == ""

	order bank bank_id quarter *
	drop if quarter < tq(2010q1)

	foreach i of varlist _all {
		local lab: var label `i'
		if strmatch("`lab'", "*(fill=*") == 1 {
			local newlab = strupper("`i'")
			la var `i' "`newlab'"
		}
	}

	la var dates "Date"
	la var bank_id "Bank Ticker"

	save "$data\bank.dta", replace


*****************************
****** NPL Forecasting ******
*****************************

use "$data\bank.dta", clear

egen max=max(quarter)
format max %tq
label variable max "Maximum period"
* need to add more for higher time horizon of forcasting
tsappend, add(4)
replace max=l.max if max==.
gen year=yofd(dofq(quarter))
label variable year "Year"
xtset bank_id quarter

gen npl_r=bs_non_perform_loans/bs_tot_loan*100
label variable npl_r "NPL ratio"

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

gen c_loan_r=bs_tot_loan/bs_tot_asset*100
gen c_dep_r=bs_customer_deposits/bs_tot_asset*100
gen c_nii_r=non_int_inc/bs_tot_asset*100
gen c_nie_r=non_int_exp/bs_tot_asset*100
foreach j in loan_r dep_r nii_r nie_r{
	egen `j'=mean(c_`j'), by(bank_id)
	drop c_`j'
}

gen c_lending_r=is_int_inc/bs_tot_loan*100
egen lending_r=mean(c_lending_r), by(bank_id)
label variable lending_r "Lending rate"
gen c_saving_r=(is_int_inc-net_int_inc)/bs_customer_deposits*100
replace c_saving_r=0 if c_saving_r<0
egen saving_r=mean(c_saving_r), by(bank_id)
label variable saving_r "Saving rate"
foreach j in lending_r saving_r{
	replace `j'=. if quarter>max
	drop c_`j'
}

gen afs_r=av_sa_fa_at_fv_thru_ot_comp_inc/bs_tot_loan*100
la var afs_r "AFS securities to assets"
gen tra_r=trading_secs_fa_at_fv_thru_pl/bs_tot_loan*100
la var tra_r "Trading securities to assets"
egen sec_r=rowtotal(afs_r tra_r), missing
replace sec_r=100 if sec_r>100 & !missing(sec_r)
* no reported AFS/trading securities -> treat as zero (otherwise the bank drops out of the forecast)
replace sec_r=0 if missing(sec_r) & quarter<=max
la var sec_r "Tradeable securities to assets"

* TAX RATE ASSUMPTIONS ($tax_rate from Solvency ST.xlsx, sheet Parameters)
gen tax_rate=$tax_rate
la var tax_rate "Tax rate"

* Other assumptions are read from Solvency ST.xlsx, sheet Parameters (see Global Settings):
*   payout   - dividend payout on positive profit (losses hit capital in full)
*   w_srbi   - SRBI share of bank securities = (bank SRBI + SRBI repo) / (that + bank SBN), computed in
*              Excel from BI (Ownership of SRBI) and DJPPR (Kepemilikan SBN) inputs. FVOCI + trading
*              balances exceed banks' total SBN holdings, so they also contain SRBI; SRBI is treated as
*              held to maturity (no MTM loss), so only the SBN share is revalued.
*   D_sbn    - modified duration of the SBN book (priced off the SBN 10Y yield)
*   k_stress - stress provision add-on: k x (baseline GDP - scenario GDP, pp) x bank NPL stock, per
*              quarter. Calibrated so Adverse 2 cumulative credit loss ~ 2021 peak (11.5% of capital);
*              the estimated NPL/provision models alone gave ~4.8% (a normal year), since front-loaded
*              PSAK 71 / COVID reserves bias the regressions down. Baseline gets no add-on (gap = 0).
save "$data\bank.dta", replace

*****************************
******** Simulations ********
*****************************

use "$data\bank.dta", clear

xtset bank_id quarter

forval i=1/3{

	*Obtaining scenario*
	merge m:m quarter using "$data\comb`i'.dta", force
	keep if _merge==3
	drop _merge
	foreach j in gdp reporate cpi forex d_property ln_forex d_price ust10y sbn10y{
		gen `j'_b`i'=`j'
	}
	sort bank_id quarter
	xtset bank_id quarter
	* securities price change (%): only the SBN share is marked to market (SRBI held to maturity);
	* overrides the sheet's d_price
	replace d_price_b`i'=-(1-$w_srbi)*$D_sbn*d.sbn10y_b`i'

	*B/S calculations*
	gen asset_b`i'=bs_tot_asset
	* balance sheet grows with nominal GDP: (real yoy growth + CPI inflation), converted to a quarterly rate
	bys bank_id (quarter): replace asset_b`i'=asset_b`i'[_n-1] * (1+(gdp+cpi)/400) if missing(asset_b`i') & quarter>max
	label variable asset_b`i' "Bank assets scenario `i'"

	gen rwa_b`i'=bs_risk_weighted_assets
	bys bank_id (quarter): replace rwa_b`i'=rwa_b`i'[_n-1] * (1+(gdp_b1+cpi_b1)/400) if missing(rwa_b`i') & quarter>max
	label variable rwa_b`i' "RWA scenario `i'"

	gen size_b`i'=log(asset_b`i')
	label variable size_b`i' "Bank size scenario `i'"

	gen loan_b`i'=loan_r/100*asset_b`i'
	label variable loan_b`i' "Bank loans scenario `i'"

	gen dep_b`i'=dep_r/100*asset_b`i'
	label variable dep_b`i' "Bank deposits scenario `i'"

	gen sec_b`i'=sec_r
	label variable sec_b`i' "Bank securities scenario `i'"

	bys bank_id (quarter): replace sec_b`i'=sec_b`i'[_n-1] if missing(sec_b`i') & quarter>max

	gen nii_b`i'=non_int_inc
	replace nii_b`i'=l.nii_b`i' if missing(nii_b`i') & quarter>max

	gen nie_b`i'=non_int_exp
	replace nie_b`i'=l.nie_b`i' if missing(nie_b`i') & quarter>max

	*NPL modelling and forecasting*
	* dynamic FE model: lagged NPL + GDP + BI rate. Property dropped: IHPR never fell in-sample
	* (min d_property +0.04), so its coefficient has the wrong sign and adverse shocks lowered NPL.
	gen npl_b`i'=npl_r
	qui xi: xtreg npl_b`i' l.npl_b`i' l.gdp l2.gdp l3.gdp l4.gdp l.reporate l2.reporate l3.reporate l4.reporate, fe vce(bootstrap, rep(10) seed(1234))
	* recursive forecast: each quarter uses the previous quarter's forecast NPL
	* (xbu is only defined in-sample, so carry each bank's fixed effect u_i forward explicitly)
	predict double npl_u, u
	bys bank_id: egen double npl_ui=max(npl_u)
	qui sum quarter
	forval q=`=max[1]+1'/`r(max)'{
		predict double npl_tmp, xb
		replace npl_b`i'=npl_tmp+npl_ui if quarter==`q'
		drop npl_tmp
	}
	drop npl_u npl_ui
	predict npl_i`i', xb

	label variable npl_b`i' "NPL ratio scenario `i'"

	*Provision forecasting*
	* provision/loans = bank's normal credit cost (avg of last 8 quarters)
	*                 + estimated response to NPL increases this quarter and last quarter ($npl_b0, $npl_b1)
	gen prov_b`i'=prov_r
	bys bank_id: egen prov_base`i'=mean(cond(quarter>max-8 & quarter<=max, prov_r, .))
	egen prov_med`i'=median(prov_base`i')
	replace prov_base`i'=prov_med`i' if missing(prov_base`i')
	replace prov_b`i'=prov_base`i' + $npl_b0*max(npl_b`i'-l.npl_b`i',0) + $npl_b1*max(l.npl_b`i'-l2.npl_b`i',0) if quarter>max
	replace prov_b`i'=0 if prov_b`i'<0 & quarter>max
	replace prov_b`i'=prov_b`i' + $k_stress*max(gdp_b1-gdp,0)*npl_b`i' if quarter>max
	label variable prov_b`i' "Bank provisions scenario `i'"
	drop prov_base`i' prov_med`i'

	*Losses from tradeable securities*
	* d_price = % price change of securities = -duration x change in SBN 10Y yield (Solvency ST.xlsx)
	* sec_b is securities to loans (%), so convert to an amount before applying the price change
	gen sec_amt_b`i'=sec_b`i'/100*loan_b`i'
	gen loss_b`i'=-(d_price_b`i'/100)*sec_amt_b`i'
	label variable loss_b`i' "Losses from securities transactions"
	gen loss_r_b`i'=loss_b`i'/loan_b`i'*100
	label variable loss_r_b`i' "Securities losses to loans scenario `i'"


	*I/S calculations*
	gen lending_r_b`i'=lending_r
	bys bank_id (quarter): replace lending_r_b`i'=lending_r_b`i'[_n-1] + d.reporate if missing(lending_r_b`i') & quarter>max

   *egen saving_r_b`i'=mean(saving_r), by(bank_id)
	gen saving_r_b`i'=saving_r
	bys bank_id (quarter): replace saving_r_b`i'=saving_r_b`i'[_n-1] + d.reporate if missing(saving_r_b`i') & quarter>max

	gen int_inc_b`i'=lending_r_b`i'/100*loan_b`i'
	gen int_exp_b`i'=saving_r_b`i'/100*dep_b`i'

	gen nim_b`i'=(int_inc_b`i'-int_exp_b`i')/asset_b`i'

	gen ebt_b`i'=int_inc_b`i' - int_exp_b`i'+ nii_b`i' - nie_b`i' - (prov_b`i'/100)*loan_b`i' - loss_b`i'
	gen tax_b`i'=ebt_b`i'*tax_rate
	replace tax_b`i'=0 if tax_b`i'<0
	gen eat_b`i'=ebt_b`i'-tax_b`i'

	*CAR calculations*
	gen tier1_b`i'=bs_tier1_capital
	gen ret_b`i'=cond(eat_b`i'>0, (1-$payout)*eat_b`i', eat_b`i') if !missing(eat_b`i')
	label variable ret_b`i' "Retained earnings scenario `i'"
	replace tier1_b`i'=l.tier1_b`i'+ret_b`i' if quarter>max
	label variable tier1_b`i' "Tier 1 capital scenario `i'"
	gen cap_b`i'=bs_tot_cap_fund
	replace cap_b`i'=l.cap_b`i'+ret_b`i' if quarter>max
	label variable cap_b`i' "Regulatory capital scenario `i'"

	gen t1r_b`i'=tier1_b`i'/rwa_b`i'*100
	label variable t1r_b`i' "Tier 1 ratio scenario `i'"
	gen car_b`i'=cap_b`i'/rwa_b`i'*100
	label variable car_b`i' "CAR scenario `i'"

	drop gdp reporate cpi forex property d_property ln_forex d_price ust10y sbn10y
}

replace npl_i3=npl_r if quarter>max
rename npl_i3 npl_i
label variable npl_i "Predicted NPL"
lgraph npl_r npl_i quarter if year>2011 & year<2023, wide ytitle("NPL (%)") xtitle("Quarter") legend(pos(6) row(1) size(small))
graph export "$results\npl_predict.png", as(png) name("Graph") replace

lgraph loss_r_b1 loss_r_b2 loss_r_b3 quarter, wide ytitle("Losses from MTM securities to loans (%)") xtitle("Quarter") legend(order(1 "Scenario 1" 2 "Scenario 2" 3 "Scenario 3") pos(6) row(1) size(small)) xline(264, lcolor(maroon) lpattern(shortdash))
graph export "$results\securities.png", as(png) name("Graph") replace

preserve
forval x=1/3{
	graph bar prov_b`x' loss_r_b`x' if quarter>=265, stack over(quarter, relabel(1 "2026Q2" 2 "2026Q3" 3 "2026Q4" 4 "2027Q1" 5 "2027Q2")) legend(order(1 "Credit losses" 2 "Market losses") pos(6) row(1) size(medium)) ytitle("Losses to total loans (%)") title("Scenario `x'")
	* need to periodically change the date
	graph save "$results\comp_`x'.gph", replace
}
graph combine "$results\comp_1.gph" "$results\comp_2.gph"  "$results\comp_3.gph" , iscale(0.5) row(1)
graph export "$results\composition.png", as(png) name("Graph") replace
restore
save "$data\bank.dta", replace

*****************************
********** Results **********
*****************************

	drop if year<2014

*1.	Industry results

	* NPL forecast
	lgraph npl_b1 npl_b2 npl_b3 quarter, wide ytitle("Industry NPL (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) xline(266, lcolor(maroon) lpattern(shortdash))
	graph export "$results\npl_scenario.png", as(png) name("Graph") replace

	* Provisions forecast
	lgraph prov_b1 prov_b2 prov_b3 quarter, wide ytitle("Industry provisions (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) xline(266, lcolor(maroon) lpattern(shortdash))
	graph export "$results\prov_scenario.png", as(png) name("Graph") replace

	preserve
		collapse (sum) rwa_b1 rwa_b2 rwa_b3 tier1_b1 tier1_b2 tier1_b3 cap_b1 cap_b2 cap_b3 eat_b1 eat_b2 eat_b3 asset_b1 asset_b2 asset_b3, by(quarter)
		forval i=1/3{
			* CAR forecast
			gen car_`i'=cap_b`i'/rwa_b`i'*100
			label variable car_`i' "CAR scenario `i'"
			* Tier 1 Capital forecast
			gen tr1_`i'=tier1_b`i'/rwa_b`i'*100
			label variable tr1_`i' "Tier 1 capital ratio scenario `i'"
			* Net income forecast
			gen eat_`i'=eat_b`i'/asset_b`i'*100
			label variable eat_`i' "Net income to assets scenario `i'"
		}

		lgraph car_1 car_2 car_3 quarter, wide ytitle("CAR (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) xline(266, lcolor(maroon) lpattern(shortdash))
		graph export "$results\car_scenario.png", as(png) name("Graph") replace
		lgraph tr1_1 tr1_2 tr1_3 quarter, wide ytitle("Tier 1 Capital (%)") xtitle("Quarter") legend(pos(6) row(1) size(small))	xline(266, lcolor(maroon) lpattern(shortdash))
		graph export "$results\tr1_scenario.png", as(png) name("Graph") replace
		lgraph eat_1 eat_2 eat_3 quarter, wide ytitle("Net income (%)") xtitle("Quarter") legend(pos(6) row(1) size(small))	xline(266, lcolor(maroon) lpattern(shortdash))
		graph export "$results\eat_scenario.png", as(png) name("Graph") replace
	restore

*2.	BUKU results

	bys bank_id (quarter): replace kbmi=kbmi[_n-1] if missing(kbmi)

	forval b=1/4{
		lgraph npl_b1 npl_b2 npl_b3 quarter if kbmi==`b', wide ytitle("NPL (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) title("BUKU `b'") xline(266, lcolor(maroon) lpattern(shortdash))
		graph save "$results\npl_scenario_kbmi`b'.gph", replace
		preserve
			keep if kbmi==`b'
			collapse (sum) rwa_b1 rwa_b2 rwa_b3 tier1_b1 tier1_b2 tier1_b3 cap_b1 cap_b2 cap_b3 eat_b1 eat_b2 eat_b3 asset_b1 asset_b2 asset_b3, by(quarter)
			forval i=1/3{
				* CAR forecast
				gen car_`i'=cap_b`i'/rwa_b`i'*100
				label variable car_`i' "CAR scenario `i'"
				* Tier 1 Capital forecast
				gen tr1_`i'=tier1_b`i'/rwa_b`i'*100
				label variable tr1_`i' "Tier 1 capital ratio scenario `i'"
				* Net income forecast
				gen eat_`i'=eat_b`i'/asset_b`i'*100
				label variable eat_`i' "Net income to assets scenario `i'"
			}

			lgraph car_1 car_2 car_3 quarter, wide ytitle("CAR (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) title("BUKU `b'") xline(266, lcolor(maroon) lpattern(shortdash))
			graph save "$results\car_scenario_kbmi`b'.gph", replace
			lgraph tr1_1 tr1_2 tr1_3 quarter, wide ytitle("Tier 1 Capital (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) title("BUKU `b'") xline(266, lcolor(maroon) lpattern(shortdash))
			graph save "$results\tr1_scenario_kbmi`b'.gph", replace
			lgraph eat_1 eat_2 eat_3 quarter, wide ytitle("Net income (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) title("BUKU `b'") xline(266, lcolor(maroon) lpattern(shortdash))
			graph save "$results\eat_scenario_kbmi`b'.gph", replace
		restore
	}

	graph combine "$results\npl_scenario_kbmi1.gph" "$results\npl_scenario_kbmi2.gph"  "$results\npl_scenario_kbmi3.gph"  "$results\npl_scenario_kbmi4.gph", iscale(0.5)
	graph export "$results\npl_kbmi.png", as(png) name("Graph") replace
	graph combine "$results\car_scenario_kbmi1.gph" "$results\car_scenario_kbmi2.gph"  "$results\car_scenario_kbmi3.gph"  "$results\car_scenario_kbmi4.gph", iscale(0.5)
	graph export "$results\car_kbmi.png", as(png) name("Graph") replace
	graph combine "$results\tr1_scenario_kbmi1.gph" "$results\tr1_scenario_kbmi2.gph"  "$results\tr1_scenario_kbmi3.gph"  "$results\tr1_scenario_kbmi4.gph", iscale(0.5)
	graph export "$results\tr1_kbmi.png", as(png) name("Graph") replace
	graph combine "$results\eat_scenario_kbmi1.gph" "$results\eat_scenario_kbmi2.gph"  "$results\eat_scenario_kbmi3.gph"  "$results\eat_scenario_kbmi4.gph", iscale(0.5)
	graph export "$results\eat_kbmi.png", as(png) name("Graph") replace

*3.	Failed banks

	preserve
		forval i=1/3{
			gen fail_`i'=cond(1,car_b`i'<8 & quarter>=max,0)
			egen fail_b`i'=max(fail_`i'),by(bank_id)
			qui count if fail_b`i'==1
			if r(N)==0 {
				di "Scenario `i': no bank with CAR < 8%"
				continue
			}
			xtline car_b`i' if fail_b`i'==1
			graph save "$results\fail_bank_scenario`i'.gph", replace
			graph export "$results\fail_bank_scenario`i'.png", as(png) name("Graph") replace
		}
	restore

*****************************
********** Presentation *****
*****************************

*1 Presentation Data

	preserve
		gen eat_3 = eat_b3/asset_b3*100

		collapse (sum)	tier1_b* rwa_b* cap_b* npl_b* npl_r, by(quarter)
		gen tr1_1 = tier1_b1/rwa_b1*100
		gen tr1_2 = tier1_b2/rwa_b2*100
		gen tr1_3 = tier1_b3/rwa_b3*100
		gen car_1 = cap_b1/rwa_b1*100
		gen car_2 = cap_b2/rwa_b2*100
		gen car_3 = cap_b3/rwa_b3*100
	restore

*2 Excel summary (overwritten on every run): $results\stress_test_summary.xlsx
*  Industry figures use banks with a full forecast in all scenarios. Losses are cumulative over
*  the forecast horizon, in % of starting (last actual quarter) regulatory capital.

	global xls "$results\stress_test_summary.xlsx"
	cap erase "$xls"

	use "$data\bank.dta", clear
	xtset bank_id quarter
	bys bank_id (quarter): replace bank=bank[_n-1] if bank==""
	bys bank_id (quarter): replace kbmi=kbmi[_n-1] if missing(kbmi)
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
		* cumulative figures for the summary sheet
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

	* Bank level: CAR at start and end of horizon, cumulative losses in % of own starting capital
	preserve
		bys bank_id (quarter): gen cap0=cap_b1[1]
		bys bank_id (quarter): gen car_start=car_b1[1]
		bys bank_id (quarter): gen npl_start=npl_r[1]
		bys bank_id (quarter): gen sec_cap=sec_r[1]/100*bs_tot_loan[1]/cap0*100
		forval i=1/3{
			bys bank_id (quarter): egen cum_cl`i'=total(cond(quarter>`base', cl_b`i', .))
			bys bank_id (quarter): egen cum_ml`i'=total(cond(quarter>`base', loss_b`i', .))
		}
		keep if quarter==`last'
		forval i=1/3{
			gen credit_loss_cap_s`i'=cum_cl`i'/cap0*100
			gen market_loss_cap_s`i'=cum_ml`i'/cap0*100
			rename car_b`i' car_end_s`i'
		}
		keep bank kbmi car_start car_end_s* npl_start sec_cap credit_loss_cap_s* market_loss_cap_s*
		order bank kbmi car_start car_end_s1 car_end_s2 car_end_s3 npl_start sec_cap credit_loss_cap_s* market_loss_cap_s*
		sort car_end_s3
		forval i=1/3{
			qui count if car_end_s`i'<8
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

		* Assumptions used in this run
		clear
		set obs 9
		gen str60 parameter=""
		gen double value=.
		local k=0
		foreach p in payout k_stress npl_b0 npl_b1 w_srbi D_sbn{
			local ++k
			replace parameter="`p'" in `k'
			replace value=${`p'} in `k'
		}
		replace parameter="tax_rate" in 7
		replace value=$tax_rate in 7
		replace parameter="base quarter (last actual)" in 8
		replace value=`base' in 8
		replace parameter="forecast quarters" in 9
		replace value=`last'-`base' in 9
		export excel using "$xls", sheet("Assumptions", replace) firstrow(variables)
	restore
	di "Excel summary written to $xls"

