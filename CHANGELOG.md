# Changelog: Banking Solvency Stress Test

This file traces how the stress-test model changed from the original handbook do-file (v1) to the
current version (v3). The aim is that anyone can see what changed, why, and what it did to the
results. For how to run the model, see `README.md`.

## Version map

| Version | File | Date | Status |
|---|---|---|---|
| **v1** | `archive/Stata/dofile.do` | 4 Oct 2026 | Original handbook model (2024Q2 setup). Archived. |
| **v2** | `archive/old_script/dofile_old.do` | 9 Oct 2026 | Updated model; produced everything in `archive/Result/` incl. `stress_test_summary.xlsx`. Archived. |
| **v3** | `script/dofile_fixed.do` | 12 Oct 2026 | **Current model.** v2 with bugs fixed. Outputs in `intermediate/fixed/` and `output/fixed/`. |
| alt | `script/00_master.do` … `05_results.do` (= `script/stress_test_full.do`) | 10 Oct 2026 | Separate logit-based model built for comparison. Not the main line (see the "Alternative model" section below). |

Data vintage for v2 and v3: bank data to **2026Q2** (Bloomberg, sheet `Output Sheet (Copy)`),
scenarios **2026Q3–2027Q2**, 45 listed banks.

---

## v1 → v2 (original → `dofile_old.do`)

The changes here were made by the original author; they are summarised from the code diff.

**Setup and data**
- Paths moved from the shared drive (`Z:\Shared\PROSPERA\...`) to a local folder.
- Bank data are read from sheet `Output Sheet (Copy)`, the values snapshot. The sheet `Output Sheet`
  holds live BQL formulas, which only refresh on a Bloomberg Terminal.
- Assumptions moved out of the code into sheet `Parameters` of `Solvency ST.xlsx`: `tax_rate`,
  `payout`, `w_srbi`, `D_sbn`, `k_stress`.
- Outlier exclusion changed from `bank_id == 7` to the tickers `BANK` and `MCOR`. MCOR was
  excluded because its interest expense came out at about 9× its interest income (a data issue).

**Model**
- **NPL.** v1 was a static linear FE model (12 lags of GDP, BI rate and property prices). v2 is a
  **dynamic FE model**: lagged NPL plus 4 lags each of GDP and BI rate. Property prices were dropped
  because the house-price index never fell in sample, so its coefficient had the wrong sign and adverse
  shocks *lowered* NPL. Forecasts are recursive and carry each bank's fixed effect forward.
- **Provisions.** v1 used an FE regression on NPL, size and BI rate. v2 uses the bank's average
  provision charge over the last 8 quarters, plus an estimated response to NPL increases
  (`npl_b0` = 0.188 in the same quarter, `npl_b1` = 0.118 one quarter later), floored at 0, plus the
  **stress overlay** `k_stress × (baseline GDP − scenario GDP) × NPL`.
- **Securities (MTM).** v1 used `d.d_price/10000 × sec_r`, i.e. the change of a change applied to a
  ratio. v2 computes the price change as `−(1 − w_srbi) × D_sbn × Δ SBN 10Y yield`; SRBI is held to
  maturity, so only SBN is revalued. The loss is that price change applied to the securities **amount**.
- **Balance sheet.** Growth switched from real GDP to **nominal** GDP (GDP + CPI), quarterly.
- **Income statement.** Provisions are scaled by **loans**; v1 scaled them by assets.
- **Capital.** v1 added all profit to capital. v2 pays a 50% dividend on profits (`payout`); losses
  hit capital in full.

**Output**
- Added `stress_test_summary.xlsx` with sheets Industry_path, Bank, Summary and Assumptions.
- Chart dates updated to 2026Q2 (still hard-coded).

---

## v2 → v3 (`dofile_old.do` → `dofile_fixed.do`)

v3 keeps v2's structure (one file, `_b1/_b2/_b3` variables) and every model choice. Only bugs were
fixed. Each fix is marked `FIX:` in the code and listed in the FIX LOG at the end of the file.

| # | Area | v2 | v3 | Why |
|---|---|---|---|---|
| 1 | Paths | personal Desktop folder | project `input/`, `intermediate/fixed/`, `output/fixed/` | Reproducible |
| 2 | Variable names | `rename *fill* *` left names like `is_int_incfa_period_typeq`, used only via Stata abbreviation | Names taken from the BQL item label | Fragile, could break silently |
| 3 | Merges | `merge m:m` (KBMI, scenarios) | `merge m:1`, matched rows only | `m:m` is not a valid join |
| 4 | Starting ratios | Bank's 2014–2026 **average** loan/asset, deposit/asset, lending rate, saving rate, non-interest income/expense | Last actual quarter (stocks) or last 4 quarters (flows) | The average made the balance sheet and income **jump** at the start of the forecast |
| 5 | Non-interest income/expense | Held flat at the last quarter's level | Last-4Q ratio × projected assets | Consistent with balance-sheet growth |
| 6 | Policy-rate pass-through | Annual BI-rate change added to **quarterly** lending/saving rates | Change ÷ 4 | Overstated repricing four-fold |
| 7 | RWA growth | Baseline GDP + CPI (`gdp_b1+cpi_b1`) in **every** scenario | Each scenario's own GDP + CPI | Adverse RWA grew as if in the baseline |
| 8 | Quarterly growth | `g/4` | `(1+g)^(1/4) − 1` | Exact conversion |
| 9 | NPL | 10-replication bootstrap SEs; no floor | Clustered SEs (same point estimates); floor at 0 | Bootstrap with 10 reps is not meaningful |
| 10 | Securities data | Capped at 100% of loans | Values larger than **total assets** (Bloomberg scaling errors: BACA, BBYB, BNBA, BTPS, BVIC) replaced by the KBMI median | Capping kept wrong values in |
| 11 | MTM loss treatment | All losses through P&L (taxed) | FVTPL part through P&L; FVOCI part through OCI, straight to capital | Accounting treatment |
| 12 | Charts | `lgraph` = **simple average of bank ratios**; hard-coded dates | Aggregated ratios (sum of amounts ÷ sum of base); dates from data; no `ssc` package needed | A small bank counted as much as BRI |
| 13 | History in charts | Model back-cast of net income | Reported net income | Shows actual history |
| 14 | Bank failure | CAR < 8% in the **last** quarter only (and `quarter >= max` included the actual) | CAR < 8% in **any** forecast quarter | A bank can breach and recover within the horizon |
| 15 | Robustness | Panel not re-sorted after `tsappend` | `xtset` after `tsappend` | Lag operators need sorted data |

### Changes tried in v3 and reverted (12 Oct 2026)

Two NPL changes were tested and then **reverted**, because they altered the author's model choice
rather than fixing a bug, and they made NPL implausibly low:

1. **Anchoring each bank on its last 4 quarters** instead of its fixed effect. This kept NPL at its
   2026 cyclical low, so NPL *fell* in the baseline (2.10% → 2.01%).
2. **Excluding NPL data breaks** (NPL = 0, or jumps of 5 pp or more) from the NPL regression. This
   lowered the sensitivity of NPL to the scenarios.

| Industry NPL, 2027Q2 | Baseline | Adverse 2 |
|---|---|---|
| v2 (archive) | 2.23 | 2.49 |
| v3 with both changes (reverted) | 2.01 | 2.19 |
| **v3 final** | **2.21** | **2.48** |

### Model change in v3: property-price term in NPL (12 Oct 2026)

Not a bug fix but a deliberate, **judgmental** addition (setting `global e_prop` at the top of
`dofile_fixed.do`; `0` switches it off and gives the pure model).

- **Why.** Without it, Adverse 2 NPL is only 0.27 pp above the baseline (Prospera: about 0.77 pp), and the
  property shock in the scenarios has no channel into the model.
- **Why not estimated.** The property price index (IHPR) never fell in sample (QoQ growth +0.04% to
  +1.39%; scenario trough −2.65%). Estimated on our data to 2026Q2, the property coefficients have the
  wrong sign: Adverse 2 NPL would *fall* to 1.61%. Real (CPI-deflated) prices give the same result.
- **What.** `e_prop = −0.429`, the sum of the property lag coefficients in Prospera's NPL regression
  (2014–2024Q2), spread evenly over lags 1–4. It enters as a **static** term on top of the dynamic NPL
  core (NPL = core + property term), so NPL persistence does not multiply it. Imposing Prospera's four
  separate lag coefficients was also tested; their alternating signs made baseline NPL jump by about
  0.3 pp in 2026Q4, so the summed, evenly spread version was chosen.

| End 2027Q2, k_stress = 0.05 | v3 before | **v3 with property term** |
|---|---|---|
| NPL Baseline / Adv 1 / Adv 2 (%) | 2.21 / 2.27 / 2.48 | **2.26 / 2.34 / 3.01** |
| NPL spread Adv 2 − Baseline (pp) | 0.27 | **0.75** |
| CAR end Baseline / Adv 1 / Adv 2 (%) | 22.47 / 21.93 / 21.29 | **22.47 / 21.91 / 21.11** |
| Credit losses Adv 2 (% capital) | 11.7 | **13.2** |
| Banks with CAR < 8%, Adv 2 | 2 (BINA, BCIC) | 2 (BINA, BCIC) |

### Scenario change: Adverse 1 property path (12 Oct 2026)

With the property term, Adverse 1 NPL rose only 0.08 pp above the baseline (Adverse 2: 0.75 pp),
because the Adverse 1 property path was barely shocked within the horizon (+0.20, +0.36, 0.00, +0.11%
QoQ; the declines came only in 2027Q3–Q4). In `input/Solvency ST.xlsx`, sheet `Scenario 2`, column
`d_property` (F2:F7) is now the **midpoint between Baseline and Adverse 2**, consistent with Adverse 1
GDP, which also lies about halfway. F2 was a formula (`=Macro!J50-Haircut!I7`); F2:F7 are now values.

| d_property, QoQ % | 26Q3 | 26Q4 | 27Q1 | 27Q2 | 27Q3 | 27Q4 |
|---|---|---|---|---|---|---|
| Adverse 1, old | 0.20 | 0.36 | 0.00 | 0.11 | −0.22 | −0.55 |
| **Adverse 1, new** | **0.18** | **−0.57** | **−1.20** | **−1.16** | **−0.44** | **−0.19** |

| End 2027Q2 | Baseline | Adverse 1 old | **Adverse 1 new** | Adverse 2 |
|---|---|---|---|---|
| NPL (%) | 2.26 | 2.34 | **2.57** | 3.01 |
| CAR (%) | 22.47 | 21.91 | **21.88** | 21.11 |
| Credit losses (% capital) | 4.7 | 7.9 | **8.3** | 13.2 |
| Banks with CAR < 8% | 0 | 0 | **0** | 2 |

### Scenario package: coherent Adverse 1, stronger BI response in Adverse 2 (13 Oct 2026)

This supersedes the Adverse 1 property path above. A review of the scenarios found that **Adverse 1 was
not coherent**: the rupiah weakened by 7% and CPI rose to 5% (above the target band), yet BI *cut* rates
by 71 bp. Adverse 1 is now a milder version of the Adverse 2 global shock. Changed in
`input/Solvency ST.xlsx`, sheets `Scenario 2` and `Scenario 3`, rows 2–7, columns C (`reporate`),
F (`d_property`), G (`d_price`) and J (`sbn10y`). All are now values; they were formulas linked to
`Haircut`. GDP, CPI, FX and UST are unchanged.

| 26Q3 → 27Q4 | Old | New |
|---|---|---|
| BI rate, Adverse 1 (%) | 5.75 → 4.56 (cuts) | 5.75, 6.00, 6.25, 6.25, 6.25, 6.25 (+50 bp) |
| BI rate, Adverse 2 (%) | 5.75 → 6.94 | 6.00, 6.50, 7.00, 7.25, 7.25, 7.25 (+150 bp, in line with 2013/2018/2022) |
| d_property, Adverse 2 (% QoQ) | 0.11, −1.39, −2.65, −2.57, −1.12, −0.62 | −0.5, −1.5, −2.0, −2.5, −2.5, −2.0 (no recovery while GDP still falls; 4Q total about −6.5%) |
| d_property, Adverse 1 (% QoQ) | midpoint of the old Adverse 2 path | 50% of the new Adverse 2 deviation from baseline: −0.12, −0.62, −0.88, −1.12, −1.12, −0.88 |
| SBN 10Y | — | shifted by beta_rate (0.125) × change in BI rate, as in `Haircut`; `d_price` = −5 × ΔSBN 10Y |

Alternatives tested with Adverse 1 property at 67% and 75% of Adverse 2: CAR is practically the same
(21.79 and 21.78), and only NPL changes (2.75 and 2.79). 50% was chosen.

| End 2027Q2 | Before | **After** |
|---|---|---|
| NPL Baseline / Adv 1 / Adv 2 (%) | 2.26 / 2.57 / 3.01 | **2.26 / 2.67 / 3.08** |
| CAR Baseline / Adv 1 / Adv 2 (%) | 22.47 / 21.88 / 21.11 | **22.47 / 21.80 / 21.03** |
| Credit losses Adv 1 / Adv 2 (% capital) | 8.3 / 13.2 | **8.5 / 13.6** |
| Market losses Adv 1 / Adv 2 (% capital) | 1.4 / 3.2 | **1.6 / 3.4** |
| Banks with CAR < 8%, Adv 1 / Adv 2 | 0 / 2 | **0 / 2** (BINA's minimum CAR in Adverse 1 is 8.68%) |

Remaining scenario points, not changed: baseline UST 10Y jumps from 4.47 to 4.96 in the first quarter;
the Adverse 2 UST path (7.3% by 27Q2) is extreme and should be described as a tail scenario; the property
shock is set by judgment (about 8σ of IHPR history, against about 2σ for the other variables).

### Output addition: Himbara vs non-Himbara and group tables (13 Oct 2026)

- `global himbara "BBRI BMRI BBNI BBTN BRIS"` (top of `dofile_fixed.do`). These are the four Himbara
  banks plus BSI (BRIS), which was added by choice: it is majority state-owned through Mandiri, BRI and
  BNI, but is not a formal Himbara member.
- New charts `npl_himbara.png`, `car_himbara.png`, `tr1_himbara.png`, `eat_himbara.png`.
- New sheets in `stress_test_summary.xlsx`: `Group_summary` (per group × scenario: CAR start/end/min,
  Tier 1, NPL, cumulative credit/market losses and net income in % of the group's capital, banks with
  CAR < 8%) and `Group_path` (quarterly CAR, Tier 1 and NPL). Both cover Himbara, Non-Himbara and
  KBMI 1–4. The `Bank` sheet has a `himbara` column.
- No change to the model or to the industry results.

The rise of about 0.1 pp in the first forecast quarter, seen in all scenarios, is **intended**. Each
bank converges (ρ ≈ 0.8) back toward its through-the-cycle NPL, and the 100 bp BI-rate hike in
2026Q2 feeds in with a lag. It is not a bug.

---

## Results by version

Base quarter 2026Q2, horizon 4 quarters (end 2027Q2). Losses are cumulative over the horizon, as %
of starting regulatory capital.

| | v2 (archive) | v3 (bug fixes only) | **v3 current** (+ property term, scenario package) | alt (logit) |
|---|---|---|---|---|
| CAR end, Baseline / Adv 1 / Adv 2 (%) | 22.77 / 22.23 / 21.25 | 22.47 / 21.93 / 21.29 | **22.47 / 21.80 / 21.03** | 23.14 / 22.78 / 22.41 |
| NPL end, Baseline / Adv 1 / Adv 2 (%) | 2.23 / 2.29 / 2.49 | 2.21 / 2.27 / 2.48 | **2.26 / 2.67 / 3.08** | 2.07 / 2.12 / 2.20 |
| Credit losses Adv 2 (% capital) | 11.5 | 11.7 | **13.6** | 10.5 |
| Market losses Adv 2 (% capital) | 6.4 | 3.2 | **3.4** | 3.3 |
| Banks with CAR < 8%, Baseline / Adv 1 / Adv 2 | 0 / 0 / 1 | 0 / 0 / 2 (BINA, BCIC) | **0 / 0 / 2 (BINA, BCIC)** | 0 / 1 / 3 |

The v2 and "bug fixes only" columns use the original scenarios. v3 current and alt use the current
scenarios (13 Oct 2026). The alt model has no property term, so its NPL barely responds.

v1 has no summary table. Its charts in `archive/Result/` (files `*_buku*`, dated 4 Oct) come from
an earlier data vintage.

**What drives the v2 → v3 differences**
- **Baseline CAR is lower (−0.3 pp).** v2 overstated profits because it used historical-average
  rates and ratios. v3 profits over 4 quarters are about 16% of capital, in line with the actual ROA
  of about 2%.
- **Market losses are half.** The mis-scaled Bloomberg securities values are no longer used.
- **Adverse 2 CAR ends at about the same level, but one more bank fails.** Failure is now checked in
  every forecast quarter, not only the last one.

---

## Alternative model (logit), for reference

Built on 10 Oct 2026 as a re-design, before v2 was available. It uses a dynamic **logit** NPL model,
asset-weighted, with a COVID dummy; provisions as a function of the NPL level and change; and NII as
NIM plus a repricing gap. It reproduces history well (out-of-sample back-test error ±0.08 pp).
However, it projects lower NPL in stress, because it is anchored on recent levels. It is kept in
`script/` for comparison only. Its outputs are the files directly in `intermediate/` and in
`output/tables/` and `output/figures/`.

## Folder restructure (10 Oct 2026)

- Original folders `Stata/` and `Result/` moved to `archive/Stata/` and `archive/Result/`.
- Raw inputs copied to `input/`: `Solvency ST.xlsx`, `Stress Testing Manual - Excel Template.xlsx`
  and `kbmi.dta`. Reference documents are in `input/reference/`.
- The pipeline writes only to `intermediate/` and `output/`; `input/` is never modified.

## Open issues

- **BINA and BCIC fail mainly on MTM losses.** Bloomberg reports their securities at 66–70% of
  assets; check this against their financial statements.
- **The estimated NPL response to the scenarios is small.** From GDP and the BI rate alone, Adverse 2
  is only about 0.27 pp above the baseline, because the macro sensitivity is estimated on 2015–2026,
  which includes the OJK restructuring period. The judgmental property term (`e_prop`) raises this to
  0.75 pp. Stress credit losses still depend mainly on `k_stress`. Its data-based estimate is about 0.02
  (industry provisions on GDP gap × NPL). 0.05 is kept as a judgmental severe calibration. The target
  of 11.5% of capital should be re-checked: the peak in our data is 10.5% (2021Q1).
- **The scenario sheets hold 6 quarters but the model uses 4.** The horizon is set by
  `global horizon` / `tsappend`.
