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
