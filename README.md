# Indonesian Banking Solvency Stress Test

Top-down, bank-level solvency stress test of 46 listed Indonesian banks, following
the Prospera *Banking Stress Test Handbook*. Base quarter **2026Q2**, horizon **4 quarters**,
scenarios **Baseline / Adverse 1 / Adverse 2**.

Version history (original handbook do-file → current model, with results per version): see `CHANGELOG.md`.

## Folder structure

| Folder | Contents | Written by code? |
|---|---|---|
| `input/` | `Solvency ST.xlsx` (macro history, 3 scenarios, Parameters), `Stress Testing Manual - Excel Template.xlsx` (Bloomberg BQL bank data), `kbmi.dta` (bank classes); source files for the Parameters/scenario inputs: `Asset Market Updater - Stasis_011026.xlsx` (Bloomberg yields: SBN/UST 10Y) and `ownership/` (BI SRBI and DJPPR SBN ownership releases, used for `w_srbi`) | never |
| `input/reference/` | Handbook PDF, W5 training deck, original `dofile.do` | never |
| `intermediate/` | `bank_raw`, `bank_panel`, `macro`, `parameters`, satellite estimates (`est_*.ster`, `sat_coefs`, `bank_anchor`, `backtest`), `projection`, `industry_path` | yes |
| `output/tables/` | `stress_test_results.xlsx` (Summary, Industry_path, KBMI_path, Bank, Failed_banks, Assumptions), `satellite_models.xlsx` | yes |
| `output/figures/` | industry CAR / T1 / NPL / ROA, loss composition, CAR by KBMI, bank CAR scatter, NPL back-test, macro scenarios | yes |
| `output/logs/` | full run log | yes |
| `script/` | `00_master.do` → `01_import` → `02_prepare` → `03_satellite` → `04_projection` → `05_results` | — |

`archive/Stata/` and `archive/Result/` are the original materials (old do-file outputs,
backups, earlier charts), kept for reference; the pipeline does not use them.

**Run the current model (v3):** in Stata, `do "script/dofile_fixed.do"` (run the whole file; close
`Solvency ST.xlsx` in Excel first). Edit `global base` at the top if the folder moves. It is the corrected
version of the earlier model (`archive/old_script/dofile_old.do`): same structure and model choices,
bugs fixed (FIX LOG at the end of the file). It writes to `intermediate/fixed/` and `output/fixed/`
(incl. `stress_test_summary.xlsx`).

**Alternative logit model (comparison only):** `do "script/00_master.do"` (edit `$root` if the folder
moves); outputs in `intermediate/` and `output/tables`, `output/figures`. `script/stress_test_full.do`
is the same model in a single file; it is a copy, so after editing any 01–05 file, regenerate it.
The folder table above and the Model section below describe this alternative model.
Settings (horizon, exclusions, pass-through, overlay switch, CAR threshold) sit at the top of
the master file; economic parameters (tax, payout, SRBI share, k_stress) are read from the
`Parameters` sheet.

## Model

1. **Scenarios.** GDP growth, BI rate, property prices, bond prices (Δprice = −D × ΔSBN 10Y yield).
2. **NPL.** Dynamic logit, bank fixed effects, asset-weighted:
   `logit(NPL)_t = a_i + 0.91·logit(NPL)_{t-1} − 0.006·GDP + 0.027·BI rate − 0.013·Δproperty` (4-quarter lag averages).
   The COVID restructuring window is dummied out, and reporting breaks are excluded.
   An 8-quarter out-of-sample back-test tracks industry NPL within ±0.08 pp.
3. **Provisions.** `prov/loans = c_i + 0.128·NPL + 0.141·ΔNPL` (quarterly, floored at 0).
   On top of this sits the stress overlay `k_stress × GDP gap vs baseline × NPL stock`.
4. **Market risk.** Securities (FVTPL + FVOCI) × (1 − SRBI share) × bond-price change.
   FVTPL losses go through P&L and FVOCI losses through OCI.
5. **P&L.**
   - NII = trailing NIM × assets + (loans − deposits) × ΔBI rate / 4.
   - Non-interest income and expense are held at trailing ratios to assets.
   - Tax is 22% on profits; dividends are a 50% payout of profits.
6. **Capital.** Capital = previous capital + retained earnings − OCI losses. The balance sheet and RWA grow with quarterly-ised GDP.
   **A bank fails if CAR < 8%.**

### Corrections relative to the original `dofile.do`

| Issue | Original | Now |
|---|---|---|
| GDP growth per quarter | used year-on-year growth as quarterly growth (~5% per quarter) | (1+g)^¼ − 1 |
| RWA growth | baseline GDP in every scenario | the scenario's own GDP |
| Policy-rate pass-through | annual rate change added to quarterly yields | divided by 4 |
| Provisions | % of loans in estimation, % of assets in the P&L | loans in both |
| Securities loss | used the change of a change, applied to a ratio | % price change applied to an amount |
| Dividends | none | 50% payout |
| Macro merge | `merge m:m` | `m:1` |
| Outlier exclusion | `bank_id==7` | by ticker |
| Chart dates | hard-coded | derived from the data |

## Key caveats

- The bank data come from the `Output Sheet (Copy)` snapshot. `Output Sheet` holds BQL
  formulas that only refresh on a Bloomberg Terminal.
- Six banks report securities larger than total assets (BACA, BBYB, BNBA, BTPS, BVIC, MCOR).
  These are unit errors, so the KBMI median share is used for them.
- BINA and BCIC fail mainly through market losses, because their reported MTM securities are
  66–70% of assets. Verify these against their financial statements before drawing conclusions.
- NPL macro elasticities are modest (persistence dominates). The stress severity therefore
  depends materially on the `k_stress` overlay. Turn it off with `use_overlay 0` for a pure-model run.
