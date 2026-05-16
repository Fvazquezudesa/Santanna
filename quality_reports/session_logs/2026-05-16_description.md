# Session Log: 2026-05-16

**Status:** IN PROGRESS

## Current Goal

Finalize spatial heterogeneity tables and prose for the PROCREAR paper
(`Procrear/paper_new.tex`, Section 5.4). Tables now follow the paper's
existing style (scriptsize, sym macro, checkmark rows for controls,
explanatory minipage below the tabular).

## Key Context (carried over from 2026-05-14/15)

**Canonical specs (filter = trim = 50 km, τ = 5 km, pre_employed == 1):**

- **Sample 1:** filter `d_res_CABA < 50`, RHS Δ = rowmin to 21 urban centers
- **Sample 2:** filter `d_res_pre_21 < 50`, RHS Δ = rowmin to 21 urban centers

**21-city set:** CABA, La Plata, Bahía Blanca, Rosario, Santa Fe, Córdoba,
Río Cuarto, Santa Rosa, Mendoza, San Rafael, Paraná, Tucumán, Salta, Jujuy,
Sgo del Estero, Resistencia, Posadas, Bariloche, Puerto Madryn,
Río Gallegos, Río Grande. (Paraná replaces SanLuis from earlier canonical.)

**Bins:** Closer (Δ<−5), Same (|Δ|≤5, reference), Away (Δ>+5).

**Two specifications estimated:**

1. **Slope (continuous):** `c.Δ##i.ganador` →
   coefficient of interest β_W = average marginal Δ × Win effect
2. **Bin:** `ib2.bin##i.ganador` →
   β_C (Closer × Win), β_A (Away × Win), both relative to Same

**Outcomes:** log_wage (main), total_wage Poisson QMLE (appendix).
Employed/any_work/is_monotributo dropped from paper output.

## Today's progress

- Renamed bin coefficient labels in paper equations from Spanish
  (Acerca/Igual/Aleja) to English (Closer/Same/Away) to match table
- Section 5.4 now has explicit equations (Slope and Bin) above the table
- Compiles cleanly at 23 pages; pushed commits b546e27 and 32c0865

## Dofile

`scripts/paper_distancia_outcomes.do` — single source of truth.
Outputs `Procrear/tables/tab_distancia_{log_wage,total_wage}.tex`.

## Open questions

- Whether to also format the equations to use the same coefficient names
  (β_W vs β_S etc.) as future writeup will reference
- Whether bin-level Lee bounds (Chen-Roth) deserve their own table
- Cuit-change heterogeneity (descriptive, not in paper currently) — keep
  out or include as a robustness panel?

## Other 2026-05-16 sessions

- [2026-05-16_bcra_combined_age.md](2026-05-16_bcra_combined_age.md):
  fixed Total Debt note (nominal, not constant ARS) and reordered
  `bcra_combined_age.tex` so Banked sits right after Slow Payer (col 3),
  with Q1–Q4 contiguous in cols 4–7. Pushed `b96bed0` and `1b89e2f`.

---

## Late-day session: dofile-table format alignment + Spanish removal

### Goal
Align Stata table-writers in `scripts/*.do` with the manually-polished
.tex tables (Codex/Franco style: `tabcolsep=0pt`, Pattern A fixed-width
`p{X\textwidth}` cols OR Pattern B `tabular*` + `\extracolsep{\fill}`,
notes outside the tabular in a `\begin{minipage}` after `\par\smallskip`).

### Work completed

**1. Dofile format alignment for 12 tables across 6 dofiles**
- `paper_labor_outcomes.do`: 6 tables (first_stage [esttab],
  main/main_full [shared block], het_type, het_cohort, het_type_cohort)
- `paper_placebo_nov23.do`: placebo_fs_combined (A), placebo_itt_combined (B)
- `paper_hijos_outcomes.do`: table_n_kids_after (A)
- `paper_bcra_combined_age.do`: bcra_combined_age (A, 7-col, p=0.108)
- `paper_distancia_outcomes.do`: tab_distancia_log_wage and
  tab_distancia_total_wage (both B)

GitHub commit: `6e22898`.

**2. Spanish → English in tables AND dofiles**
- Ganador → Winner, Mujer → Female, Receptor → Recipient, Edad → Age
- Sorteo / sorteos → Lottery / lotteries
- Monotributo → **Self-employed** (per Franco: "hablar de autónomo")
- Aleja / Acerca / Igual → Away / Closer / Same
- Lotes → Land, Construcci\'{o}n → Construction
- fecha\_sorteo → lottery date, any tipo → any type

For `paper_distancia_outcomes.do`, the bin-name change had to be
applied beyond just file_write strings: `label define binlab`, `post`
statements, `cond()`, `foreach rowname`, `coef == "..."` filters, and
`local bin_lbl` — all kept consistent. Stata variable names
(`sorteo_fe`, `fecha_sorteo`, `tipo_grupo`) intact in code paths.

Commits: Overleaf `c0923d1` (.tex), GitHub `a7ce8d2` (dofiles).

**3. table_main / table_main_full iterations**
- Dropped the `p-val (H_0: δ=0)` row and matching footnote sentence.
  Applied manually to both .tex files and to the Step 5d generator
  in `paper_labor_outcomes.do`. Overleaf `a634e44`, GitHub `d79a3bb`.
- Renamed caption "Main Effects and Gender Heterogeneity" →
  "Labor Market Effects" (and "(Full Controls)" for the appendix
  version). Matches the `\subsection{Labor Market Effects}` heading.
  Overleaf `860c4bb`, GitHub `4425d75`.

**4. Placebo section commentary**
Added a paragraph in `paper_new.tex` Section "Robustness" after the
cross-placebo paragraph noting:
1. For Nov 23 (FS=0 by construction), the employment ITT flips sign
   between Panel A (last-month employment, positive ≈0.007–0.010) and
   Panel B (post-lottery share, negative ≈−0.005 to −0.001) — noise
   around a true zero.
2. Restricting to Panel A, the ITT magnitudes order monotonically
   with the first stages: Nov 23 (FS=0, ITT≈0.01), Dec 4 (FS=0.318,
   ITT≈0.015), Sep 26 (FS=0.624, ITT≈0.025). ITT/FS ratio
   approximately constant across the two non-placebo lotteries —
   consistent with a stable LATE close to the main-sample estimate.
Also fixed remnant Spanish ("sorteos", "fecha\_sorteo") in the
preceding paragraph. Overleaf commit: `bf4fd61`.

### Open items
- `balance_pooled.tex` still uses the old `\multicolumn{N}{p{...}}`
  notes inside the tabular. Codex didn't touch it; left alone.
- Tables NOT in paper_new.tex (table_extensive, table_emp_share,
  table_het_gender, hijos extras, placebo per-sorteo) still have
  remnant Spanish in their writers; left alone since they don't
  appear in the paper.

---

## Late-evening: read `paper_placebo_nov23.do`

User asked for a read-through (no edits). Summary captured in chat:
the dofile loops over 3 lotteries (Nov 23 placebo + Sep 26 DU and Dec 4 DU
positive controls), builds per-lottery sorteo + SIPA + cross-section,
runs Step 4e first stage and Step 5 ITT pooled + gender heterogeneity per
lottery, then Step 6 emits two cross-lottery combined tables
(`placebo_fs_combined.tex`, `placebo_itt_combined.tex`). 11 tables total.
No code changes; awaiting further user instruction.

---

## Night session: add BCRA outcomes to placebo dofile

### Goal
Extend `paper_placebo_nov23.do` to also run the §5.2 BCRA analysis on
each of the three placebo lotteries (Nov 23 placebo + Sep 26 / Dec 4 DU
positive controls), with both per-lottery tables and a cross-lottery
combined table that lays the three side by side. Outcomes mirror
`bcra_combined_age.tex`: Total Debt, Slow Payer, Banked (all-entities
sample) and Q1–Q4 Cost (excl.-Hipotecario sample). ITT only, age
control (matches the IV/2SLS spec in the main §5.2 table but without
the first stage since the Nov 23 placebo has receptor = 0 by
construction).

### Edits to `scripts/paper_placebo_nov23.do`

1. **Header docstring** — bumped from "THREE tables per lottery" to
   "FOUR tables per lottery" and listed the new BCRA outputs.
   Documented the dependency on `$temp/median_costo.dta`.
2. **Step 1.5 (new, outside loop)** — load `$temp/median_costo.dta`,
   compute Q-quartile cutoffs (p25/p50/p75 over the same universe as
   the main analysis), generate `is_q1`/`is_q2`/`is_q3`/`is_q4` entity
   flags, save to `$temp/_plac_q_flags_entity.dta`.
3. **Step 5c (new, inside placebo loop)** — for each lottery:
   - Load `Data_BCRA.dta` filtered to placebo persons (all-entities
     pass) → total_deuda, moroso_ever, active_bcra
   - Drop Hipotecario rows → Q1–Q4 Cost with last-period semantics
   - Join to xsec, run 7 ITT regressions with age control, save locals
   - Write per-lottery `placebo_bcra[_sfx].tex` (7-col table matching
     `bcra_combined_age.tex` layout, but ITT)
4. **Step 7 (new, post-loop)** — assemble cross-lottery comparison
   `placebo_bcra_combined.tex` (outcomes as rows, 3 lotteries as cols).
5. **Cleanup** — added `_plac_q_flags_entity.dta` to the final erase
   list.
6. **Final summary** — appended the new tables to the run-end di's.

Outputs: 4 new tables (placebo_bcra.tex, placebo_bcra_sep26_du.tex,
placebo_bcra_dec4_du.tex, placebo_bcra_combined.tex) on top of the 7
existing tables.

### Status
Script launched in background. Awaiting completion. No commit yet —
will check log + verify table outputs before pushing.

---

## Late-night follow-up: 3-spec BCRA placebo + paper table reformat

### Run 1: original Step 5c (age-only)

Script completed (exit 0). 4 new BCRA tables generated and pushed
(commit `ad5e051`):
- `placebo_bcra.tex`, `placebo_bcra_sep26_du.tex`,
  `placebo_bcra_dec4_du.tex` (per-lottery, 7 outcomes, age control)
- `placebo_bcra_combined.tex` (cross-lottery, 7 outcomes × 3 lotteries,
  age control)

Highlights from the combined table:
- Nov 23 (placebo): all 7 outcomes NS (exclusion restriction holds)
- Sep 26 (DU): Total Debt −1,760*** ; Banked +0.024*; others NS
- Dec 4 (DU): Total Debt −1,032* ; Slow Payer +0.081***; others NS

### Run 2: 3 spec variants (no ctl / age / full)

User asked to see the 3 control specs. Modified Step 5c to run 3 specs
per outcome (saving `bcra_bn`/`bcra_b`/`bcra_bf` locals) plus log
display via `di` with PARSE-prefixed lines. Re-ran the full script.
Parsed PARSE lines back from the log; presented full 3-spec results
in chat. Point estimates almost identical across specs — sorteo
randomization makes controls a precision lever only.

### Run 3: reformatted combined table for paper inclusion

User wants the §5.2 placebo evidence in the paper but limited to:
- 3 outcomes (Total Debt, Slow Payer, Banked) — drop the four
  Q-Cost columns
- 2 specs (no ctl + age only) — drop full ctl

Modified Step 7 to produce a `tabular*` 6-col layout matching the
existing `placebo_itt_combined.tex` (multicolumn header per lottery,
`\cmidrule`, Controls-for-age `\checkmark` row).

Skipped re-running the full script. Wrote the new `.tex` manually using
the values harvested from Run 2's log. Commit `4d7119c`.

### Outstanding
- `paper_new.tex` doesn't yet `\input` the new `placebo_bcra_combined`
  table. User asked me to leave the inclusion decision to them.
- Per-lottery `placebo_bcra*.tex` tables still use 7 outcomes × age
  spec only — left untouched since the user said "en el paper" only.

---

## Update — paper_new.tex Section 5.1 narrative written

Wrote the labor + fertility narrative for Section 5.1 of
`paper_new.tex`:
- Setup paragraph: age-only controls (only unbalanced covariate);
  appendix `table_main_full` has the full-controls version.
- Define `Formal Emp` (Dec 2025) and `Emp Share (18m+)` (months
  employed from sorteo+18 through Dec 2025).
- Pooled: +1.30pp Formal Emp (★★), +1.65pp Emp Share (★★★). Bigger
  effect on cumulative share — credit smooths attachment, not only
  endpoint.
- Gender: stronger for men (1.63/1.83pp) than women (1.20/1.43pp),
  no p-val mentioned per Franco's instruction.
- Fertility channel: +0.0070 kids pooled (★, +11% relative); by
  gender not significant but women (0.0082) > men (0.0059).
- Commit `bfe1e50` pushed to Overleaf.

---

## Update — placebo do-file: added fertility block

Extended `scripts/paper_placebo_nov23.do` with a fertility outcome
block, mirroring the labor + BCRA placebo machinery for the three 2023
sorteos.

Spec: `n_kids_post` = `n_kids_2024 - n_kids_at_sorteo` (kids born
strictly after the lottery year, observed through end of 2024). ITT
with three specs: noctl / age / age+`n_kids_pre` (primary, matches
`table_n_kids_after.tex`).

Changes:
- Header docstring: list new outputs and data requirements.
- STEP 1.6 (NEW): build cumulative-children panel from
  `$data/proc_as_parents.dta`, save as `_plac_proc_kids_panel.dta`.
- STEP 2: `destring cuil, gen(cuil_num) force`.
- STEP 4: add `cuil_num` to xsec keep list.
- STEP 5d (NEW, inside loop): three merges from kids panel →
  `n_kids_pre`, `n_kids_at_sorteo`, `n_kids_2024`. Three reghdfe specs
  on `n_kids_post`. Write `placebo_hijos<sfx>.tex` (3 cols, 1 outcome,
  controls indicator rows).
- STEP 8 (NEW, after loop): combined `placebo_hijos_combined.tex` (3
  sorteos, primary spec).
- Cleanup + final summary listing.

Caveat in table footnote: all three placebos are 2023 sorteos, so
`n_kids_post` only spans 2024.

### In-flight results
- Nov 23 placebo: `n_kids_post` ITT (a+pre) = 0.0043 (SE 0.0127),
  cm = 0.0195. All three specs basically null — consistent with the
  placebo expectation (no real effect when credits not disbursed).
- Sep 26 DU and Dec 4 DU: script still running (background task
  `bbrxgujom`).

### Open
- Verify Sep 26 / Dec 4 fertility ITT once script finishes.
- Commit + push do-file (GitHub) and tables (Overleaf).
- Decide with Franco whether to `\input` `placebo_hijos_combined`
  into paper_new.tex Robustness section.
