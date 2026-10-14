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
| alt | `archive/alt_model/script/00_master.do` … `05_results.do` (= `stress_test_full.do`) | 10 Oct 2026 | Separate logit-based model built for comparison. Archived on 13 Oct 2026 (see below). |

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

### Bank sample: MCOR back in (data repaired), BANK stays out (13 Oct 2026)

- **MCOR** was excluded because its simulated interest expense was about 9× its interest income. The
  cause was a single Bloomberg error: deposits in 2020Q4 recorded at Rp0.02T (neighbouring quarters
  about Rp18T), which made the funding cost 679% that quarter. A new fix replaces any one-quarter
  deposit value below 20% of the average of its two neighbouring quarters with that average. It
  catches MCOR 2020Q4 (and BANK 2021Q3). MCOR is now included. It is healthy: CAR 28.5%, with a minimum
  of 22.8% in Adverse 2. The original Prospera model, run on the current data, still makes MCOR fail
  (CAR −46%) because of this error.
- **BANK** was tested and stays excluded. Its 2021 loans are recorded at Rp29–42 million, giving
  provision/loan ratios of about −50,000%. Including it raises the provision-response coefficients
  from 0.19/0.12 to 8.6/10.7 for all banks, and Adverse 2 CAR collapses to 3.1% with 24 failures. Its
  provisions are also negative in every quarter.
- **Results (46 banks):** CAR 22.48 / 21.82 / 21.05, NPL 2.25 / 2.66 / 3.06; banks with CAR < 8%
  0 / 0 / 2 (BINA, BCIC). Before (45 banks): 22.47 / 21.80 / 21.03.
- **First forecast quarter only (2026Q3):** no bank fails in any scenario; the lowest is MAYA at 10.7%.

### One official model; outputs grouped; alternative model archived (13 Oct 2026)

- **v3 (`script/dofile_fixed.do`) is the only official model.** The alternative logit model gave
  different numbers in a parallel `output/figures/` folder (e.g. KBMI 4 CAR *rose* in every scenario,
  because it grows RWA with real rather than nominal GDP). Its scripts and outputs moved to
  `archive/alt_model/{script,intermediate,output}`, and its paths now point there.
- **v3 now produces every chart the alternative model had:** `macro_scenarios.png`,
  `bank_car_adverse2.png`, `industry_roa_ann.png` (annualised ROA) and `npl_backtest.png` (the v3 NPL
  model estimated to 2024Q2, forecast 8 quarters with actual macro). **Back-test result:** mean
  absolute error 0.30 pp, at most 0.39 pp. The model over-predicts (forecast about 2.45% against an
  actual of about 2.1%) because banks revert to their through-the-cycle NPL. The alternative logit
  model, anchored on recent quarters, tracked within ±0.08 pp but responds less to stress.
- **`output/fixed/` is grouped:** `1_macro/`, `2_industry/`, `3_kbmi/`, `4_himbara/`, `5_banks/`,
  `6_model_checks/`, `gph/` (Stata working graphs). `stress_test_summary.xlsx` stays at the top.

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

### Partial rate pass-through and overlay recalibration (14 Oct 2026)

- **Pass-through (new parameters `beta_l`, `beta_d` in sheet `Parameters`).** Before, a BI-rate change
  passed one-for-one to both lending and funding rates, so a hike was almost neutral for NII. Now
  lending rate(t) = rate(t−1) + `beta_l` × ΔBI/4 and funding cost(t) = cost(t−1) + `beta_d` × ΔBI/4.
  - Product betas are taken from observed transmission in the three hiking episodes 2018–19 (175 bp),
    2022–24 (275 bp) and 2026 (100 bp): 1-month time deposits 0.694, savings 0.016, working-capital
    loans 0.144, investment loans 0.194, consumer loans 0.091 (the 2018 −83 bp outlier excluded).
  - `beta_l` = **0.145**: the product betas weighted by the loan mix (BI, May 2026: working capital
    42.3%, investment 30.5%, consumer 27.2%).
  - `beta_d` = **0.694**: the time-deposit beta applied to all funding. This is an upper bound on
    funding pressure. With the LPS deposit mix (Dec 2025: time 35.7%, demand 32.8%, savings 30.6%) and
    demand deposits at half the time-deposit beta, it would be about 0.37.
  - Effect, Adverse 2 vs baseline rates over 4 quarters: interest income +0.86, interest expense −4.36,
    net −3.50% of capital (Adverse 1: −1.56%).
- **Overlay `k_stress` 0.05 → 0.03.** Calibrated so that Adverse 2 credit losses match the peak
  4-quarter provisions in our data (2021Q1, 10.5% of capital). The data-based estimate is about 0.02;
  COVID restructuring held provisioning down then, so 0.03 sits slightly above it. The overlay is now
  46% of Adverse 2 credit losses (was 59%). Adverse 2 credit losses at k = 0 / 0.02 / 0.03 / 0.05:
  5.6 / 8.7 / 10.3 / 13.5% of capital.
- A BI-rate add-on to credit cost was tested in the scratchpad and **not** adopted.
- **Results:** CAR 22.53 / 21.87 / 21.14, NPL 2.25 / 2.66 / 3.06; credit losses 4.7 / 7.1 / 10.3% of
  capital; banks with CAR < 8%: 0 / 0 / 2 (BINA, BCIC, minimum CAR 4.3% and 4.5%). Before:
  22.48 / 21.82 / 21.05. The two changes roughly offset: the smaller overlay lifts Adverse 2 CAR, the
  margin squeeze lowers it.

### FVOCI import fixed; failure by risk-profile CAR minimum (14 Oct 2026)

- **Bug: the model read the wrong FVOCI column.** `Output Sheet (Copy)` has two FVOCI columns:
  - V: `AV_SA_FA_AT_FV_THRU_OT_COMP_INC(FA_PERIOD_TYPE=Q, …)`, the correct quarterly series.
  - W: the same field without `FA_PERIOD_TYPE=Q`. It is not aligned with the bank/date rows. For
    example, BNBA (assets Rp7.7T) shows FVOCI of Rp171T and BBCA only Rp0.4T.
  
  Stata truncates the column V header to exactly `av_sa_fa_at_fv_thru_ot_comp_inc`. The rename loop
  treated that name as already taken and **dropped column V**, so column W was used for every bank.
  The loop now keeps a column whose name is already the target.
- **Checks:** column V passes the audit in `Sheet1`/`Sheet2` of the Excel template (FV + loans ≤
  assets for every bank-quarter; highest 93.6%). It also matches published statements, e.g. BCIC
  FVOCI Rp2.33T in Jun 2026 (Bank JTrust report) and BINA Rp7.4T in Sep 2025 (total securities
  Rp7.7T).
- **Data cleaning:**
  - Negative FV values (106 in column V, Bloomberg artefacts) are set to 0.
  - A missing FV value is filled from the previous quarter, at most 2 back (MCOR and BBMD in 2026Q2).
  - The cap of securities at 100% of loans is removed.
- **Failure by risk profile:** `Summary` also counts banks whose minimum CAR falls below the
  risk-profile minimums of POJK 11/2016: 9, 10, 11 and 14%. Bank ratings are not in the data, so
  only counts are shown.
- **Results:**
  - CAR 22.62 / 21.53 / 20.44 (was 22.53 / 21.87 / 21.14).
  - Market losses −0.9 / 3.2 / 6.7% of capital (was −0.5 / 1.6 / 3.4). Large banks now carry
    realistic FV books: Himbara market loss 6.9% of capital, KBMI 3 9.1%.
  - Credit losses and NPL unchanged.
  - Banks with CAR < 8%: 0 / 0 / 1 (**BINA**, minimum 6.5%; was BINA and BCIC). BINA holds FV
    securities of about 4× capital, which fell to Rp2.8T after its 2025 loss. It still fails without
    the overlay and the property term (7.9%).
  - BCIC passes (11.6%).
  - Below 9 / 10 / 11 / 14%, Adverse 2: 2 / 3 / 3 / 6 banks (BINA, MAYA, BBKP, BCIC, PNBS, BJBR).

---

## Results by version

Base quarter 2026Q2, horizon 4 quarters (end 2027Q2). Losses are cumulative over the horizon, as %
of starting regulatory capital.

| | v2 (archive) | v3 (bug fixes only) | v3, 13 Oct (+ property term, scenario package, 45 banks) | v3, 14 Oct (+ MCOR, pass-through, k = 0.03; 46 banks) | **v3 current** (+ correct FVOCI column) | alt (logit) |
|---|---|---|---|---|---|---|
| CAR end, Baseline / Adv 1 / Adv 2 (%) | 22.77 / 22.23 / 21.25 | 22.47 / 21.93 / 21.29 | 22.47 / 21.80 / 21.03 | 22.53 / 21.87 / 21.14 | **22.62 / 21.53 / 20.44** | 23.14 / 22.78 / 22.41 |
| NPL end, Baseline / Adv 1 / Adv 2 (%) | 2.23 / 2.29 / 2.49 | 2.21 / 2.27 / 2.48 | 2.26 / 2.67 / 3.08 | 2.25 / 2.66 / 3.06 | **2.25 / 2.66 / 3.06** | 2.07 / 2.12 / 2.20 |
| Credit losses Adv 2 (% capital) | 11.5 | 11.7 | 13.6 | 10.3 | **10.3** | 10.5 |
| Market losses Adv 2 (% capital) | 6.4 | 3.2 | 3.4 | 3.4 | **6.7** | 3.3 |
| Banks with CAR < 8%, Baseline / Adv 1 / Adv 2 | 0 / 0 / 1 | 0 / 0 / 2 (BINA, BCIC) | 0 / 0 / 2 (BINA, BCIC) | 0 / 0 / 2 (BINA, BCIC) | **0 / 0 / 1 (BINA)** | 0 / 1 / 3 |

All v2 and v3 columns before "v3 current" used the misaligned FVOCI column (see the 14 Oct entry), so
their market losses are not reliable.

The v2 and "bug fixes only" columns use the original scenarios. The later v3 columns and alt use the
current scenarios (13 Oct 2026). The alt model has no property term, so its NPL barely responds.

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

- **Bank risk-profile ratings are not in the data.** Failure is reported at 8% plus the counts below
  9 / 10 / 11 / 14%. Which banks actually breach their own minimum depends on their ratings: check
  them for the six banks below 14% in Adverse 2.
- **The estimated NPL response to the scenarios is small.** From GDP and the BI rate alone, Adverse 2
  is only about 0.27 pp above the baseline, because the macro sensitivity is estimated on 2015–2026,
  which includes the OJK restructuring period. The judgmental property term (`e_prop`) raises this to
  0.75 pp. Stress credit losses still depend materially on `k_stress` (46% of Adverse 2 credit
  losses). It is set at 0.03, calibrated to the 2021Q1 provisioning peak (10.5% of capital); the
  data-based estimate is about 0.02.
- **The stress overlay is triggered by the GDP gap only, not by the BI rate directly.** A scenario
  with a sharp rate hike but no GDP shortfall would barely raise provisions. In the current scenarios
  GDP and the BI rate move together, so the GDP gap stands in for both. The base credit cost (last
  8-quarter average) is deliberately held flat; all stress enters through the NPL response and the
  overlay.
- **`beta_d` = 0.694 is an upper bound.** It treats all funding like time deposits. A deposit-mix
  weighted value would be about 0.37, which would roughly halve the extra Adverse 2 interest expense.
- **The scenario sheets hold 6 quarters but the model uses 4.** The horizon is set by
  `global horizon` / `tsappend`.
