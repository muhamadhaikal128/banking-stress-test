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
