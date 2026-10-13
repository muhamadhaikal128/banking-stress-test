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
