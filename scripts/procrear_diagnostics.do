/*==============================================================================
  PROCREAR — Lottery Design Diagnostics & Randomization Inference

  This do-file addresses best practices from the school-choice lottery literature
  (Cullen-Jacob-Levitt 2006; Deming 2014; Abdulkadiroglu-Angrist-Narita-Pathak
  2017; Bugni-Canay-Shaikh 2018/2019; Fogarty 2018) for settings with many
  small strata and varying treatment probabilities.

  REQUIRES: $data/Data_sorteos.dta, $data/Data_SIPA.dta, $temp/deflator.dta
            (deflator from procrear_labor_v2.do Step 1, or build independently)

  ===========================================================================
  OUTLINE
  ===========================================================================

  STEP 0: Build analysis sample and balance variables from raw data
          - Load Data_sorteos → build sorteo_fe, filter, derive edad
          - Merge SIPA at sorteo_month → pre_wage, pre_employed, mujer
          - Balance variables: edad, mujer, pre_employed, pre_wage
          - Output: $temp/_diag_sample.dta

  STEP 1: Lottery design descriptives
          - N sorteos, sorteo sizes, win rates, implied weights
          - Figures: histograms of sorteo size, win rate, weight

  STEP 2: Joint balance F-test (conditional on sorteo FE)
          - reghdfe each balance variable on ganador with sorteo FE
          - Joint Wald test of all coefficients = 0

  STEP 3: Simulation-based balance test (a la Cullen et al. 2006)
          - 1000 permutations: reassign ganador within each sorteo_fe
          - For each permutation, regress each balance var on fake ganador
          - Compare actual t-stats to permutation distribution
          - Report: empirical p-values + histogram overlay with N(0,1)

  STEP 4: Randomization inference for main outcomes
          - 1000 permutations of ganador within sorteo_fe
          - Re-estimate ITT for key outcomes
          - Report: RI p-values alongside conventional p-values

  STEP 5: Balanced-lottery subsample (a la Hoxby-Murarka)
          - Restrict to sorteos that pass a within-sorteo joint balance test
          - Re-estimate ITT on this restricted sample
          - Compare to full-sample results

  STEP 6: Sorteo-level weight diagnostics
          - What sorteos drive the estimate? (effective weights)
          - Sensitivity to dropping high-influence sorteos

  STEP 7: ITT with explicit weighting schemes
          - (a) Precision-weighted: w = N_j * p_j * (1-p_j)  [≈ reghdfe]
          - (b) Equal weight per sorteo: w = 1/J
          - (c) Population-weighted: w = N_j
          - Scatter + histogram of within-sorteo effects
          - LaTeX table for paper

==============================================================================*/

clear all
set more off
set matsize 10000
set seed 20260330

* --- PROJECT PATHS ------------------------------------------------------------
global root "/Users/francomartinvazquez/Dropbox (Personal)/Procrear Santanna"
global data "$root/DATA"
global tables "$root/Procrear/tables"
global figures "$root/Procrear/figures"
global temp "$root/TEMP"

cap mkdir "$tables"
cap mkdir "$figures"
cap mkdir "$temp"

* Number of permutation iterations (increase to 5000+ for final version)
local n_perms = 1000


/*==============================================================================
  STEP 0: BUILD ANALYSIS SAMPLE AND BALANCE VARIABLES FROM RAW DATA

  Constructs everything from Data_sorteos.dta and Data_SIPA.dta.
  Balance variables: edad, mujer, pre_employed, pre_wage
  Output: $temp/_diag_sample.dta
==============================================================================*/

di as text _n "=== STEP 0: Building analysis sample from raw data ===" _n

* ---- 0a. Load Data_sorteos and build sorteo structure -----------------------

use "$data/Data_sorteos.dta", clear
di as text "Raw sorteos: N = " _N

* CUIL prefix → median birth date mapping (built BEFORE filtering)
preserve
    keep cuil fnacimiento
    keep if fnacimiento != .
    gen str3 _pfx_str = substr(cuil, 3, 3)
    destring _pfx_str, gen(dni_prefix) force
    keep if dni_prefix != . & dni_prefix < 900
    gen double fnac_num = fnacimiento
    collapse (median) med_fnac = fnac_num, by(dni_prefix)
    gen med_birth_date = med_fnac
    format med_birth_date %td
    gen med_birth_year  = year(med_birth_date)
    gen med_birth_month = month(med_birth_date)
    tempfile prefix_map
    save `prefix_map'
restore

* Sorteo FE grouping variables: fill missings
replace desarrollourbanistico = 0 if desarrollourbanistico == .
replace tipologia = 0 if tipologia == .
replace cupo = 0 if cupo == .

egen sorteo_fe = group(fecha_sorteo tipo desarrollourbanistico tipologia cupo)

* Credit type groups
gen tipo_grupo = .
replace tipo_grupo = 1 if tipo == 5                              // DU
replace tipo_grupo = 2 if inlist(tipo, 2, 3, 4)                  // Construccion
replace tipo_grupo = 3 if inlist(tipo, 6)                        // Lotes
replace tipo_grupo = 4 if inlist(tipo, 1, 8, 9, 10, 11, 12, 13) // Refaccion
label define tipo_grupo_lbl 1 "DU" 2 "Construccion" 3 "Lotes" 4 "Refaccion"
label values tipo_grupo tipo_grupo_lbl

* Drop Refaccion
di as text "Dropping Refaccion..."
drop if tipo_grupo == 4

* Drop degenerate sorteos (winrate == 0 or 1)
bys sorteo_fe: egen _winrate = mean(ganador)
di as text "Dropping degenerate sorteos..."
count if _winrate == 0 | _winrate == 1
drop if _winrate == 0 | _winrate == 1
drop _winrate

* Time variables
gen sorteo_month = mofd(fecha_sorteo)
format sorteo_month %tm
gen cohort_year = year(fecha_sorteo)

* ---- 0b. Derive edad: CUIL prefix → fnacimiento → edad column --------------

gen str3 dni_prefix_str = substr(cuil, 3, 3)
destring dni_prefix_str, gen(dni_prefix) force

merge m:1 dni_prefix using `prefix_map', keep(master match) nogenerate

gen sorteo_year      = year(fecha_sorteo)
gen sorteo_month_num = month(fecha_sorteo)

rename edad edad_original

* Primary: CUIL prefix → median birth year
gen edad = sorteo_year - med_birth_year
replace edad = edad - 1 if sorteo_month_num < med_birth_month & edad != .

* Fallback 1: individual fnacimiento
replace edad = sorteo_year - year(fnacimiento) if edad == . & fnacimiento != .
replace edad = edad - 1 if sorteo_month_num < month(fnacimiento) & edad != . & med_birth_year == .

* Fallback 2: original edad column
replace edad = edad_original if edad == . & edad_original != .

drop edad_original dni_prefix_str dni_prefix med_fnac med_birth_date ///
     med_birth_year med_birth_month sorteo_year sorteo_month_num fnacimiento cuil

di as text "Age (edad) non-missing: "
count if edad != .
di as text "  " r(N) " of " _N " (" %4.1f 100*r(N)/_N "%)"

* ---- 0c. Keep what we need for merging --------------------------------------

keep id_anon ganador receptor sorteo_fe tipo tipo_grupo sorteo_month ///
     cohort_year fecha_sorteo edad genero

save "$temp/_diag_sorteo_base.dta", replace

* ---- 0d. Build SIPA data at sorteo_month for pre_wage, pre_employed, mujer --

* Get person list
preserve
    keep id_anon
    duplicates drop
    tempfile _plist
    save `_plist'
restore

* Load SIPA, filter to analysis persons
use "$data/Data_SIPA.dta", clear
merge m:1 id_anon using `_plist', keep(match) nogenerate
di as text "SIPA records for analysis sample: N = " _N

* Create monthly date
gen int _y = floor(mes / 100)
gen int _m = mod(mes, 100)
gen periodo_month = ym(_y, _m)
format periodo_month %tm
drop _y _m

* Deseasonalize (aguinaldo in months 6 and 12)
gen int cal_month = month(dofm(periodo_month))
gen double wage_desest = remuneracion
replace wage_desest = remuneracion / 1.5 if inlist(cal_month, 6, 12)
drop cal_month

* Deflate to constant prices
merge m:1 periodo_month using "$temp/deflator.dta", keep(master match) nogenerate
gen double real_wage = wage_desest / deflator
replace real_wage = 0 if wage_desest == .

* Collapse to person × month (sum wages across employers, keep mujer)
collapse (sum) total_wage = real_wage (firstnm) mujer, by(id_anon periodo_month)

* Rename for pre-treatment merge
rename total_wage pre_wage
gen byte pre_employed = 1

save "$temp/_diag_sipa_panel.dta", replace

* ---- 0e. Merge SIPA at sorteo_month onto sorteo base -----------------------

use "$temp/_diag_sorteo_base.dta", clear

* Create merge key
gen periodo_month = sorteo_month
format periodo_month %tm

merge m:1 id_anon periodo_month using "$temp/_diag_sipa_panel.dta", ///
    keep(master match) nogenerate
drop periodo_month

* Fill zeros for persons not in SIPA at sorteo month
replace pre_wage     = 0 if pre_wage == .
replace pre_employed = 0 if pre_employed == .

* ---- 0f. Construct mujer: SIPA first, then genero from sorteos --------------

* mujer comes from SIPA merge; fill missing from genero (1=mujer, 2=hombre)
replace mujer = (genero == 1) if mujer == . & genero != .
drop genero

di as text _n "=== Balance variable coverage ==="
di as text "edad:         " %9.0fc _N - missing(edad) " non-missing of " %9.0fc _N
di as text "mujer:        " %9.0fc _N - missing(mujer) " non-missing of " %9.0fc _N
di as text "pre_employed: " %9.0fc _N " (all filled, 0 = not in SIPA)"
di as text "pre_wage:     " %9.0fc _N " (all filled, 0 = not in SIPA)"

sum edad mujer pre_employed pre_wage

save "$temp/_diag_sample.dta", replace

* Clean up temp files
cap erase "$temp/_diag_sorteo_base.dta"
cap erase "$temp/_diag_sipa_panel.dta"

di as text _n "=== Step 0 complete. Sample saved to _diag_sample.dta ===" _n


/*==============================================================================
  STEP 1: LOTTERY DESIGN DESCRIPTIVES
==============================================================================*/

di as text _n "=== STEP 1: Lottery Design Descriptives ===" _n

use "$temp/_diag_sample.dta", clear

* --- Sorteo-level statistics ---
preserve

    bys sorteo_fe: egen n_sorteo = count(id_anon)
    bys sorteo_fe: egen n_winners = total(ganador)
    bys sorteo_fe: egen p_win = mean(ganador)
    gen weight_j = n_sorteo * p_win * (1 - p_win)

    * Collapse to sorteo level
    bys sorteo_fe: keep if _n == 1

    local n_sorteos = _N
    di as text _n "Number of non-degenerate sorteo cells: `n_sorteos'"

    di as text _n "=== Sorteo size distribution ==="
    sum n_sorteo, detail

    di as text _n "=== Win rate distribution ==="
    sum p_win, detail

    di as text _n "=== Implied weight N_j * p_j * (1-p_j) distribution ==="
    sum weight_j, detail

    * Top 10 sorteos by weight (these drive the estimate most)
    di as text _n "=== Top 20 sorteos by implied weight ==="
    gsort -weight_j
    list sorteo_fe n_sorteo n_winners p_win weight_j in 1/20, noobs

    * --- Figure: Histogram of sorteo sizes ---
    histogram n_sorteo, bin(50) ///
        title("Distribution of Lottery Cell Sizes") ///
        xtitle("Number of applicants per sorteo cell") ///
        ytitle("Density") ///
        note("N = `n_sorteos' non-degenerate sorteo cells.") ///
        color(navy%70) lcolor(navy)
    graph export "$figures/diag_sorteo_sizes.pdf", replace
    graph export "$figures/diag_sorteo_sizes.png", replace width(2400)

    * --- Figure: Histogram of win rates ---
    histogram p_win, bin(50) ///
        title("Distribution of Win Rates Across Sorteo Cells") ///
        xtitle("Probability of winning (within cell)") ///
        ytitle("Density") ///
        note("N = `n_sorteos' non-degenerate sorteo cells." ///
             "Cells with p=0 or p=1 excluded (degenerate).") ///
        color(cranberry%70) lcolor(cranberry)
    graph export "$figures/diag_winrates.pdf", replace
    graph export "$figures/diag_winrates.png", replace width(2400)

    * --- Figure: Histogram of implied weights ---
    histogram weight_j, bin(50) ///
        title("Distribution of Implied Regression Weights") ///
        xtitle("Weight = N{subscript:j} × p{subscript:j} × (1 − p{subscript:j})") ///
        ytitle("Density") ///
        note("Weight proportional to contribution to pooled ITT estimate." ///
             "Cullen, Jacob & Levitt (2006, Econometrica).") ///
        color(forest_green%70) lcolor(forest_green)
    graph export "$figures/diag_weights.pdf", replace
    graph export "$figures/diag_weights.png", replace width(2400)

    * --- Cumulative weight share ---
    gsort -weight_j
    gen cum_weight = sum(weight_j)
    gen total_weight = cum_weight[_N]
    gen cum_share = cum_weight / total_weight
    gen rank = _n

    * What fraction of sorteos account for 50%, 80%, 90% of the weight?
    di as text _n "=== Weight concentration ==="
    count if cum_share <= 0.50
    local n50 = r(N)
    di as text "Top `n50' sorteos (of `n_sorteos') account for 50% of weight"

    count if cum_share <= 0.80
    local n80 = r(N)
    di as text "Top `n80' sorteos account for 80% of weight"

    count if cum_share <= 0.90
    local n90 = r(N)
    di as text "Top `n90' sorteos account for 90% of weight"

    * --- Figure: Cumulative weight share ---
    twoway (line cum_share rank, lcolor(navy) lwidth(medthick)), ///
        title("Cumulative Weight Share by Sorteo Rank") ///
        xtitle("Sorteo rank (by weight, descending)") ///
        ytitle("Cumulative share of total weight") ///
        yline(0.5, lpattern(dash) lcolor(gray)) ///
        yline(0.8, lpattern(dash) lcolor(gray)) ///
        yline(0.9, lpattern(dash) lcolor(gray)) ///
        note("Top `n50' sorteos = 50% of weight; top `n80' = 80%; top `n90' = 90%.")
    graph export "$figures/diag_cum_weight.pdf", replace
    graph export "$figures/diag_cum_weight.png", replace width(2400)

restore


/*==============================================================================
  STEP 2: JOINT BALANCE F-TEST (conditional on sorteo FE)

  Regress each balance variable on ganador with sorteo FE absorbed,
  then compute a joint F-test across all variables.
  This is the pooled-conditional-on-assignment-cell balance test.
==============================================================================*/

di as text _n "=== STEP 2: Joint Balance F-test ===" _n

use "$temp/_diag_sample.dta", clear

* Balance variables: pre-treatment characteristics
local balvars "edad mujer pre_employed pre_wage"

* Store individual t-stats and p-values
matrix balance = J(`:word count `balvars'', 4, .)
matrix colnames balance = "Coef" "SE" "t" "p"
local rnames ""

local i = 0
foreach var of local balvars {
    local ++i
    quietly reghdfe `var' ganador, absorb(sorteo_fe) cluster(id_anon)
    matrix balance[`i', 1] = _b[ganador]
    matrix balance[`i', 2] = _se[ganador]
    matrix balance[`i', 3] = _b[ganador] / _se[ganador]
    matrix balance[`i', 4] = 2 * ttail(e(df_r), abs(_b[ganador] / _se[ganador]))
    local rnames `"`rnames' "`var'""'
}

matrix rownames balance = `rnames'
matlist balance, format(%9.4f) title("Individual Balance Tests (conditional on sorteo FE)")

* Joint F-test via suest (seemingly unrelated estimation)
* Note: suest doesn't work with reghdfe directly, so we use a different approach:
* Manually stack the regressions and test joint significance

* Alternative: run one regression with all balance vars and test joint
* We use the approach of stacking the t-stats and comparing to chi-squared

* Compute joint chi-squared = sum of squared t-stats (conservative: ignores correlation)
local chi2 = 0
local nbal : word count `balvars'
forvalues i = 1/`nbal' {
    local chi2 = `chi2' + balance[`i', 3]^2
}
local joint_p = chi2tail(`nbal', `chi2')

di as text _n "=== Joint Balance Test ==="
di as text "Chi-squared(`nbal') = " %9.3f `chi2'
di as text "p-value     = " %9.4f `joint_p'
di as text "(Conservative: assumes independence across balance variables.)"
di as text "(A proper SUR-based test would be more powerful.)"


/*==============================================================================
  STEP 3: SIMULATION-BASED BALANCE TEST (a la Cullen, Jacob & Levitt 2006)

  For each permutation:
    - Within each sorteo_fe, randomly reassign ganador (maintaining # winners)
    - Run balance regressions
    - Store t-statistics
  Then compare actual t-stats to the permutation distribution.

  Under the null of valid randomization, the actual t-stats should look
  like a random draw from the permutation distribution.
==============================================================================*/

di as text _n "=== STEP 3: Simulation-Based Balance Test ===" _n
di as text "Running `n_perms' permutations (this may take a while)..." _n

use "$temp/_diag_sample.dta", clear

* Balance variables
local balvars "edad mujer pre_employed pre_wage"
local nbal : word count `balvars'

* Compute actual t-stats
local j = 0
foreach var of local balvars {
    local ++j
    quietly reghdfe `var' ganador, absorb(sorteo_fe) cluster(id_anon)
    local actual_t_`j' = _b[ganador] / _se[ganador]
    di as text "Actual t-stat for `var': " %7.3f `actual_t_`j''
}

* Prepare permutation storage
tempfile base_data
save `base_data'

* Create a dataset to store permutation t-stats
clear
set obs `n_perms'
gen int perm_id = _n
forvalues j = 1/`nbal' {
    gen double t_`j' = .
}
tempfile perm_results
save `perm_results'

* Run permutations
forvalues p = 1/`n_perms' {
    if mod(`p', 100) == 0 {
        di as text "  Permutation `p' of `n_perms'..."
    }

    quietly {
        use `base_data', clear

        * Permute ganador within each sorteo_fe
        * (maintains exact number of winners per cell)
        gen double _u = runiform()
        bys sorteo_fe (_u): gen int _rank = _n
        bys sorteo_fe: egen _nwin = total(ganador)
        gen byte ganador_perm = (_rank <= _nwin)
        drop _u _rank _nwin

        * Run balance regressions with permuted treatment
        local j = 0
        foreach var of local balvars {
            local ++j
            cap reghdfe `var' ganador_perm, absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                local t_`j' = _b[ganador_perm] / _se[ganador_perm]
            }
            else {
                local t_`j' = .
            }
        }

        * Store results
        use `perm_results', clear
        forvalues j = 1/`nbal' {
            replace t_`j' = `t_`j'' if perm_id == `p'
        }
        save `perm_results', replace
    }
}

* Compute empirical p-values
use `perm_results', clear

di as text _n "=== Simulation-Based Balance Results ==="
di as text "(`n_perms' permutations, reassigning ganador within sorteo_fe cells)"
di as text _n

local j = 0
foreach var of local balvars {
    local ++j
    quietly count if abs(t_`j') >= abs(`actual_t_`j'') & t_`j' != .
    local n_exceed = r(N)
    quietly count if t_`j' != .
    local n_valid = r(N)
    local ri_p = `n_exceed' / `n_valid'
    di as text "`var':"
    di as text "  Actual t    = " %7.3f `actual_t_`j''
    di as text "  RI p-value  = " %7.4f `ri_p' " (`n_exceed'/`n_valid' permutations)"
}

* --- Figure: Permutation distributions overlaid with actual t-stats ---
local j = 0
foreach var of local balvars {
    local ++j
    local at = `actual_t_`j''

    * Histogram of permuted t-stats with actual value marked
    twoway (histogram t_`j', bin(50) color(navy%50) lcolor(navy%80)) ///
           (function normalden(x), range(-4 4) lcolor(red) lwidth(medthick) lpattern(dash)), ///
        xline(`at', lcolor(cranberry) lwidth(thick) lpattern(solid)) ///
        title("Permutation Distribution: `var'") ///
        xtitle("t-statistic") ytitle("Density") ///
        legend(order(1 "Permuted t-stats" 2 "N(0,1)" ) rows(1)) ///
        note("Red vertical line = actual t-stat (`at'). `n_perms' permutations.")
    graph export "$figures/diag_perm_`var'.pdf", replace
    graph export "$figures/diag_perm_`var'.png", replace width(2400)
}


/*==============================================================================
  STEP 4: RANDOMIZATION INFERENCE FOR MAIN OUTCOMES

  Same permutation logic, but now for the key treatment effect estimates.
  This gives RI p-values for the main ITT coefficients.
  Reference: Bugni, Canay & Shaikh (2018 JASA, 2019 QE); Fogarty (2018).
==============================================================================*/

di as text _n "=== STEP 4: Randomization Inference for Main Outcomes ===" _n

* Note: RI uses _diag_sample.dta which has sorteo_fe and ganador.
* Main outcomes (employed, is_monotributo, etc.) require cross_section_v2.dta
* which has the post-treatment outcomes merged. We build them here from scratch.
* For now, use _diag_sample.dta — pre_employed serves as the employment outcome
* for RI on balance variables. For post-treatment outcomes, use cross_section_v2.
use "$temp/cross_section_v2.dta", clear

* Key outcomes
local outcomes "employed is_monotributo any_work total_wage"
local nout : word count `outcomes'

* Compute actual ITT coefficients and t-stats
local j = 0
foreach var of local outcomes {
    local ++j
    quietly reghdfe `var' ganador, absorb(sorteo_fe) cluster(id_anon)
    local actual_b_`j' = _b[ganador]
    local actual_t_`j' = _b[ganador] / _se[ganador]
    local actual_p_`j' = 2 * ttail(e(df_r), abs(_b[ganador] / _se[ganador]))
    di as text "`var': coef = " %9.5f `actual_b_`j'' ///
        ", t = " %7.3f `actual_t_`j'' ", conv. p = " %7.4f `actual_p_`j''
}

tempfile outcome_data
save `outcome_data'

* Create permutation storage
clear
set obs `n_perms'
gen int perm_id = _n
forvalues j = 1/`nout' {
    gen double b_`j' = .
    gen double t_`j' = .
}
tempfile perm_outcomes
save `perm_outcomes'

di as text _n "Running `n_perms' permutations for outcome regressions..."

forvalues p = 1/`n_perms' {
    if mod(`p', 100) == 0 {
        di as text "  Permutation `p' of `n_perms'..."
    }

    quietly {
        use `outcome_data', clear

        * Permute ganador within sorteo_fe
        gen double _u = runiform()
        bys sorteo_fe (_u): gen int _rank = _n
        bys sorteo_fe: egen _nwin = total(ganador)
        gen byte ganador_perm = (_rank <= _nwin)
        drop _u _rank _nwin

        local j = 0
        foreach var of local outcomes {
            local ++j
            cap reghdfe `var' ganador_perm, absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                local b_`j' = _b[ganador_perm]
                local t_`j' = _b[ganador_perm] / _se[ganador_perm]
            }
            else {
                local b_`j' = .
                local t_`j' = .
            }
        }

        use `perm_outcomes', clear
        forvalues j = 1/`nout' {
            replace b_`j' = `b_`j'' if perm_id == `p'
            replace t_`j' = `t_`j'' if perm_id == `p'
        }
        save `perm_outcomes', replace
    }
}

* Report RI p-values
use `perm_outcomes', clear

di as text _n "=== Randomization Inference Results ==="
di as text "Outcome" _col(25) "Coef" _col(38) "Conv. p" _col(50) "RI p" _col(60) "N perms"
di as text "{hline 65}"

local j = 0
foreach var of local outcomes {
    local ++j
    * Two-sided RI p-value based on |t| >= |t_actual|
    quietly count if abs(t_`j') >= abs(`actual_t_`j'') & t_`j' != .
    local n_exceed = r(N)
    quietly count if t_`j' != .
    local n_valid = r(N)
    local ri_p = `n_exceed' / `n_valid'

    di as text "`var'" _col(25) %9.5f `actual_b_`j'' ///
        _col(38) %7.4f `actual_p_`j'' ///
        _col(50) %7.4f `ri_p' ///
        _col(60) "`n_valid'"
}


/*==============================================================================
  STEP 5: BALANCED-LOTTERY SUBSAMPLE (a la Hoxby & Murarka)

  Restrict to sorteo cells that pass a within-cell joint balance test.
  This is a conservative robustness check. Not the dominant practice
  today (dominant is conditioning on sorteo FE), but useful for appendix.
==============================================================================*/

di as text _n "=== STEP 5: Balanced-Lottery Subsample ===" _n

use "$temp/_diag_sample.dta", clear

* For each sorteo_fe, test whether ganador predicts balance variables
* Use a simple joint F-test (regress ganador on all balance vars within cell)

local balvars "edad mujer pre_employed pre_wage"

* We need enough obs per cell for meaningful tests
bys sorteo_fe: gen _n_cell = _N
tab _n_cell if _n_cell < 10
di as text "Sorteo cells with fewer than 10 obs will be excluded from this test."

* For cells with >= 20 obs, run within-cell balance regression
* and flag cells where joint F-test p < 0.05 as "imbalanced"

gen byte balanced_cell = 1  // default: balanced

levelsof sorteo_fe if _n_cell >= 20, local(cells)
local n_tested = 0
local n_failed = 0

foreach c of local cells {
    quietly {
        cap reg ganador `balvars' if sorteo_fe == `c'
        if _rc == 0 {
            local n_tested = `n_tested' + 1
            cap test `balvars'
            if _rc == 0 {
                if r(p) < 0.05 {
                    replace balanced_cell = 0 if sorteo_fe == `c'
                    local n_failed = `n_failed' + 1
                }
            }
        }
    }
}

di as text _n "=== Balanced-Lottery Test Results ==="
di as text "Sorteo cells tested (N >= 20):  `n_tested'"
di as text "Cells failing balance (p<0.05): `n_failed'"
di as text "Expected under null (5%):       " %5.1f `n_tested' * 0.05
di as text "Ratio (observed / expected):    " %5.2f `n_failed' / (`n_tested' * 0.05)

* Save balanced cell indicator
keep sorteo_fe balanced_cell
bys sorteo_fe: keep if _n == 1
tempfile balanced_flags
save `balanced_flags'

* Re-estimate ITT on balanced subsample
use "$temp/cross_section_v2.dta", clear
merge m:1 sorteo_fe using `balanced_flags', keep(master match) nogenerate

di as text _n "--- Full sample ---"
count
di as text "--- Balanced subsample (balanced_cell == 1) ---"
count if balanced_cell == 1

* Full sample for comparison
local outcomes "employed is_monotributo any_work total_wage"

di as text _n "=== ITT: Full Sample vs Balanced Subsample ==="
di as text "Outcome" _col(25) "Full b" _col(38) "Full p" ///
    _col(50) "Bal b" _col(63) "Bal p" _col(75) "Bal N"
di as text "{hline 80}"

foreach var of local outcomes {
    quietly reghdfe `var' ganador, absorb(sorteo_fe) cluster(id_anon)
    local full_b = _b[ganador]
    local full_p = 2 * ttail(e(df_r), abs(_b[ganador] / _se[ganador]))

    quietly reghdfe `var' ganador if balanced_cell == 1, absorb(sorteo_fe) cluster(id_anon)
    local bal_b = _b[ganador]
    local bal_p = 2 * ttail(e(df_r), abs(_b[ganador] / _se[ganador]))
    local bal_n = e(N)

    di as text "`var'" _col(25) %9.5f `full_b' _col(38) %7.4f `full_p' ///
        _col(50) %9.5f `bal_b' _col(63) %7.4f `bal_p' _col(75) %9.0fc `bal_n'
}


/*==============================================================================
  STEP 6: SORTEO-LEVEL WEIGHT DIAGNOSTICS

  The pooled ITT with sorteo FE is a weighted average of within-sorteo effects.
  Weights are proportional to N_j * p_j * (1-p_j).
  This step checks: which sorteos drive the estimate?

  We compute LOO influence for BOTH:
    (a) ITT (reduced form): tau_j = E[Y|ganador=1,s=j] - E[Y|ganador=0,s=j]
    (b) IV  (Wald per cell): beta_j = tau_j / pi_j
        where pi_j = E[receptor|ganador=1,s=j] - E[receptor|ganador=0,s=j]
        The pooled IV ≈ sum(w_j * tau_j) / sum(w_j * pi_j)
==============================================================================*/

di as text _n "=== STEP 6: Sorteo-Level Weight Diagnostics ===" _n

use "$temp/cross_section_v2.dta", clear

* Compute within-sorteo statistics
bys sorteo_fe: egen _n_cell = count(id_anon)
bys sorteo_fe: egen _p_win = mean(ganador)
gen _weight = _n_cell * _p_win * (1 - _p_win)

* --- 6a. Within-sorteo ITT (reduced form on employed) ---
bys sorteo_fe ganador: egen _mean_emp_trt = mean(employed)
bys sorteo_fe: egen _mean_emp_1 = max(cond(ganador == 1, _mean_emp_trt, .))
bys sorteo_fe: egen _mean_emp_0 = max(cond(ganador == 0, _mean_emp_trt, .))
gen _tau_j = _mean_emp_1 - _mean_emp_0

* --- 6b. Within-sorteo first stage (receptor on ganador) ---
bys sorteo_fe ganador: egen _mean_rec_trt = mean(receptor)
bys sorteo_fe: egen _mean_rec_1 = max(cond(ganador == 1, _mean_rec_trt, .))
bys sorteo_fe: egen _mean_rec_0 = max(cond(ganador == 0, _mean_rec_trt, .))
gen _pi_j = _mean_rec_1 - _mean_rec_0

* --- 6c. Within-sorteo Wald IV = tau_j / pi_j ---
gen _wald_j = _tau_j / _pi_j if _pi_j != 0 & _pi_j != .

* Collapse to sorteo level
preserve
    bys sorteo_fe: keep if _n == 1
    keep sorteo_fe _n_cell _p_win _weight _tau_j _pi_j _wald_j

    * ==============================
    * ITT: LOO influence
    * ==============================
    gen _weighted_tau = _weight * _tau_j
    quietly sum _weighted_tau
    local sum_wtau = r(sum)
    quietly sum _weight
    local sum_w = r(sum)
    local pooled_tau = `sum_wtau' / `sum_w'

    di as text "Pooled ITT (weighted avg of within-sorteo effects): " %9.5f `pooled_tau'

    gen _loo_tau = (`sum_wtau' - _weighted_tau) / (`sum_w' - _weight)
    gen _influence_itt = `pooled_tau' - _loo_tau

    di as text _n "=== Leave-one-out influence: ITT ==="
    sum _influence_itt, detail

    gsort -_influence_itt
    di as text _n "Top 10 most influential sorteos — ITT (pulling UP):"
    list sorteo_fe _n_cell _p_win _tau_j _pi_j _weight _influence_itt in 1/10, noobs

    gsort _influence_itt
    di as text _n "Top 10 most influential sorteos — ITT (pulling DOWN):"
    list sorteo_fe _n_cell _p_win _tau_j _pi_j _weight _influence_itt in 1/10, noobs

    * ==============================
    * IV: LOO influence
    * ==============================
    * Pooled IV ≈ sum(w_j * tau_j) / sum(w_j * pi_j)
    gen _weighted_pi = _weight * _pi_j
    quietly sum _weighted_pi
    local sum_wpi = r(sum)
    local pooled_iv = `sum_wtau' / `sum_wpi'

    di as text _n "Pooled IV (Wald ratio of weighted sums): " %9.5f `pooled_iv'
    di as text "  (= pooled ITT / pooled first stage = " ///
        %9.5f `pooled_tau' " / " %9.5f (`sum_wpi' / `sum_w') ")"

    * LOO-IV: drop sorteo j, recompute ratio
    gen _loo_iv = (`sum_wtau' - _weighted_tau) / (`sum_wpi' - _weighted_pi)
    gen _influence_iv = `pooled_iv' - _loo_iv

    di as text _n "=== Leave-one-out influence: IV ==="
    sum _influence_iv, detail

    gsort -_influence_iv
    di as text _n "Top 10 most influential sorteos — IV (pulling UP):"
    list sorteo_fe _n_cell _p_win _tau_j _pi_j _wald_j _weight _influence_iv in 1/10, noobs

    gsort _influence_iv
    di as text _n "Top 10 most influential sorteos — IV (pulling DOWN):"
    list sorteo_fe _n_cell _p_win _tau_j _pi_j _wald_j _weight _influence_iv in 1/10, noobs

    * ==============================
    * Figures
    * ==============================

    * --- Panel A: ITT influence ---
    twoway (scatter _influence_itt _weight, mcolor(navy%50) msize(small)) ///
           (lowess _influence_itt _weight, lcolor(cranberry) lwidth(medthick)), ///
        yline(0, lcolor(gray) lpattern(dash)) ///
        title("A. ITT (Reduced Form)") ///
        xtitle("Sorteo weight = N{subscript:j} × p{subscript:j} × (1 − p{subscript:j})") ///
        ytitle("Influence (pooled − LOO)") ///
        legend(off) ///
        graphregion(color(white)) scheme(s2color) ///
        name(_loo_itt, replace) nodraw

    * --- Panel B: IV influence ---
    twoway (scatter _influence_iv _weight, mcolor(navy%50) msize(small)) ///
           (lowess _influence_iv _weight, lcolor(cranberry) lwidth(medthick)), ///
        yline(0, lcolor(gray) lpattern(dash)) ///
        title("B. IV (Wald Estimator)") ///
        xtitle("Sorteo weight = N{subscript:j} × p{subscript:j} × (1 − p{subscript:j})") ///
        ytitle("Influence (pooled − LOO)") ///
        legend(off) ///
        graphregion(color(white)) scheme(s2color) ///
        name(_loo_iv, replace) nodraw

    * --- Combined figure ---
    graph combine _loo_itt _loo_iv, ///
        rows(1) cols(2) ///
        graphregion(color(white)) ///
        title("Leave-One-Out Influence by Sorteo Weight") ///
        note("Each dot = one sorteo cell. Positive = pulling estimate up." ///
             "IV = reduced-form / first-stage Wald ratio per cell.")
    graph export "$figures/diag_influence.pdf", replace
    graph export "$figures/diag_influence.png", replace width(2400)

    * --- Also save individual panels ---
    graph display _loo_itt
    graph export "$figures/diag_influence_itt.pdf", replace
    graph export "$figures/diag_influence_itt.png", replace width(1600)

    graph display _loo_iv
    graph export "$figures/diag_influence_iv.pdf", replace
    graph export "$figures/diag_influence_iv.png", replace width(1600)

    * --- Summary comparison ---
    di as text _n "=== LOO Summary ==="
    di as text "  Pooled ITT:  " %9.5f `pooled_tau'
    di as text "  Pooled IV:   " %9.5f `pooled_iv'
    di as text "  Max |influence| ITT: " %9.5f max(abs(_influence_itt))
    quietly sum _influence_itt
    di as text "  Max |influence| ITT: " %9.6f max(abs(r(min)), abs(r(max)))
    quietly sum _influence_iv
    di as text "  Max |influence| IV:  " %9.6f max(abs(r(min)), abs(r(max)))

    * Correlation between ITT and IV influence
    corr _influence_itt _influence_iv
    di as text "  Correlation ITT vs IV influence: " %6.3f r(rho)

restore


/*==============================================================================
  STEP 7: WEIGHTING ROBUSTNESS — ITT & IV, WITH AND WITHOUT CONTROLS

  We run pooled reghdfe/ivreghdfe with sorteo FE under three observation-level
  weight schemes that replicate Precision / Equal / Population weighting:

    (a) Unweighted (= precision, since reghdfe with FE gives N_j*p_j*(1-p_j))
    (b) Equal per sorteo: weight = 1 / (N_j * p_j * (1 - p_j))
        so that w_j × [N_j p_j(1-p_j)] = 1 for every cell → equal weights
    (c) Population: weight = 1 / (p_j * (1 - p_j))
        so that w_j × [N_j p_j(1-p_j)] = N_j for every cell → pop weights

  Each specification is run:
    - Without controls  (Panel A)
    - With controls     (Panel B): pre_wage pre_employed edad mujer

  Estimands:
    - ITT: reghdfe Y ganador [aw=w], absorb(sorteo_fe) cluster(id_anon)
    - IV:  ivreghdfe Y (receptor = ganador) [aw=w], absorb(sorteo_fe) cluster(id_anon)

  Outcomes: employed, is_monotributo, any_work, total_wage, log_wage|employed

  References: Cullen, Jacob & Levitt (2006); Bugni, Canay & Shaikh (2019).
==============================================================================*/

di as text _n "=== STEP 7: Weighting Robustness — ITT & IV ===" _n

use "$temp/cross_section_v2.dta", clear

* --- 7a. Construct observation-level weights ---

bys sorteo_fe: egen _n_cell = count(id_anon)
bys sorteo_fe: egen _p_win  = mean(ganador)

* Precision weight = implicit in unweighted reghdfe → w_obs = 1
gen double _w_precision = 1

* Equal weight per sorteo: undo precision, give each cell weight 1
* obs weight = 1 / [N_j * p_j * (1-p_j)]
gen double _w_equal = 1 / (_n_cell * _p_win * (1 - _p_win))

* Population weight: undo the p(1-p) part, keep N_j
* obs weight = 1 / [p_j * (1-p_j)]
gen double _w_pop = 1 / (_p_win * (1 - _p_win))

local n_cells_all = _N
quietly tab sorteo_fe
local n_sorteos = r(r)
di as text "Observations: `n_cells_all',  Sorteo cells: `n_sorteos'"

* --- 7b. Define outcomes and controls ---

local outcomes    "employed is_monotributo any_work total_wage log_wage"
local controls    "pre_wage pre_employed edad mujer"

* Clean labels for table output
local lbl_employed       "Formal Employment"
local lbl_is_monotributo "Monotributo"
local lbl_any_work       "Any Work"
local lbl_total_wage     "Total Wage"
local lbl_log_wage       "Log Wage|Emp"

* --- 7c. Run regressions and store results ---
* We store into matrices: rows = outcomes, cols = precision/equal/pop × coef/se

* Loop: ctl = {noctl, ctl} × est = {itt, iv} × wt = {precision, equal, pop}

foreach ctl in noctl ctl {

    if "`ctl'" == "noctl" local ctrls ""
    if "`ctl'" == "noctl" local ctl_label "No Controls"
    if "`ctl'" == "ctl"   local ctrls "`controls'"
    if "`ctl'" == "ctl"   local ctl_label "With Controls"

    foreach est in itt iv {

        if "`est'" == "itt" local est_label "ITT"
        if "`est'" == "iv"  local est_label "IV"

        di as text _n "{hline 80}"
        di as text "`est_label' — `ctl_label'"
        di as text "{hline 80}"
        di as text %-20s "Outcome" _col(22) %12s "Precision" _col(38) %12s "Equal" _col(54) %12s "Population"
        di as text "{hline 80}"

        * Prepare file for this panel
        capture file close ftab
        file open ftab using "$tables/weighted_`est'_`ctl'.tex", write replace

        file write ftab "\begin{table}[htbp]" _n
        file write ftab "\centering" _n
        file write ftab "\begin{threeparttable}" _n
        file write ftab "\caption{`est_label' Estimates Under Alternative Weighting Schemes (`ctl_label')}" _n
        file write ftab "\label{tab:weighted_`est'_`ctl'}" _n
        file write ftab "\begin{tabular}{lccc}" _n
        file write ftab "\hline\hline" _n
        file write ftab " & Precision & Equal & Population \\" _n
        file write ftab " & \$N_j p_j(1-p_j)\$ & \$1/J\$ & \$N_j\$ \\" _n
        file write ftab "\hline" _n

        foreach var of local outcomes {

            * log_wage: restrict to employed == 1 & total_wage > 0
            local ifcond ""
            if "`var'" == "log_wage" local ifcond "if employed == 1 & total_wage > 0"

            local vname "`lbl_`var''"

            * Storage for this row
            local b_prec = .
            local se_prec = .
            local b_eq = .
            local se_eq = .
            local b_pop = .
            local se_pop = .

            local wt_idx = 0
            foreach wt in _w_precision _w_equal _w_pop {
                local ++wt_idx

                if "`est'" == "itt" {
                    capture quietly reghdfe `var' ganador `ctrls' ///
                        `ifcond' [aw = `wt'], absorb(sorteo_fe) cluster(id_anon)
                    if _rc == 0 {
                        local _b = _b[ganador]
                        local _s = _se[ganador]
                    }
                    else {
                        local _b = .
                        local _s = .
                    }
                }
                else {
                    capture quietly ivreghdfe `var' `ctrls' ///
                        (receptor = ganador) `ifcond' [aw = `wt'], ///
                        absorb(sorteo_fe) cluster(id_anon)
                    if _rc == 0 {
                        local _b = _b[receptor]
                        local _s = _se[receptor]
                    }
                    else {
                        local _b = .
                        local _s = .
                    }
                }

                if `wt_idx' == 1 {
                    local b_prec  = `_b'
                    local se_prec = `_s'
                }
                if `wt_idx' == 2 {
                    local b_eq  = `_b'
                    local se_eq = `_s'
                }
                if `wt_idx' == 3 {
                    local b_pop  = `_b'
                    local se_pop = `_s'
                }
            }

            * Display
            di as text %-20s "`vname'" ///
                _col(22) %10.5f `b_prec' _col(38) %10.5f `b_eq' _col(54) %10.5f `b_pop'
            di as text _col(22) "(" %8.5f `se_prec' ")" ///
                _col(38) "(" %8.5f `se_eq' ")" ///
                _col(54) "(" %8.5f `se_pop' ")"

            * Write to tex
            file write ftab "`vname' & " %9.5f (`b_prec') " & " %9.5f (`b_eq') " & " %9.5f (`b_pop') " \\" _n
            file write ftab "  & (" %7.5f (`se_prec') ") & (" %7.5f (`se_eq') ") & (" %7.5f (`se_pop') ") \\" _n
        }

        file write ftab "\hline" _n
        file write ftab "Sorteo cells & `n_sorteos' & `n_sorteos' & `n_sorteos' \\" _n
        file write ftab "Controls & " ///
            cond("`ctl'" == "ctl", "Yes", "No") " & " ///
            cond("`ctl'" == "ctl", "Yes", "No") " & " ///
            cond("`ctl'" == "ctl", "Yes", "No") " \\" _n
        file write ftab "\hline\hline" _n
        file write ftab "\end{tabular}" _n
        file write ftab "\begin{tablenotes}\small" _n
        if "`est'" == "itt" {
            file write ftab "\item \textit{Notes:} ITT regressions of each outcome on \texttt{ganador}" _n
        }
        else {
            file write ftab "\item \textit{Notes:} IV/2SLS regressions instrumenting \texttt{receptor} with \texttt{ganador}" _n
        }
        file write ftab " with sorteo FE, under three observation-level weighting schemes." _n
        file write ftab " Precision weights arise from the unweighted regression" _n
        file write ftab " (\$w_j = N_j p_j(1-p_j)\$). Equal weights re-weight so each" _n
        file write ftab " sorteo cell contributes equally. Population weights re-weight" _n
        file write ftab " so each applicant contributes equally (\$w_j = N_j\$)." _n
        if "`ctl'" == "ctl" {
            file write ftab " Controls: pre-treatment wage, employment, age, gender." _n
        }
        file write ftab " Log Wage estimated on employed subsample (\texttt{employed==1 \& total\_wage>0})." _n
        file write ftab " SE clustered at person level." _n
        file write ftab "\end{tablenotes}" _n
        file write ftab "\end{threeparttable}" _n
        file write ftab "\end{table}" _n

        file close ftab
        di as text _n "  Saved: weighted_`est'_`ctl'.tex"
    }
}


* --- 7d. Figures: within-sorteo ITT and distribution (kept from original) ---

* Recompute raw within-sorteo tau for employed (for figures)
bys sorteo_fe ganador: egen double _m1_emp = mean(employed) if ganador == 1
bys sorteo_fe ganador: egen double _m0_emp = mean(employed) if ganador == 0
bys sorteo_fe: egen double _mean1_emp = max(_m1_emp)
bys sorteo_fe: egen double _mean0_emp = max(_m0_emp)
gen double _tau_employed = _mean1_emp - _mean0_emp
drop _m1_emp _m0_emp _mean1_emp _mean0_emp

gen double w_precision_cell = _n_cell * _p_win * (1 - _p_win)

preserve
    bys sorteo_fe: keep if _n == 1
    keep if _n_cell >= 5

    * Figure: tau_j vs weight
    twoway (scatter _tau_employed w_precision_cell [aw = w_precision_cell], ///
                mcolor(navy%40) msize(small)) ///
           (lowess _tau_employed w_precision_cell, lcolor(cranberry) lwidth(medthick)), ///
        yline(0, lcolor(gray) lpattern(dash)) ///
        title("Within-Sorteo ITT on Employment by Weight") ///
        xtitle("Sorteo weight = N{subscript:j} × p{subscript:j} × (1 − p{subscript:j})") ///
        ytitle("Within-sorteo ITT ({&tau}{subscript:j})") ///
        legend(off) ///
        note("Marker area proportional to weight. Lowess in red.")
    graph export "$figures/diag_tau_by_weight.pdf", replace
    graph export "$figures/diag_tau_by_weight.png", replace width(2400)

    * Figure: distribution of tau_j
    quietly sum w_precision_cell
    local _tau_prec = .
    gen double _wt = w_precision_cell * _tau_employed
    quietly sum _wt
    local _sum_wt = r(sum)
    quietly sum w_precision_cell
    local _tau_prec = `_sum_wt' / r(sum)
    drop _wt

    histogram _tau_employed [fw = round(w_precision_cell)], bin(40) ///
        color(navy%60) lcolor(navy) ///
        xline(`_tau_prec', lcolor(cranberry) lwidth(thick)) ///
        title("Distribution of Within-Sorteo ITT on Employment") ///
        xtitle("{&tau}{subscript:j} (within-sorteo treatment effect)") ///
        ytitle("Frequency (precision-weighted)") ///
        note("Red line = precision-weighted average." ///
             "Weighted by N_j × p_j × (1−p_j).")
    graph export "$figures/diag_tau_distribution.pdf", replace
    graph export "$figures/diag_tau_distribution.png", replace width(2400)

restore


/*==============================================================================
  SUMMARY
==============================================================================*/

di as text _n "{hline 70}"
di as text "PROCREAR Lottery Diagnostics — Complete"
di as text "{hline 70}"
di as text ""
di as text "Outputs:"
di as text "  Figures/"
di as text "    diag_sorteo_sizes.pdf      — Distribution of sorteo cell sizes"
di as text "    diag_winrates.pdf           — Distribution of win rates"
di as text "    diag_weights.pdf            — Distribution of implied weights"
di as text "    diag_cum_weight.pdf         — Cumulative weight share"
di as text "    diag_perm_*.pdf             — Permutation distributions (balance)"
di as text "    diag_influence.pdf          — Leave-one-out influence (ITT + IV)"
di as text "    diag_tau_by_weight.pdf      — Within-sorteo effects by weight"
di as text "    diag_tau_distribution.pdf   — Distribution of within-sorteo effects"
di as text "  Tables/"
di as text "    weighted_itt_noctl.tex      — ITT, no controls, 3 weighting schemes"
di as text "    weighted_itt_ctl.tex        — ITT, with controls, 3 weighting schemes"
di as text "    weighted_iv_noctl.tex       — IV, no controls, 3 weighting schemes"
di as text "    weighted_iv_ctl.tex         — IV, with controls, 3 weighting schemes"
di as text ""
di as text "Key references for methodology section:"
di as text "  Cullen, Jacob & Levitt (2006, Econometrica)"
di as text "  Deming (2014, AER)"
di as text "  Abdulkadiroglu, Angrist, Narita & Pathak (2017, Econometrica)"
di as text "  Bugni, Canay & Shaikh (2018, JASA; 2019, QE)"
di as text "  Fogarty (2018, JRSSB / Biometrika)"
di as text "  Hoxby & Murarka (2009, AER)"
di as text "{hline 70}"
