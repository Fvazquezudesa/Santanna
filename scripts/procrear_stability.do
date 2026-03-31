/*==============================================================================
  PROCREAR — Income Stability Analysis

  Tests whether PROCREAR credit receipt reduces income variability and
  increases employment stability post-lottery.

  Mechanism: mortgage payments create incentives for stable employment.

  Outcomes:
    1. cv_wage       — Coefficient of variation of monthly wages (SD/mean)
    2. sd_wage       — Standard deviation of monthly wages
    3. pct_employed  — Proportion of months with formal employment
    4. any_gap       — Dummy: any month without formal employment
    5. n_transitions — Number of employment <-> non-employment transitions
    6. n_employers   — Count of distinct employers (CUITs) from raw SIPA

  Two time windows:
    A. 24 months post-sorteo (comparable across cohorts)
    B. All available months post-sorteo

  REQUIRES: procrear_labor_v2.do Steps 1-4
            (produces cross_section_v2.dta, sipa_panel.dta)

  Table prefix: stab24_ (24-month window), stabfull_ (full window)
==============================================================================*/



clear all
set more off
set matsize 10000

* --- PROJECT PATHS ------------------------------------------------------------
global root "/Users/francomartinvazquez/Dropbox (Personal)/Procrear Santanna"
global data "$root/DATA"
global tables "$root/Procrear/tables"
global temp "$root/TEMP"

cap mkdir "$tables"


/*==============================================================================
  STEP 1: BUILD STABILITY OUTCOMES — 24-MONTH WINDOW

  Strategy: expand each sorteo row to 24 monthly rows, merge with SIPA,
  compute stability measures from the resulting panel.
==============================================================================*/

di as text _n "=== STEP 1: Stability outcomes (24-month window) ===" _n

* Load cross-section and assign row IDs
use "$temp/cross_section_v2.dta", clear
gen long row_id = _n
keep row_id id_anon sorteo_month
local N_rows = _N
di as text "Cross-section rows: `N_rows'"

* Expand to 24 monthly rows per sorteo inscription
expand 24
sort row_id
by row_id: gen int month_offset = _n
gen periodo_month = sorteo_month + month_offset
format periodo_month %tm

di as text "Expanded panel (24m): " _N " rows"

* Merge with SIPA to identify employed months
* sipa_panel is unique on (id_anon, periodo_month) — only has employed months
merge m:1 id_anon periodo_month using "$temp/sipa_panel.dta", ///
    keep(master match) keepusing(total_wage)

* Employed = found in SIPA that month
gen byte employed = (_merge == 3)
gen double wage = total_wage if _merge == 3
replace wage = 0 if _merge == 1
drop _merge total_wage

* --- Compute transitions ---
sort row_id periodo_month
by row_id: gen byte _transition = 0 if _n == 1
by row_id: replace _transition = (employed != employed[_n-1]) if _n > 1

* --- Collapse to summary stats per row_id ---
gen double wage_sq = wage^2
* Employed-months-only wage variables (for intensive-margin CV)
gen double wage_emp = wage if employed == 1
gen double wage_emp_sq = wage_emp^2

collapse (mean) pct_employed_24=employed mean_wage_24=wage ///
         (sum) sum_sq_24=wage_sq sum_wage_24=wage n_transitions_24=_transition ///
         (mean) mean_wage_emp_24=wage_emp ///
         (sum) sum_sq_emp_24=wage_emp_sq ///
         (count) n_emp_months_24=wage_emp, ///
         by(row_id)

* SD (population): sqrt(E[X^2] - E[X]^2)
gen double var_24 = sum_sq_24 / 24 - mean_wage_24^2
replace var_24 = 0 if var_24 < 0  // numerical precision
gen double sd_wage_24 = sqrt(var_24)

* CV = SD / mean (undefined when mean = 0)
gen double cv_wage_24 = sd_wage_24 / mean_wage_24 if mean_wage_24 > 0

* Employed-months-only SD and CV (intensive margin, excludes zero-wage months)
gen double var_emp_24 = sum_sq_emp_24 / n_emp_months_24 - mean_wage_emp_24^2 if n_emp_months_24 >= 2
replace var_emp_24 = 0 if var_emp_24 < 0 & var_emp_24 != .
gen double sd_wage_emp_24 = sqrt(var_emp_24)
gen double cv_wage_emp_24 = sd_wage_emp_24 / mean_wage_emp_24 if mean_wage_emp_24 > 0 & n_emp_months_24 >= 2

* Any gap = not always employed
gen byte any_gap_24 = (pct_employed_24 < 1)

keep row_id cv_wage_24 sd_wage_24 cv_wage_emp_24 sd_wage_emp_24 pct_employed_24 any_gap_24 n_transitions_24

di as text _n "24-month outcomes computed."
sum cv_wage_24 sd_wage_24 pct_employed_24 any_gap_24 n_transitions_24

save "$temp/_stab_outcomes_24m.dta", replace


/*==============================================================================
  STEP 2: BUILD STABILITY OUTCOMES — FULL WINDOW

  Same approach, but uses all available post-sorteo months.
  Window length varies by sorteo date.
==============================================================================*/

di as text _n "=== STEP 2: Stability outcomes (full window) ===" _n

* Find last available SIPA month
use "$temp/sipa_panel.dta", clear
quietly sum periodo_month
local last_sipa = r(max)
di as text "Last SIPA month: " %tm `last_sipa'

* Load cross-section with row IDs
use "$temp/cross_section_v2.dta", clear
gen long row_id = _n
keep row_id id_anon sorteo_month

* Number of post-sorteo months per row
gen int n_months = `last_sipa' - sorteo_month
di as text "Post-sorteo months range:"
sum n_months

* Expand to full window
expand n_months
sort row_id
by row_id: gen int month_offset = _n
gen periodo_month = sorteo_month + month_offset
format periodo_month %tm

di as text "Expanded panel (full): " _N " rows"

* Merge with SIPA
merge m:1 id_anon periodo_month using "$temp/sipa_panel.dta", ///
    keep(master match) keepusing(total_wage)

gen byte employed = (_merge == 3)
gen double wage = total_wage if _merge == 3
replace wage = 0 if _merge == 1
drop _merge total_wage

* Transitions
sort row_id periodo_month
by row_id: gen byte _transition = 0 if _n == 1
by row_id: replace _transition = (employed != employed[_n-1]) if _n > 1

* Collapse
gen double wage_sq = wage^2
gen double wage_emp = wage if employed == 1
gen double wage_emp_sq = wage_emp^2

collapse (mean) pct_employed_full=employed mean_wage_full=wage ///
         (sum) sum_sq_full=wage_sq sum_wage_full=wage n_transitions_full=_transition ///
         (count) T_full=wage ///
         (mean) mean_wage_emp_full=wage_emp ///
         (sum) sum_sq_emp_full=wage_emp_sq ///
         (count) n_emp_months_full=wage_emp, ///
         by(row_id)

* SD and CV
gen double var_full = sum_sq_full / T_full - mean_wage_full^2
replace var_full = 0 if var_full < 0
gen double sd_wage_full = sqrt(var_full)
gen double cv_wage_full = sd_wage_full / mean_wage_full if mean_wage_full > 0

* Employed-months-only SD and CV (intensive margin)
gen double var_emp_full = sum_sq_emp_full / n_emp_months_full - mean_wage_emp_full^2 if n_emp_months_full >= 2
replace var_emp_full = 0 if var_emp_full < 0 & var_emp_full != .
gen double sd_wage_emp_full = sqrt(var_emp_full)
gen double cv_wage_emp_full = sd_wage_emp_full / mean_wage_emp_full if mean_wage_emp_full > 0 & n_emp_months_full >= 2

gen byte any_gap_full = (pct_employed_full < 1)

keep row_id cv_wage_full sd_wage_full cv_wage_emp_full sd_wage_emp_full pct_employed_full any_gap_full n_transitions_full

di as text _n "Full-window outcomes computed."
sum cv_wage_full sd_wage_full pct_employed_full any_gap_full n_transitions_full

save "$temp/_stab_outcomes_full.dta", replace


/*==============================================================================
  STEP 2B: COMPUTE DISTINCT EMPLOYER COUNT FROM RAW SIPA

  The collapsed sipa_panel.dta loses employer (CUIT) info.
  Go back to raw Data_SIPA.dta to count distinct CUITs per person × sorteo
  within each time window.
==============================================================================*/

di as text _n "=== STEP 2B: Distinct employer count ===" _n

* Build SIPA CUIT panel: unique (id_anon, periodo_month, cuit)
use "$data/Data_SIPA.dta", clear

* Filter to analysis sample
preserve
use "$temp/cross_section_v2.dta", clear
keep id_anon
duplicates drop
save "$temp/_stab_persons2.dta", replace
restore

merge m:1 id_anon using "$temp/_stab_persons2.dta", keep(match) nogenerate
erase "$temp/_stab_persons2.dta"

* Create monthly date
gen int _y = floor(mes / 100)
gen int _m = mod(mes, 100)
gen periodo_month = ym(_y, _m)
format periodo_month %tm
drop _y _m

* Keep only what we need and deduplicate
keep id_anon periodo_month cuit
duplicates drop

di as text "SIPA CUIT panel: " _N " unique (person, month, employer) records"
save "$temp/_sipa_cuit.dta", replace

* --- 24-month window: count distinct CUITs per row_id ---

di as text _n "--- Counting employers (24m window) ---"

use "$temp/cross_section_v2.dta", clear
gen long row_id = _n
keep row_id id_anon sorteo_month

joinby id_anon using "$temp/_sipa_cuit.dta"
keep if periodo_month > sorteo_month & periodo_month <= sorteo_month + 24

di as text "Records in 24m window: " _N

* Count distinct employers per row_id
duplicates drop row_id cuit, force
collapse (count) n_employers_24 = cuit, by(row_id)

di as text "Rows with employer data: " _N
sum n_employers_24
save "$temp/_n_employers_24.dta", replace

* --- Full window: count distinct CUITs per row_id ---

di as text _n "--- Counting employers (full window) ---"

use "$temp/cross_section_v2.dta", clear
gen long row_id = _n
keep row_id id_anon sorteo_month

joinby id_anon using "$temp/_sipa_cuit.dta"
keep if periodo_month > sorteo_month

di as text "Records in full window: " _N

duplicates drop row_id cuit, force
collapse (count) n_employers_full = cuit, by(row_id)

di as text "Rows with employer data: " _N
sum n_employers_full
save "$temp/_n_employers_full.dta", replace

erase "$temp/_sipa_cuit.dta"


/*==============================================================================
  STEP 2C: PRE-STABLE INDICATOR

  Flag persons continuously employed in the 12 months before sorteo.
  This is a pre-treatment characteristic — no selection bias.
  Used for "attached workers" CV subsample.
==============================================================================*/

di as text _n "=== STEP 2C: Pre-stable indicator (12m pre-sorteo) ===" _n

use "$temp/cross_section_v2.dta", clear
gen long row_id = _n
keep row_id id_anon sorteo_month

* Expand to 12 pre-sorteo months
expand 12
sort row_id
by row_id: gen int month_offset = -_n
gen periodo_month = sorteo_month + month_offset
format periodo_month %tm

* Merge with SIPA to check employment
merge m:1 id_anon periodo_month using "$temp/sipa_panel.dta", ///
    keep(master match) keepusing(total_wage)
gen byte employed = (_merge == 3)
drop _merge total_wage

* Count employed months in 12m pre-sorteo window
collapse (sum) pre_emp_months = employed, by(row_id)

* Pre-stable = employed all 12 months before sorteo
gen byte pre_stable = (pre_emp_months == 12)

di as text "Pre-stable workers:"
tab pre_stable

keep row_id pre_stable
save "$temp/_pre_stable.dta", replace


/*==============================================================================
  STEP 3: MERGE OUTCOMES TO CROSS-SECTION

  Combine stability outcomes with sorteo-level data + pre-treatment controls.
==============================================================================*/

di as text _n "=== STEP 3: Merging outcomes to cross-section ===" _n

use "$temp/cross_section_v2.dta", clear
gen long row_id = _n

merge 1:1 row_id using "$temp/_stab_outcomes_24m.dta", nogenerate
merge 1:1 row_id using "$temp/_stab_outcomes_full.dta", nogenerate
merge 1:1 row_id using "$temp/_n_employers_24.dta", nogenerate
merge 1:1 row_id using "$temp/_n_employers_full.dta", nogenerate
merge 1:1 row_id using "$temp/_pre_stable.dta", nogenerate

* Fill missing stability outcomes for persons never in SIPA during window
foreach sfx in "24" "full" {
    replace sd_wage_`sfx' = 0 if sd_wage_`sfx' == .
    replace pct_employed_`sfx' = 0 if pct_employed_`sfx' == .
    replace any_gap_`sfx' = 1 if any_gap_`sfx' == .
    replace n_transitions_`sfx' = 0 if n_transitions_`sfx' == .
    replace n_employers_`sfx' = 0 if n_employers_`sfx' == .
    * cv_wage and cv_wage_emp remain missing for mean=0 / <2 employed months
}
replace pre_stable = 0 if pre_stable == .

di as text _n "=== Sample summary ==="
di as text "N: " _N
di as text _n "24-month window:"
sum cv_wage_24 sd_wage_24 cv_wage_emp_24 sd_wage_emp_24 pct_employed_24 any_gap_24 n_transitions_24 n_employers_24
di as text _n "Full window:"
sum cv_wage_full sd_wage_full cv_wage_emp_full sd_wage_emp_full pct_employed_full any_gap_full n_transitions_full n_employers_full
di as text _n "Pre-stable indicator:"
tab pre_stable

save "$temp/cross_section_stability.dta", replace

erase "$temp/_stab_outcomes_24m.dta"
erase "$temp/_stab_outcomes_full.dta"
erase "$temp/_n_employers_24.dta"
erase "$temp/_n_employers_full.dta"
erase "$temp/_pre_stable.dta"


/*==============================================================================
  STEP 4: POOLED ESTIMATION — ITT & IV

  For each window (24m, full), run ITT and IV with 5 stability outcomes.
  Each table: 5 columns (CV, SD, Pct Emp, Any Gap, Transitions).
==============================================================================*/

di as text _n "=== STEP 4: Pooled Estimation ===" _n

use "$temp/cross_section_stability.dta", clear

foreach win in "24" "full" {

    if "`win'" == "24"   local win_note "24-month window post-sorteo."
    if "`win'" == "full" local win_note "All available months post-sorteo."

    foreach ctl in "noctl" "ctl" {
        if "`ctl'" == "noctl" local controls ""
        if "`ctl'" == "noctl" local note_ctl "No pre-treatment controls."
        if "`ctl'" == "ctl"   local controls "pre_wage pre_employed edad mujer"
        if "`ctl'" == "ctl"   local note_ctl "Controls: pre-wage, pre-employment, age, gender."

        * ---- ITT ----
        eststo clear

        eststo s_cv: reghdfe cv_wage_`win' ganador `controls', ///
            absorb(sorteo_fe) cluster(id_anon)
        quietly sum cv_wage_`win' if ganador == 0 & e(sample)
        estadd scalar cmean = r(mean)

        eststo s_sd: reghdfe sd_wage_`win' ganador `controls', ///
            absorb(sorteo_fe) cluster(id_anon)
        quietly sum sd_wage_`win' if ganador == 0
        estadd scalar cmean = r(mean)

        eststo s_pct: reghdfe pct_employed_`win' ganador `controls', ///
            absorb(sorteo_fe) cluster(id_anon)
        quietly sum pct_employed_`win' if ganador == 0
        estadd scalar cmean = r(mean)

        eststo s_gap: reghdfe any_gap_`win' ganador `controls', ///
            absorb(sorteo_fe) cluster(id_anon)
        quietly sum any_gap_`win' if ganador == 0
        estadd scalar cmean = r(mean)

        eststo s_tr: reghdfe n_transitions_`win' ganador `controls', ///
            absorb(sorteo_fe) cluster(id_anon)
        quietly sum n_transitions_`win' if ganador == 0
        estadd scalar cmean = r(mean)

        eststo s_emp: reghdfe n_employers_`win' ganador `controls', ///
            absorb(sorteo_fe) cluster(id_anon)
        quietly sum n_employers_`win' if ganador == 0
        estadd scalar cmean = r(mean)

        esttab s_* using "$tables/stab`win'_itt_`ctl'.tex", replace ///
            keep(ganador) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean N r2, labels("Control mean" "Observations" "R-squared") ///
                  fmt(%9.3f %9.0fc %9.3f)) ///
            mtitles("CV Wage" "SD Wage" "Pct Employed" "Any Gap" "Transitions" "Employers") ///
            title("ITT — Income Stability (`win_note')") ///
            note("`note_ctl' `win_note' SE clustered at person level. Sorteo FE absorbed.") ///
            substitute(`"\begin{tabular}"' `"\small\begin{tabular}"' `"\multicolumn{7}{l}{"' `"\multicolumn{7}{p{0.95\textwidth}}{"') ///
            label

        * ---- IV ----
        eststo clear

        eststo s_cv: ivreghdfe cv_wage_`win' `controls' ///
            (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
        quietly sum cv_wage_`win' if ganador == 0 & e(sample)
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)

        eststo s_sd: ivreghdfe sd_wage_`win' `controls' ///
            (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
        quietly sum sd_wage_`win' if ganador == 0
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)

        eststo s_pct: ivreghdfe pct_employed_`win' `controls' ///
            (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
        quietly sum pct_employed_`win' if ganador == 0
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)

        eststo s_gap: ivreghdfe any_gap_`win' `controls' ///
            (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
        quietly sum any_gap_`win' if ganador == 0
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)

        eststo s_tr: ivreghdfe n_transitions_`win' `controls' ///
            (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
        quietly sum n_transitions_`win' if ganador == 0
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)

        eststo s_emp: ivreghdfe n_employers_`win' `controls' ///
            (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
        quietly sum n_employers_`win' if ganador == 0
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)

        esttab s_* using "$tables/stab`win'_iv_`ctl'.tex", replace ///
            keep(receptor) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
                  fmt(%9.3f %9.1f %9.0fc)) ///
            mtitles("CV Wage" "SD Wage" "Pct Employed" "Any Gap" "Transitions" "Employers") ///
            title("IV — Income Stability (`win_note')") ///
            note("2SLS. Instrument: ganador. `note_ctl' `win_note' SE clustered at person level. Sorteo FE absorbed.") ///
            substitute(`"\begin{tabular}"' `"\label{tab:stab`win'}\small\begin{tabular}"' `"\multicolumn{7}{l}{"' `"\multicolumn{7}{p{0.95\textwidth}}{"') ///
            label
    }
}


/*==============================================================================
  STEP 4B: CV WAGE VARIANTS — INTENSIVE MARGIN AND PRE-STABLE

  Three measures to decompose wage variability:
    1. CV (all months)      — includes zeros from non-employment
    2. CV (employed only)   — intensive margin, excludes zero-wage months
    3. CV (pre-stable)      — all months, restricted to workers employed
                               12 consecutive months pre-sorteo
==============================================================================*/

di as text _n "=== STEP 4B: CV Wage Variants ===" _n

use "$temp/cross_section_stability.dta", clear

foreach win in "24" "full" {

    if "`win'" == "24"   local win_note "24-month window post-sorteo."
    if "`win'" == "full" local win_note "All available months post-sorteo."

    foreach ctl in "noctl" "ctl" {
        if "`ctl'" == "noctl" local controls ""
        if "`ctl'" == "noctl" local note_ctl "No pre-treatment controls."
        if "`ctl'" == "ctl"   local controls "pre_wage pre_employed edad mujer"
        if "`ctl'" == "ctl"   local note_ctl "Controls: pre-wage, pre-employment, age, gender."

        * ---- ITT ----
        eststo clear

        eststo s_all: reghdfe cv_wage_`win' ganador `controls', ///
            absorb(sorteo_fe) cluster(id_anon)
        quietly sum cv_wage_`win' if ganador == 0 & e(sample)
        estadd scalar cmean = r(mean)

        eststo s_emp: reghdfe cv_wage_emp_`win' ganador `controls', ///
            absorb(sorteo_fe) cluster(id_anon)
        quietly sum cv_wage_emp_`win' if ganador == 0 & e(sample)
        estadd scalar cmean = r(mean)

        eststo s_pre: reghdfe cv_wage_`win' ganador `controls' ///
            if pre_stable == 1, absorb(sorteo_fe) cluster(id_anon)
        quietly sum cv_wage_`win' if ganador == 0 & pre_stable == 1 & e(sample)
        estadd scalar cmean = r(mean)

        esttab s_* using "$tables/stabcv`win'_itt_`ctl'.tex", replace ///
            keep(ganador) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean N r2, labels("Control mean" "Observations" "R-squared") ///
                  fmt(%9.3f %9.0fc %9.3f)) ///
            mtitles("CV (all months)" "CV (employed only)" "CV (pre-stable)") ///
            title("ITT --- CV Wage Variants (`win_note')") ///
            note("`note_ctl' `win_note' Col 1: CV over all months (zeros incl). Col 2: CV over employed months only. Col 3: workers employed 12 consecutive months pre-sorteo. SE clustered at person level. Sorteo FE absorbed.") ///
            label

        * ---- IV ----
        eststo clear

        eststo s_all: ivreghdfe cv_wage_`win' `controls' ///
            (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
        quietly sum cv_wage_`win' if ganador == 0 & e(sample)
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)

        eststo s_emp: ivreghdfe cv_wage_emp_`win' `controls' ///
            (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
        quietly sum cv_wage_emp_`win' if ganador == 0 & e(sample)
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)

        eststo s_pre: ivreghdfe cv_wage_`win' `controls' ///
            (receptor = ganador) if pre_stable == 1, absorb(sorteo_fe) cluster(id_anon)
        quietly sum cv_wage_`win' if ganador == 0 & pre_stable == 1 & e(sample)
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)

        esttab s_* using "$tables/stabcv`win'_iv_`ctl'.tex", replace ///
            keep(receptor) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
                  fmt(%9.3f %9.1f %9.0fc)) ///
            mtitles("CV (all months)" "CV (employed only)" "CV (pre-stable)") ///
            title("IV --- CV Wage Variants (`win_note')") ///
            note("2SLS. Instrument: ganador. `note_ctl' `win_note' Col 1: CV over all months (zeros incl). Col 2: CV over employed months only. Col 3: workers employed 12 consecutive months pre-sorteo. SE clustered at person level. Sorteo FE absorbed.") ///
            label
    }
}


/*==============================================================================
  STEP 5: ESTIMATION BY CREDIT TYPE GROUP

  For each tipo_grupo, produce ITT and IV stability tables,
  both windows, with and without controls.
==============================================================================*/

di as text _n "=== STEP 5: Estimation by Credit Type ===" _n

use "$temp/cross_section_stability.dta", clear

local grp_names `" "DU" "Construccion" "Lotes" "'

forvalues g = 1/3 {
    local grp : word `g' of `grp_names'
    local grp_lower = lower("`grp'")

    di as text _n "============================================"
    di as text "  Credit type: `grp' (tipo_grupo == `g')"
    di as text "============================================" _n

    foreach win in "24" "full" {

        if "`win'" == "24"   local win_note "24-month window."
        if "`win'" == "full" local win_note "All months post-sorteo."

        foreach ctl in "noctl" "ctl" {
            if "`ctl'" == "noctl" local controls ""
            if "`ctl'" == "noctl" local note_ctl "No pre-treatment controls."
            if "`ctl'" == "ctl"   local controls "pre_wage pre_employed edad mujer"
            if "`ctl'" == "ctl"   local note_ctl "Controls: pre-wage, pre-employment, age, gender."

            * ---- ITT ----
            eststo clear

            capture eststo s_cv: reghdfe cv_wage_`win' ganador `controls' ///
                if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                quietly sum cv_wage_`win' if ganador == 0 & tipo_grupo == `g' & e(sample)
                estadd scalar cmean = r(mean)
            }

            capture eststo s_sd: reghdfe sd_wage_`win' ganador `controls' ///
                if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                quietly sum sd_wage_`win' if ganador == 0 & tipo_grupo == `g'
                estadd scalar cmean = r(mean)
            }

            capture eststo s_pct: reghdfe pct_employed_`win' ganador `controls' ///
                if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                quietly sum pct_employed_`win' if ganador == 0 & tipo_grupo == `g'
                estadd scalar cmean = r(mean)
            }

            capture eststo s_gap: reghdfe any_gap_`win' ganador `controls' ///
                if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                quietly sum any_gap_`win' if ganador == 0 & tipo_grupo == `g'
                estadd scalar cmean = r(mean)
            }

            capture eststo s_tr: reghdfe n_transitions_`win' ganador `controls' ///
                if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                quietly sum n_transitions_`win' if ganador == 0 & tipo_grupo == `g'
                estadd scalar cmean = r(mean)
            }

            capture eststo s_emp: reghdfe n_employers_`win' ganador `controls' ///
                if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                quietly sum n_employers_`win' if ganador == 0 & tipo_grupo == `g'
                estadd scalar cmean = r(mean)
            }

            esttab s_* using "$tables/stab`win'_type_`grp_lower'_itt_`ctl'.tex", replace ///
                keep(ganador) se(%9.4f) b(%9.4f) ///
                star(* 0.10 ** 0.05 *** 0.01) ///
                stats(cmean N r2, labels("Control mean" "Observations" "R-squared") ///
                      fmt(%9.3f %9.0fc %9.3f)) ///
                mtitles("CV Wage" "SD Wage" "Pct Employed" "Any Gap" "Transitions" "Employers") ///
                title("ITT — Income Stability (`grp', `win_note')") ///
                note("`note_ctl' `win_note' SE clustered at person level. Sorteo FE absorbed.") ///
                label

            * ---- IV ----
            eststo clear

            capture eststo s_cv: ivreghdfe cv_wage_`win' `controls' ///
                (receptor = ganador) if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                quietly sum cv_wage_`win' if ganador == 0 & tipo_grupo == `g' & e(sample)
                estadd scalar cmean = r(mean)
                estadd scalar fs_F = e(widstat)
            }

            capture eststo s_sd: ivreghdfe sd_wage_`win' `controls' ///
                (receptor = ganador) if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                quietly sum sd_wage_`win' if ganador == 0 & tipo_grupo == `g'
                estadd scalar cmean = r(mean)
                estadd scalar fs_F = e(widstat)
            }

            capture eststo s_pct: ivreghdfe pct_employed_`win' `controls' ///
                (receptor = ganador) if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                quietly sum pct_employed_`win' if ganador == 0 & tipo_grupo == `g'
                estadd scalar cmean = r(mean)
                estadd scalar fs_F = e(widstat)
            }

            capture eststo s_gap: ivreghdfe any_gap_`win' `controls' ///
                (receptor = ganador) if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                quietly sum any_gap_`win' if ganador == 0 & tipo_grupo == `g'
                estadd scalar cmean = r(mean)
                estadd scalar fs_F = e(widstat)
            }

            capture eststo s_tr: ivreghdfe n_transitions_`win' `controls' ///
                (receptor = ganador) if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                quietly sum n_transitions_`win' if ganador == 0 & tipo_grupo == `g'
                estadd scalar cmean = r(mean)
                estadd scalar fs_F = e(widstat)
            }

            capture eststo s_emp: ivreghdfe n_employers_`win' `controls' ///
                (receptor = ganador) if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                quietly sum n_employers_`win' if ganador == 0 & tipo_grupo == `g'
                estadd scalar cmean = r(mean)
                estadd scalar fs_F = e(widstat)
            }

            esttab s_* using "$tables/stab`win'_type_`grp_lower'_iv_`ctl'.tex", replace ///
                keep(receptor) se(%9.4f) b(%9.4f) ///
                star(* 0.10 ** 0.05 *** 0.01) ///
                stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
                      fmt(%9.3f %9.1f %9.0fc)) ///
                mtitles("CV Wage" "SD Wage" "Pct Employed" "Any Gap" "Transitions" "Employers") ///
                title("IV — Income Stability (`grp', `win_note')") ///
                note("2SLS. Instrument: ganador. `note_ctl' `win_note' SE clustered at person level. Sorteo FE absorbed.") ///
                label
        }
    }

    di as text _n "  `grp' complete."
}


/*==============================================================================
  SUMMARY
==============================================================================*/

di as text _n(3) "================================================"
di as text       "  PROCREAR Income Stability Analysis — Complete"
di as text       "================================================"
di as text _n "Outcomes: CV Wage, SD Wage, Pct Employed, Any Gap, Transitions, Employers"
di as text "         CV Wage (employed only), CV Wage (pre-stable workers)"
di as text "Windows: 24-month and full post-sorteo"
di as text "Unit of observation: person x sorteo inscription"
di as text "SE clustered at person level throughout"
di as text _n "Tables saved to: $tables/"
di as text "  --- Pooled (2 windows x ITT/IV x noctl/ctl = 8 tables) ---"
di as text "  stab24_itt_*.tex / stab24_iv_*.tex"
di as text "  stabfull_itt_*.tex / stabfull_iv_*.tex"
di as text "  --- CV Variants (2 windows x ITT/IV x noctl/ctl = 8 tables) ---"
di as text "  stabcv24_itt_*.tex / stabcv24_iv_*.tex"
di as text "  stabcvfull_itt_*.tex / stabcvfull_iv_*.tex"
di as text "  --- By credit type (2 windows x 3 types x ITT/IV x noctl/ctl = 24 tables) ---"
di as text "  stab24_type_{grp}_itt_*.tex / stab24_type_{grp}_iv_*.tex"
di as text "  stabfull_type_{grp}_itt_*.tex / stabfull_type_{grp}_iv_*.tex"
