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
3. **Provisions** (% of loans per quarter) = max(base + response, 0) + overlay.
   - **Base:** each bank's average credit cost over the last 8 quarters. It is the anchor and is held
     flat over the horizon in every scenario.
   - **Response:** `npl_b0 × ΔNPL⁺(t) + npl_b1 × ΔNPL⁺(t−1)`, with 0.19 and 0.12 estimated by panel FE
     (total 0.31, p = 0.04). Only NPL increases count.
   - **Stress overlay:** `k_stress × max(baseline GDP − scenario GDP, 0) × NPL`. It adds provisions
     when the economy is below baseline, before NPL has risen, in the spirit of forward-looking ECL
     (PSAK 71). It is zero in the baseline. `k_stress = 0.03` is **calibrated** so that Adverse 2
     credit losses match the peak 4-quarter provisions in our data (2021Q1, 10.5% of capital). The
     data-based estimate is about 0.02. The overlay is 46% of Adverse 2 credit losses.
   - All stress enters through the response and the overlay. Raising the base as well would count the
     same shock twice, because `k_stress` is calibrated on total credit losses.
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

## Current results

End 2027Q2, 46 banks. Losses and net income are cumulative over 4 quarters, as % of starting capital.

| | Baseline | Adverse 1 | Adverse 2 |
|---|---|---|---|
| CAR (%; start 22.53) | 22.53 | 21.87 | 21.14 |
| Tier 1 (%) | 21.42 | 20.76 | 20.03 |
| NPL (%; start 2.10) | 2.25 | 2.66 | 3.06 |
| Credit losses | 4.7 | 7.1 | 10.3 |
| Market (MTM) losses | −0.5 | 1.6 | 3.4 |
| Net income | 16.1 | 12.2 | 7.2 |
| Banks with CAR < 8% | 0 | 0 | 2 (BINA, BCIC) |

In Adverse 2 the margin squeeze from partial pass-through lowers net interest income by 3.5% of
capital. Sensitivity of Adverse 2 credit losses to `k_stress`: 0 → 5.6, 0.02 → 8.7, 0.03 → 10.3,
0.05 → 13.5 (% of capital). By group and by bank: `stress_test_summary.xlsx`, sheets
`Group_summary` and `Bank`.

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
  about 2.1%: a mean absolute error of 0.29 pp over 8 quarters, 0.40 pp at most. Each bank reverts
  to its through-the-cycle NPL, which is above today's level. Part of the projected NPL rise
  (including about +0.15 pp in the baseline) is this reversion, not the scenario.
- The stress overlay is triggered by the GDP gap only, not by the BI rate directly. A scenario with a
  sharp rate hike but no GDP shortfall would barely raise provisions. In the current scenarios GDP
  and the BI rate move together.
- `beta_d = 0.694` is an upper bound: it treats all funding like time deposits. Weighting by the
  deposit mix (LPS, Dec 2025) would give about 0.37.
- Stress severity depends materially on the judgmental settings `k_stress` and `e_prop`, and on
  `beta_d`. Set `e_prop` to 0 or change `k_stress` / `beta_d` in `Parameters` to see the effect.
