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
