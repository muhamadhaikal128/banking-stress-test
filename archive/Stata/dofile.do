*****************************
****** Global Settings ******
*****************************

* 	Notes: The first phase is to determine global paths. We define the path for data source, Stata storage, and results storage.

	global source 	"Z:\Shared\PROSPERA\Finance\BT.2.2_Finance Policy Team\00. Activities\11. Team Activities\g. Data Master File"
							// Select path for raw macro data source

	global bql 		"Z:\Shared\PROSPERA\Bloomberg\Finance"
							// Select path for raw bank data from Bloomberg Terminal
	
	global data 	"Z:\Shared\PROSPERA\Finance\BT.2.2_Finance Policy Team\00. Activities\06. KSSK Meeting\a. Banking Surveillance and Stress Test\2024Q2\Stata"							// Select path for Stata data results
	
	global results 	"Z:\Shared\PROSPERA\Finance\BT.2.2_Finance Policy Team\00. Activities\06. KSSK Meeting\a. Banking Surveillance and Stress Test\2024Q2\Result"							// Select path for stress test results	
	
	cap ssc install lgraph, replace
	
*	For external users, please change the "source", "bql", "data" global macros to the "\Stata" folder and the "results" macro to the "\Result" folder provided within the archive.

*****************************
**** Raw Data Extraction ****
*****************************

* 	Notes: The second phase is to import macroeconomic data, macroeconomic scenarios, and bank-level data from excel raw data into Stata format (dta).

*1.	Macroeconomic data
	import excel "$source\Solvency ST.xlsx", sheet("Macro") firstrow case(lower) clear					// Import macroeconomic data
	format quarter %tq
	save "$data\macro.dta", replace

*2.	Macroeconomic scenario	
	forval i=1/3{
		import excel "$source\Solvency ST.xlsx", sheet("Scenario `i'") case(lower) firstrow clear		// Import stress test macro scenario
		save "$data\scen`i'.dta", replace
		use "$data\macro.dta", clear
		append using "$data\scen`i'.dta"
		gen ln_forex=log(forex)
		save "$data\comb`i'.dta", replace
	}

*3.	Bank-level data
	import excel "$bql\Stress Testing Manual - Excel Template.xlsx", sheet("Output Sheet") firstrow case(lower) clear
	rename *fill* *
	rename is_*_benefit* is_*_benefit

	rename bs_sh_out dates
	gen quarter = qofd(dates)
	format quarter %tq
	drop if quarter == .
	
	rename a id
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
	
	drop if bank_id == 7 //temporary command, to exclude outlier

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
tsappend, add(4) // need to add more for higher time horizon of forcasting
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
replace sec_r=100 if sec_r>100
la var sec_r "Tradeable securities to assets"

gen tax_rate=0.22 // TAX RATE ASSUMPTIONS
la var tax_rate "Tax rate"
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
	foreach j in gdp reporate cpi forex d_property ln_forex d_price{
		gen `j'_b`i'=`j'
	}
	sort bank_id quarter
	xtset bank_id quarter

	*B/S calculations*
	gen asset_b`i'=bs_tot_asset
	bys bank_id (quarter): replace asset_b`i'=asset_b`i'[_n-1] * (1+gdp/100) if missing(asset_b`i') & quarter>max
	label variable asset_b`i' "Bank assets scenario `i'"
	
	gen rwa_b`i'=bs_risk_weighted_assets
	bys bank_id (quarter): replace rwa_b`i'=rwa_b`i'[_n-1] * (1+gdp_b1/100) if missing(rwa_b`i') & quarter>max
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
	qui xi: xtreg npl_r l.gdp l2.gdp l3.gdp l4.gdp l.reporate l2.reporate l3.reporate l4.reporate l.d_property l2.d_property l3.d_property l4.d_property, fe vce(bootstrap, rep(10) seed(1234))
	predict npl_b`i', xbu
	predict npl_i`i', xb
	gen d_npl_i`i'=d.npl_i`i'
	replace npl_b`i'=l.npl_b`i'+d_npl_i`i' if npl_b`i'==.
	
	label variable npl_b`i' "NPL ratio scenario `i'"
	replace npl_b`i'=npl_r if quarter<=max
	
	*Provision modelling and forecasting*
	qui xi: xtreg prov_r l2.npl_b`i' l.npl_b`i' npl_b`i' size_b`i' l.reporate_b`i' reporate_b`i', fe vce(bootstrap, rep(10) seed(1234))
	predict prov_b`i', xbu
	label variable prov_b`i' "Bank provisions scenario `i'"
	predict prov_i`i', xb
	gen d_prov_i`i'=d.prov_i`i'
	replace prov_b`i'=l.prov_b`i'+d_prov_i`i' if quarter>max
	
	*Losses from tradeable securities*
	gen loss_b`i'=d.d_price_b`i'/10000*sec_b`i'
	label variable loss_b`i' "Losses from securities transactions"
	
	
	*I/S calculations*
	gen lending_r_b`i'=lending_r
	bys bank_id (quarter): replace lending_r_b`i'=lending_r_b`i'[_n-1] + d.reporate if missing(lending_r_b`i') & quarter>max
	
   *egen saving_r_b`i'=mean(saving_r), by(bank_id)
	gen saving_r_b`i'=saving_r
	bys bank_id (quarter): replace saving_r_b`i'=saving_r_b`i'[_n-1] + d.reporate if missing(saving_r_b`i') & quarter>max
	
	gen int_inc_b`i'=lending_r_b`i'/100*loan_b`i'
	gen int_exp_b`i'=saving_r_b`i'/100*dep_b`i'
	
	gen nim_b`i'=(int_inc_b`i'-int_exp_b`i')/asset_b`i'
	
	gen ebt_b`i'=int_inc_b`i' - int_exp_b`i'+ nii_b`i' - nie_b`i' - (prov_b`i'/100)*asset_b`i' - loss_b`i'
	gen tax_b`i'=ebt_b`i'*tax_rate
	replace tax_b`i'=0 if tax_b`i'<0
	gen eat_b`i'=ebt_b`i'-tax_b`i'
	
	*CAR calculations*
	gen tier1_b`i'=bs_tier1_capital
	replace tier1_b`i'=l.tier1_b`i'+eat_b`i' if quarter>max
	label variable tier1_b`i' "Tier 1 capital scenario `i'"
	gen cap_b`i'=bs_tot_cap_fund
	replace cap_b`i'=l.cap_b`i'+eat_b`i' if quarter>max
	label variable cap_b`i' "Regulatory capital scenario `i'"
	
	gen t1r_b`i'=tier1_b`i'/rwa_b`i'*100
	label variable t1r_b`i' "Tier 1 ratio scenario `i'"
	gen car_b`i'=cap_b`i'/rwa_b`i'*100
	label variable car_b`i' "CAR scenario `i'"
	
	drop d_npl_i`i' prov_i`i' d_prov_i`i' gdp reporate cpi forex property d_property ln_forex d_price
}

replace npl_i3=npl_r if quarter>max
rename npl_i3 npl_i
label variable npl_i "Predicted NPL"
lgraph npl_r npl_i quarter if year>2011 & year<2023, wide ytitle("NPL (%)") xtitle("Quarter") legend(pos(6) row(1) size(small))
graph export "$results\npl_predict.png", as(png) name("Graph") replace

lgraph loss_b1 loss_b2 loss_b3 quarter, wide ytitle("Losses from MTM securities (%)") xtitle("Quarter") legend(order(1 "Scenario 1" 2 "Scenario 2" 3 "Scenario 3") pos(6) row(1) size(small)) xline(256, lcolor(maroon) lpattern(shortdash))
graph export "$results\securities.png", as(png) name("Graph") replace

preserve
forval x=1/3{
	replace loss_b`x'=-loss_b`x'
	graph bar prov_b`x' loss_b`x' if quarter>=257, stack over(quarter, relabel(1 "2024Q2" 2 "2024Q3" 3 "2024Q4" 4 "2025Q1" 5 "2025Q2")) legend(order(1 "Credit losses" 2 "Market losses") pos(6) row(1) size(medium)) ytitle("Losses to total assets (%)") title("Scenario `x'")
	graph save "$results\comp_`x'.gph", replace // need to periodically change the date  
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

	lgraph npl_b1 npl_b2 npl_b3 quarter, wide ytitle("Industry NPL (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) xline(258, lcolor(maroon) lpattern(shortdash))					// NPL forecast
	graph export "$results\npl_scenario.png", as(png) name("Graph") replace

	lgraph prov_b1 prov_b2 prov_b3 quarter, wide ytitle("Industry provisions (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) xline(258, lcolor(maroon) lpattern(shortdash))		// Provisions forecast
	graph export "$results\prov_scenario.png", as(png) name("Graph") replace

	preserve
		collapse (sum) rwa_b1 rwa_b2 rwa_b3 tier1_b1 tier1_b2 tier1_b3 cap_b1 cap_b2 cap_b3 eat_b1 eat_b2 eat_b3 asset_b1 asset_b2 asset_b3, by(quarter)
		forval i=1/3{
			gen car_`i'=cap_b`i'/rwa_b`i'*100																																				// CAR forecast
			label variable car_`i' "CAR scenario `i'"
			gen tr1_`i'=tier1_b`i'/rwa_b`i'*100																																				// Tier 1 Capital forecast
			label variable tr1_`i' "Tier 1 capital ratio scenario `i'"
			gen eat_`i'=eat_b`i'/asset_b`i'*100																																				// Net income forecast
			label variable eat_`i' "Net income to assets scenario `i'"
		}
		
		lgraph car_1 car_2 car_3 quarter, wide ytitle("CAR (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) xline(258, lcolor(maroon) lpattern(shortdash))	
		graph export "$results\car_scenario.png", as(png) name("Graph") replace
		lgraph tr1_1 tr1_2 tr1_3 quarter, wide ytitle("Tier 1 Capital (%)") xtitle("Quarter") legend(pos(6) row(1) size(small))	xline(258, lcolor(maroon) lpattern(shortdash))
		graph export "$results\tr1_scenario.png", as(png) name("Graph") replace
		lgraph eat_1 eat_2 eat_3 quarter, wide ytitle("Net income (%)") xtitle("Quarter") legend(pos(6) row(1) size(small))	xline(258, lcolor(maroon) lpattern(shortdash))
		graph export "$results\eat_scenario.png", as(png) name("Graph") replace
	restore

*2.	BUKU results

	bys bank_id (quarter): replace kbmi=kbmi[_n-1] if missing(kbmi)
	
	forval b=1/4{
		lgraph npl_b1 npl_b2 npl_b3 quarter if kbmi==`b', wide ytitle("NPL (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) title("BUKU `b'") xline(258, lcolor(maroon) lpattern(shortdash))
		graph save "$results\npl_scenario_kbmi`b'.gph", replace
		preserve
			keep if kbmi==`b'
			collapse (sum) rwa_b1 rwa_b2 rwa_b3 tier1_b1 tier1_b2 tier1_b3 cap_b1 cap_b2 cap_b3 eat_b1 eat_b2 eat_b3 asset_b1 asset_b2 asset_b3, by(quarter)
			forval i=1/3{
				gen car_`i'=cap_b`i'/rwa_b`i'*100																																			// CAR forecast
				label variable car_`i' "CAR scenario `i'"
				gen tr1_`i'=tier1_b`i'/rwa_b`i'*100																																			// Tier 1 Capital forecast
				label variable tr1_`i' "Tier 1 capital ratio scenario `i'"
				gen eat_`i'=eat_b`i'/asset_b`i'*100																																			// Net income forecast
				label variable eat_`i' "Net income to assets scenario `i'"
			}
			
			lgraph car_1 car_2 car_3 quarter, wide ytitle("CAR (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) title("BUKU `b'") xline(258, lcolor(maroon) lpattern(shortdash))
			graph save "$results\car_scenario_kbmi`b'.gph", replace
			lgraph tr1_1 tr1_2 tr1_3 quarter, wide ytitle("Tier 1 Capital (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) title("BUKU `b'") xline(258, lcolor(maroon) lpattern(shortdash))
			graph save "$results\tr1_scenario_kbmi`b'.gph", replace
			lgraph eat_1 eat_2 eat_3 quarter, wide ytitle("Net income (%)") xtitle("Quarter") legend(pos(6) row(1) size(small)) title("BUKU `b'") xline(258, lcolor(maroon) lpattern(shortdash))
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
	
