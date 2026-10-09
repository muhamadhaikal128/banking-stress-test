# Banking Solvency Stress Test – Indonesia (45 listed banks)

Top-down solvency stress test of Indonesian listed banks, built in Stata. Actual data to **2026Q2**,
forecast horizon **2026Q3–2027Q2** under three scenarios: Baseline, Adverse 1, Adverse 2.

## Repository layout

| Folder | Contents |
|---|---|
| `dofile/` | `Dofile V1.do` – current model. `Dofile V1 - original.do` – version before any of the 9 Oct 2026 revisions. |
| `data/input/` | `Solvency ST.xlsx` (macro history, scenarios, **Parameters** sheet), bank template (Bloomberg), Asset Market Updater (Bloomberg yields), BI SRBI ownership and DJPPR SBN ownership releases. |
| `data/stata/` | Stata datasets produced/used by the do-file (`kbmi.dta`, `bank.dta`, `macro.dta`, `comb*.dta`, …). |
| `results/` | Charts (`*.png`, `*.gph`) and `stress_test_summary.xlsx` (Summary, Industry_path, Bank, Assumptions). |

## How to run

1. Edit `global base` at the top of `dofile/Dofile V1.do` to point to your copy of the materials
   (the do-file expects `\Stata` for inputs/data and `\Result` for outputs).
2. **Close** `Solvency ST.xlsx` and `stress_test_summary.xlsx` in Excel.
3. `do "dofile/Dofile V1.do"` (run the whole file; do not execute a selection).
4. Results are written to `Result\stress_test_summary.xlsx` and the charts in `Result\`.

## Adjustable assumptions – `Solvency ST.xlsx`, sheet `Parameters`

| parameter | meaning |
|---|---|
| `srbi_bank`, `srbi_repo` | SRBI held by banks and under repo to BI (Rp T) – BI, *Ownership of SRBI* |
| `sbn_bank` | SBN held by banks incl. repo (Rp T) – DJPPR, *Kepemilikan SBN yang dapat diperdagangkan* |
| `w_srbi` | formula: SRBI share of bank securities (held to maturity, no MTM loss) |
| `D_sbn` | modified duration of the SBN book |
| `payout` | dividend payout on positive profit |
| `k_stress` | stress provision add-on (calibrated to the 2021 provisioning peak) |
| `tax_rate` | corporate income tax |

## Model summary

- **NPL**: dynamic bank fixed-effects model (lagged NPL, GDP and BI rate lags 1–4), recursive forecast.
- **Credit losses**: bank's normal credit cost (last 8 quarters) + estimated response to NPL increases
  (pooled FE) + stress add-on `k_stress × (baseline GDP − scenario GDP) × NPL stock`.
- **Market losses**: SBN 10Y yield path from UST 10Y, BI rate and IDR (pass-through regression);
  price change = −(1 − `w_srbi`) × `D_sbn` × ΔSBN10Y applied to FVOCI + trading securities.
- **Capital**: EBT → tax → dividends → retained earnings; balance sheet and RWA grow with nominal GDP;
  CAR = capital / RWA.

## Data notice

`data/input` contains Bloomberg-sourced data (bank template, Asset Market Updater). Keep this
repository **private**; Bloomberg terms generally do not allow redistribution of raw data.
