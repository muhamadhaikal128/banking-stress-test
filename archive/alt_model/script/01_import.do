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
