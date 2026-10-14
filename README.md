# Indonesian Banking Solvency Stress Test

Top-down, bank-level solvency stress test of 46 listed Indonesian banks, following
the Prospera *Banking Stress Test Handbook*. Base quarter **2026Q2**, horizon **4 quarters**,
scenarios **Baseline / Adverse 1 / Adverse 2**.

Version history (original handbook do-file → current model, with results per version): see `CHANGELOG.md`.

## Run

In Stata: `do "script/dofile_fixed.do"`. Run the whole file as a do-file (not line by line or as
a selection), and close `Solvency ST.xlsx` in Excel first. Edit `global base` at the top if the folder moves.

Settings at the top of the do-file: `horizon`, `car_min`, `himbara` (bank list), `e_prop` (property
effect on NPL). Economic parameters (`tax_rate`, `payout`, `w_srbi`, `D_sbn`, `k_stress`, `beta_l`,
`beta_d`) are read from sheet `Parameters` of `Solvency ST.xlsx`.

## Folder structure

| Folder | Contents | Written by code? |
|---|---|---|
| `input/` | `Solvency ST.xlsx` (macro history, 3 scenarios, `Parameters`), `Stress Testing Manual - Excel Template.xlsx` (Bloomberg BQL bank data), `kbmi.dta` (bank classes), plus source files for the yield and ownership inputs (`Asset Market Updater …xlsx`, `ownership/`) | never |
| `input/reference/` | Handbook PDF, W5 training deck, original `dofile.do` | never |
| `script/` | `dofile_fixed.do`, the model | — |
| `intermediate/fixed/` | `bank.dta` (panel + projections), `macro`, `scen1-3`, `comb1-3` | yes |
| `output/fixed/` | `stress_test_summary.xlsx` and the figures below | yes |
| `archive/` | Original Prospera materials, older do-files and results, and the alternative logit model (`archive/alt_model/`, comparison only) | no (except `alt_model`, which writes only inside its own folder) |

### Outputs (`output/fixed/`)

| Item | Contents |
|---|---|
| `stress_test_summary.xlsx` | `Summary` (per scenario), `Industry_path`, `Group_summary` and `Group_path` (Himbara, Non-Himbara, KBMI 1–4), `Bank`, `Assumptions` |
| `1_macro/` | `macro_scenarios.png`: GDP, BI rate, property prices, SBN 10Y, as used by the model |
| `2_industry/` | CAR, Tier 1, NPL, net income (quarterly and annualised ROA), provisions, MTM losses, loss composition |
| `3_kbmi/` | CAR, NPL, Tier 1, net income by KBMI group |
| `4_himbara/` | The same four charts, Himbara vs Non-Himbara |
| `5_banks/` | `bank_car_adverse2.png` (start vs minimum CAR per bank), `fail_bank_scenario*.png` |
| `6_model_checks/` | `npl_predict.png` (in-sample fit), `npl_backtest.png` (8-quarter out-of-sample) |
| `gph/` | Stata working graphs used to build the combined charts |

## Model

1. **Scenarios.** GDP growth, BI rate, CPI, FX, property prices and the SBN 10Y yield (sheets `Scenario 1–3`).
2. **NPL.** Dynamic fixed-effects model: NPL = core + property term.
   - The core is estimated on 2015–2026: lagged NPL (ρ ≈ 0.67) plus lags 1–4 of GDP and the BI rate.
     It is forecast recursively, and each bank converges to its own fixed effect.
   - The property term is `e_prop/4 × (sum of property-price growth, lags 1–4)`, with
     `e_prop = −0.429` borrowed from Prospera. This is a **judgment**: our own data cannot identify it,
     because the property index never fell in sample.
3. **Provisions.** Each bank's average credit cost over the last 8 quarters, plus the estimated
   response to NPL increases. On top of that sits the stress overlay
   `k_stress × (baseline GDP − scenario GDP) × NPL`, with `k_stress = 0.03` (**calibrated** so that
   Adverse 2 credit losses match the 2021Q1 provisioning peak, 10.5% of capital; the data-based
   estimate is about 0.02).
4. **Market risk.** The SBN share of FVTPL + FVOCI securities is revalued: price change = −D × ΔSBN 10Y.
   FVTPL losses go through P&L and FVOCI losses through OCI.
5. **P&L.** Lending and funding rates move with the BI rate, partially: lending rate +`beta_l` ×
   ΔBI/4 and funding cost +`beta_d` × ΔBI/4 per quarter, with `beta_l = 0.145` and `beta_d = 0.694`
   (observed transmission in the 2018–19, 2022–24 and 2026 hiking episodes; `beta_d` applies the
   time-deposit rate to all funding, an upper bound). Non-interest
   income and expense are held at their last-4-quarter ratios to assets. Tax is 22%. Dividends are a
   50% payout of profits; losses hit capital in full.
6. **Capital.** The balance sheet and RWA grow with each scenario's nominal GDP. A bank **fails if
   CAR < 8% in any forecast quarter**.

## Key caveats

- The bank data come from the `Output Sheet (Copy)` snapshot. `Output Sheet` holds BQL formulas
  that only refresh on a Bloomberg Terminal.
- Securities larger than total assets (Bloomberg unit errors) are replaced by the KBMI median.
  One-quarter scale errors in deposits (e.g. MCOR 2020Q4) are replaced by the average of the
  neighbouring quarters. BANK (Bank Aladin Syariah) is excluded, because its 2021 loans recorded at
  Rp29–42 million distort the provision regression for all banks.
- BINA and BCIC fail mainly through MTM losses, because their reported FV securities are 66–70% of assets
  (industry: about 9%). Verify these against their financial statements before drawing conclusions.
- The NPL back-test (`6_model_checks/npl_backtest.png`) shows an **upward bias**. Estimated to
  2024Q2 and fed the actual macro, the model put NPL at about 2.45% by 2026Q2, against an actual of
  about 2.1%: a mean absolute error of 0.30 pp over 8 quarters, 0.39 pp at most. Each bank reverts
  to its through-the-cycle NPL, which is above today's level. Part of the projected NPL rise
  (including about +0.15 pp in the baseline) is this reversion, not the scenario.
- Stress severity depends materially on the judgmental settings `k_stress` and `e_prop`, and on
  `beta_d`. Set `e_prop` to 0 or change `k_stress` / `beta_d` in `Parameters` to see the effect.
