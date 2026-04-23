/*==============================================================================
  PROCREAR — Paper Tables: Sample Balance

  THIS SCRIPT GENERATES THE OFFICIAL PAPER OUTPUTS FOR THE SAMPLE BALANCE
  SECTION (Section 3 of paper.tex). It produces three artifacts:

    1. tables/balance_pooled.tex
       Pooled balance regression: 4 columns (Age, Female, Pre-Employed,
       Pre-Wage), OLS with sorteo FE absorbed and SE clustered at the
       person level. Reports coefficient, SE, control mean, control SD,
       standardized difference (b/csd), and N. Wage values are formatted
       as comma-separated integers in ARS.

    2. Figures/balance_tstats_by_sorteo_fe.pdf
       Within-sorteo balance check: 4-panel histogram of t-statistics
       from cell-by-cell regressions of each covariate on the winner
       indicator, with N(0,1) overlay. Sorteos are filtered to N>=30,
       winners>=5, losers>=5 to avoid degenerate cells.

    3. tables/balance_permutation.tex
       Cullen-Jacob-Levitt (2006) within-sorteo permutation test:
       1,000 within-sorteo permutations of ganador. For each replication,
       recomputes the FE-residualized coefficient on each covariate.
       Reports the observed coefficient, the 2.5/97.5 percentiles of the
       permutation distribution, and the two-sided permutation p-value.

  REQUIRES: $temp/cross_section_v2.dta from paper_labor_outcomes.do.
  Run paper_labor_outcomes.do (Steps 1-4) first if not available.

  ===========================================================================
  OUTPUT → PAPER MAPPING
  ===========================================================================

  Output file                                   Paper location
  --------------------------------------------- ---------------------------
  tables/balance_pooled.tex                     Section 3 — Sample Balance
                                                  (tab:balance_pooled)
  Figures/balance_tstats_by_sorteo_fe.pdf       Section 3 — Sample Balance
                                                  (fig:balance_tstats)
  tables/balance_permutation.tex                Section 3 — Sample Balance
                                                  (tab:balance_permutation)

  ===========================================================================
  OUTLINE
  ===========================================================================

  STEP 0: Rebuild edad as edad_sorteo (exact age at sorteo date)
  STEP 1: Pooled balance table — reghdfe of each covariate on ganador
  STEP 2: By-sorteo balance histogram — t-stats from per-sorteo regressions
  STEP 3: Within-sorteo permutation test — Cullen-Jacob-Levitt (2006)

==============================================================================*/

clear all
set more off
set matsize 10000

* --- PROJECT PATHS ------------------------------------------------------------
global root "/Users/francomartinvazquez/Dropbox (Personal)/Procrear Santanna"
global data "$root/DATA"
global tables "$root/Procrear/tables"
global figures "$root/Procrear/figures"
global temp "$root/TEMP"

cap mkdir "$tables"
cap mkdir "$figures"
cap mkdir "$temp"

* --- REQUIRED PACKAGES --------------------------------------------------------
* ssc install reghdfe, replace
* ssc install ftools, replace
* ssc install estout, replace

* --- CONFIGURATION ------------------------------------------------------------
* Number of within-sorteo permutations.
* Paper text claims 1,000. Use a smaller value (e.g., 50) for quick iteration.
local B_PERM 1000

* RNG seed for reproducibility
set seed 20260406


/*==============================================================================
  STEP 0: REBUILD EDAD — edad_sorteo exacta

  Overwrites the `edad` variable from cross_section_v2.dta with an exact
  age-at-sorteo calculation (month and day precision), with a CUIL-prefix
  fallback for rows missing fnacimiento.

  Logic:
    1) Primary: edad = year(fecha_sorteo) - year(fnacimiento),
       minus 1 if the person has not yet had their birthday that year.
    2) Fallback: impute fnacimiento with the median of fnacimiento within the
       CUIL prefix group (chars 3-5), but only for CUILs where:
         - char 1 != "3"   (excludes personas juridicas: 30/33/34)
         - char 3 in {0,1,2,3,4}  (plausible DNI first digit)
       Then recompute edad from the imputed fnacimiento.

  The resulting `edad` replaces the one in cross_section_v2.dta and is
  picked up automatically by STEPS 1-3 below.
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 0: Rebuild edad as edad_sorteo (exact)"
di as text       "==================================================================="

* --- 0a. Mapa prefijo CUIL (dígitos 3-5) → mediana fnacimiento ---------------
preserve
    use "$data/Data_sorteos.dta", clear
    keep cuil fnacimiento
    keep if !missing(fnacimiento) & cuil != ""
    keep if substr(cuil, 1, 1) != "3"
    gen str1 _d3 = substr(cuil, 3, 1)
    keep if inlist(_d3, "0", "1", "2", "3", "4")
    gen str3 _pfx_str = substr(cuil, 3, 3)
    destring _pfx_str, gen(dni_prefix) force
    keep if !missing(dni_prefix)
    collapse (median) med_fnac = fnacimiento, by(dni_prefix)
    format med_fnac %td
    save "$temp/_prefix_map.dta", replace
restore

* --- 0b. Mapa id_anon → (cuil, fnacimiento) (1:1 en Data_sorteos) -----------
preserve
    use "$data/Data_sorteos.dta", clear
    keep id_anon cuil fnacimiento
    duplicates drop id_anon, force
    save "$temp/_person_birth.dta", replace
restore

* --- 0c. Cargar cross_section, dropear edad vieja, traer cuil+fnacimiento ---
use "$temp/cross_section_v2.dta", clear
drop edad
merge m:1 id_anon using "$temp/_person_birth.dta", keep(master match) nogenerate

* --- 0d. Adjuntar mediana de prefijo y flags de filtro -----------------------
gen str3 _dni_prefix_str = substr(cuil, 3, 3)
destring _dni_prefix_str, gen(dni_prefix) force
gen str1 _d1 = substr(cuil, 1, 1)
gen str1 _d3 = substr(cuil, 3, 1)
merge m:1 dni_prefix using "$temp/_prefix_map.dta", keep(master match) nogenerate

* --- 0e. Primario: edad desde fnacimiento real -------------------------------
gen int edad = year(fecha_sorteo) - year(fnacimiento)                  ///
    - (month(fecha_sorteo) < month(fnacimiento) |                      ///
       (month(fecha_sorteo) == month(fnacimiento) &                    ///
        day(fecha_sorteo) < day(fnacimiento)))                         ///
    if !missing(fnacimiento)

* --- 0f. Fallback: imputar fnacimiento con filtros y recomputar --------------
replace fnacimiento = med_fnac if                                      ///
    missing(edad) & !missing(med_fnac) &                               ///
    _d1 != "3" & inlist(_d3, "0", "1", "2", "3", "4")

replace edad = year(fecha_sorteo) - year(fnacimiento)                  ///
    - (month(fecha_sorteo) < month(fnacimiento) |                      ///
       (month(fecha_sorteo) == month(fnacimiento) &                    ///
        day(fecha_sorteo) < day(fnacimiento)))                         ///
    if missing(edad) & !missing(fnacimiento)

label variable edad "Edad (anos) al dia del sorteo"

* --- 0g. Cleanup y guardado ---------------------------------------------------
drop _dni_prefix_str dni_prefix _d1 _d3 med_fnac cuil fnacimiento
erase "$temp/_prefix_map.dta"
erase "$temp/_person_birth.dta"

di as text _n "edad (redefinida) non-missing:"
count if !missing(edad)
di as text "  " r(N) " of " _N " (" %5.2f 100*r(N)/_N "%)"

save "$temp/cross_section_v2.dta", replace
di as text _n "  done: cross_section_v2.dta overwritten with exact edad"


/*==============================================================================
  STEP 1: POOLED BALANCE TABLE

  For each of {edad, mujer, pre_employed, pre_wage}:
      reghdfe Y ganador, absorb(sorteo_fe) cluster(id_anon)
  Compute: control mean, control SD, standardized difference (b/csd).

  Output is written manually with `file write` because the table mixes
  4-decimal coefficients (age, female, employment) with comma-separated
  integers (wage in ARS), which a single esttab call cannot produce.
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 1: Pooled balance table"
di as text       "==================================================================="

use "$temp/cross_section_v2.dta", clear

* Sanity check: required variables exist
foreach v in edad mujer pre_employed pre_wage ganador sorteo_fe id_anon {
    capture confirm variable `v'
    if _rc {
        di as error "Variable `v' not found in cross_section_v2.dta"
        di as error "Re-run paper_labor_outcomes.do (Steps 1-4) to rebuild it."
        exit 111
    }
}

di as text _n "Sample size: " %12.0fc _N
quietly egen _sg = group(sorteo_fe)
quietly sum _sg
di as text "Unique sorteos: " %9.0fc r(max)
drop _sg

* --- 1a. Run regressions and capture stats -----------------------------------
foreach v in edad mujer pre_employed pre_wage {
    di as text _n "  reghdfe `v' ganador, absorb(sorteo_fe) cluster(id_anon)"
    qui reghdfe `v' ganador, absorb(sorteo_fe) cluster(id_anon)

    scalar b_`v'      = _b[ganador]
    scalar se_`v'     = _se[ganador]
    scalar n_`v'      = e(N)
    scalar p_`v'      = 2 * ttail(e(df_r), abs(b_`v' / se_`v'))

    qui sum `v' if ganador == 0
    scalar cmean_`v'  = r(mean)
    scalar csd_`v'    = r(sd)
    scalar stddif_`v' = b_`v' / csd_`v'

    di as text "    b = " %12.4f b_`v' "   se = " %12.4f se_`v' "   N = " %12.0fc n_`v'
    di as text "    cmean = " %12.4f cmean_`v' "   csd = " %12.4f csd_`v' "   stddif = " %9.4f stddif_`v'
}

* --- 1b. Build display strings -----------------------------------------------
* Stars (based on p-values)
foreach v in edad mujer pre_employed pre_wage {
    local star_`v' ""
    if p_`v' < 0.10  local star_`v' "\sym{*}"
    if p_`v' < 0.05  local star_`v' "\sym{**}"
    if p_`v' < 0.01  local star_`v' "\sym{***}"
}

* Coefficient + SE strings (4-decimal columns: edad, mujer, pre_employed)
foreach v in edad mujer pre_employed {
    local b_`v'_s  : di %9.4f b_`v'
    local b_`v'_s  = trim("`b_`v'_s'")
    local se_`v'_s : di %9.4f se_`v'
    local se_`v'_s = trim("`se_`v'_s'")
}

* Coefficient string for wage (comma-separated integer, store sign separately)
local b_pre_wage_raw : di %12.0fc b_pre_wage
local b_pre_wage_raw = trim("`b_pre_wage_raw'")
local b_pre_wage_neg = (b_pre_wage < 0)
if `b_pre_wage_neg' {
    local b_pre_wage_mag = subinstr("`b_pre_wage_raw'", "-", "", 1)
}
else {
    local b_pre_wage_mag "`b_pre_wage_raw'"
}
local b_pre_wage_mag = subinstr("`b_pre_wage_mag'", ",", "{,}", .)

local se_pre_wage_raw : di %12.0fc se_pre_wage
local se_pre_wage_raw = trim("`se_pre_wage_raw'")
local se_pre_wage_s   = subinstr("`se_pre_wage_raw'", ",", "{,}", .)

* Control mean / control SD strings
foreach v in edad mujer pre_employed {
    local cmean_`v'_s : di %9.3f cmean_`v'
    local cmean_`v'_s = trim("`cmean_`v'_s'")
    local csd_`v'_s   : di %9.3f csd_`v'
    local csd_`v'_s   = trim("`csd_`v'_s'")
}
local cmean_pre_wage_raw : di %12.0fc cmean_pre_wage
local cmean_pre_wage_raw = trim("`cmean_pre_wage_raw'")
local cmean_pre_wage_s   = subinstr("`cmean_pre_wage_raw'", ",", "{,}", .)

local csd_pre_wage_raw : di %12.0fc csd_pre_wage
local csd_pre_wage_raw = trim("`csd_pre_wage_raw'")
local csd_pre_wage_s   = subinstr("`csd_pre_wage_raw'", ",", "{,}", .)

* Std diff strings (3 decimals, magnitude + sign flag for math-mode minus)
foreach v in edad mujer pre_employed pre_wage {
    local std_`v'_raw : di %9.3f stddif_`v'
    local std_`v'_raw = trim("`std_`v'_raw'")
    local std_`v'_neg = (stddif_`v' < 0)
    if `std_`v'_neg' {
        local std_`v'_mag = subinstr("`std_`v'_raw'", "-", "", 1)
    }
    else {
        local std_`v'_mag "`std_`v'_raw'"
    }
}

* Observation count strings
foreach v in edad mujer pre_employed pre_wage {
    local n_`v'_raw : di %12.0fc n_`v'
    local n_`v'_raw = trim("`n_`v'_raw'")
    local n_`v'_s   = subinstr("`n_`v'_raw'", ",", "{,}", .)
}

* --- 1c. Write balance_pooled.tex --------------------------------------------
file open f using "$tables/balance_pooled.tex", write replace text

file write f "\begin{table}[H]\centering" _n
file write f "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
file write f "\caption{Covariate Balance --- Lottery Winners vs.\ Losers (conditional on sorteo FE)}" _n
file write f "\label{tab:balance_pooled}" _n
file write f "\begin{tabular}{l*{4}{c}}" _n
file write f "\hline\hline" _n
file write f "                    & \multicolumn{1}{c}{(1)} & \multicolumn{1}{c}{(2)} & \multicolumn{1}{c}{(3)} & \multicolumn{1}{c}{(4)} \\" _n
file write f "                    & \multicolumn{1}{c}{Age} & \multicolumn{1}{c}{Female} & \multicolumn{1}{c}{Pre-Employed} & \multicolumn{1}{c}{Pre-Wage (ARS)} \\" _n
file write f "\hline" _n

* Coefficient row (math-mode minus for negative wage coefficient)
if `b_pre_wage_neg' {
    file write f "Lottery Winner      &  `b_edad_s'`star_edad'  &  `b_mujer_s'`star_mujer'  &  `b_pre_employed_s'`star_pre_employed'  &  \$-\$`b_pre_wage_mag'`star_pre_wage'  \\" _n
}
else {
    file write f "Lottery Winner      &  `b_edad_s'`star_edad'  &  `b_mujer_s'`star_mujer'  &  `b_pre_employed_s'`star_pre_employed'  &  `b_pre_wage_mag'`star_pre_wage'  \\" _n
}

* SE row (parentheses)
file write f "                    &  (`se_edad_s')         &  (`se_mujer_s')          &  (`se_pre_employed_s')          &  (`se_pre_wage_s')            \\" _n

file write f "\hline" _n
file write f "Control mean        &  `cmean_edad_s'         &  `cmean_mujer_s'          &  `cmean_pre_employed_s'          &  `cmean_pre_wage_s'          \\" _n
file write f "Control SD          &  `csd_edad_s'         &  `csd_mujer_s'          &  `csd_pre_employed_s'          &  `csd_pre_wage_s'          \\" _n

* Std diff row — handle each cell's sign individually
local std_row "Std.\ difference   "
foreach v in edad mujer pre_employed pre_wage {
    if `std_`v'_neg' {
        local std_row "`std_row'  &  \$-\$`std_`v'_mag'"
    }
    else {
        local std_row "`std_row'  &  `std_`v'_mag'"
    }
}
local std_row "`std_row'  \\"
file write f "`std_row'" _n

file write f "Observations        &  `n_edad_s'      &  `n_mujer_s'        &  `n_pre_employed_s'      &  `n_pre_wage_s'         \\" _n

file write f "\hline\hline" _n
file write f "\multicolumn{5}{p{0.92\textwidth}}{\footnotesize OLS with sorteo FE absorbed. SE clustered at person level. Pre-treatment covariates measured at sorteo month from SIPA. Wage in current ARS. Standardized difference \$=\$ coefficient \$/\$ control-group SD.} \\" _n
file write f "\multicolumn{5}{l}{\footnotesize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)} \\" _n
file write f "\end{tabular}" _n
file write f "\end{table}" _n

file close f

di as text _n "  done: tables/balance_pooled.tex"


/*==============================================================================
  STEP 2: BY-SORTEO BALANCE FIGURE

  For each of {edad, mujer, pre_employed, pre_wage}, run a separate
  per-sorteo OLS regression of Y on ganador and collect the t-statistic.
  Then plot a 4-panel KDE with N(0,1) overlay.

  NO FILTERING: every sorteo enters the figure. The only observations
  dropped are those mathematically impossible to plot — cells where the
  per-sorteo regression returns a missing or zero standard error
  (e.g. no winners, no losers, or no within-cell variation in Y).
  These cells have undefined or infinite t-statistics and cannot be
  graphed.

  This is the unfiltered version. Cells with very few observations or
  little within-cell variation will produce noisy or extreme t-stats,
  and that noise is exactly what the figure shows.
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 2: By-sorteo balance figure (no filter)"
di as text       "==================================================================="

use "$temp/cross_section_v2.dta", clear

* --- 2a. Run statsby for each variable on the full sample -------------------
tempfile orig
save `orig'

local first 1
foreach v in edad mujer pre_employed pre_wage {
    di as text _n "  statsby for: `v'"

    use `orig', clear

    capture noisily statsby b_`v' = _b[ganador] se_`v' = _se[ganador], ///
        by(sorteo_fe) clear nodots: regress `v' ganador

    if `first' {
        save "$temp/_balance_tstats.dta", replace
        local first 0
    }
    else {
        merge 1:1 sorteo_fe using "$temp/_balance_tstats.dta", nogenerate
        save "$temp/_balance_tstats.dta", replace
    }
}

erase `orig'

* --- 2b. Compute t-stats (drop only mathematically undefined cases) ---------
use "$temp/_balance_tstats.dta", clear

foreach v in edad mujer pre_employed pre_wage {
    gen double t_`v' = b_`v' / se_`v'
    * Drop only cells where the SE is missing or zero. These are
    * mathematically undefined (no within-cell variation, all winners,
    * or all losers) and cannot be plotted.
    replace t_`v' = . if missing(se_`v') | se_`v' == 0

    quietly count if !missing(t_`v')
    di as text "    `v': " %9.0fc r(N) " sorteos with finite t-stat"
    quietly sum t_`v', detail
    di as text "         min = " %9.2f r(min) "  p1 = " %9.2f r(p1) ///
              "  p99 = " %9.2f r(p99) "  max = " %9.2f r(max)
}

* --- 2c. Plot 4-panel kernel density ----------------------------------------
* We use kernel density (epanechnikov, default bandwidth) rather than a
* histogram. With binary/limited covariates in small cells, t-statistics are
* quantized at a few discrete values, which produces jagged histogram spikes.
* KDE smooths over the quantization and gives a much cleaner comparison
* against the N(0,1) reference density.
*
* Display range: ±10. Without filtering, very small cells can produce
* extreme t-stats (well beyond ±4). The KDE is computed over [-10, 10],
* and any cells outside that range are excluded from the kernel density
* estimation only (the underlying t-stats themselves are kept in the data).
di as text _n "  Building 4-panel kernel density plot..."

local axis_min -10
local axis_max 10
local y_max    0.5
local y_step   0.1

twoway (kdensity t_edad, kernel(epanechnikov) ///
            lwidth(medthick) lcolor(navy) lpattern(solid) ///
            n(400) range(`axis_min' `axis_max')) ///
       (function y = normalden(x), range(`axis_min' `axis_max') ///
            lwidth(medthick) lcolor(red) lpattern(dash)), ///
       xline(-1.96 1.96, lcolor(gs6) lpattern(dot)) ///
       xtitle("t-statistic", size(small)) ytitle("Density", size(small)) ///
       title("Age", size(small)) ///
       xlabel(`axis_min'(2)`axis_max', labsize(small)) ///
       ylabel(0(`y_step')`y_max', labsize(small)) ///
       yscale(range(0 `y_max')) ///
       legend(off) ///
       graphregion(color(white)) plotregion(color(white)) ///
       name(g_edad, replace)

twoway (kdensity t_mujer, kernel(epanechnikov) ///
            lwidth(medthick) lcolor(navy) lpattern(solid) ///
            n(400) range(`axis_min' `axis_max')) ///
       (function y = normalden(x), range(`axis_min' `axis_max') ///
            lwidth(medthick) lcolor(red) lpattern(dash)), ///
       xline(-1.96 1.96, lcolor(gs6) lpattern(dot)) ///
       xtitle("t-statistic", size(small)) ytitle("Density", size(small)) ///
       title("Female", size(small)) ///
       xlabel(`axis_min'(2)`axis_max', labsize(small)) ///
       ylabel(0(`y_step')`y_max', labsize(small)) ///
       yscale(range(0 `y_max')) ///
       legend(off) ///
       graphregion(color(white)) plotregion(color(white)) ///
       name(g_mujer, replace)

twoway (kdensity t_pre_employed, kernel(epanechnikov) ///
            lwidth(medthick) lcolor(navy) lpattern(solid) ///
            n(400) range(`axis_min' `axis_max')) ///
       (function y = normalden(x), range(`axis_min' `axis_max') ///
            lwidth(medthick) lcolor(red) lpattern(dash)), ///
       xline(-1.96 1.96, lcolor(gs6) lpattern(dot)) ///
       xtitle("t-statistic", size(small)) ytitle("Density", size(small)) ///
       title("Pre-treatment Employment", size(small)) ///
       xlabel(`axis_min'(2)`axis_max', labsize(small)) ///
       ylabel(0(`y_step')`y_max', labsize(small)) ///
       yscale(range(0 `y_max')) ///
       legend(off) ///
       graphregion(color(white)) plotregion(color(white)) ///
       name(g_pre_employed, replace)

twoway (kdensity t_pre_wage, kernel(epanechnikov) ///
            lwidth(medthick) lcolor(navy) lpattern(solid) ///
            n(400) range(`axis_min' `axis_max')) ///
       (function y = normalden(x), range(`axis_min' `axis_max') ///
            lwidth(medthick) lcolor(red) lpattern(dash)), ///
       xline(-1.96 1.96, lcolor(gs6) lpattern(dot)) ///
       xtitle("t-statistic", size(small)) ytitle("Density", size(small)) ///
       title("Pre-treatment Wage", size(small)) ///
       xlabel(`axis_min'(2)`axis_max', labsize(small)) ///
       ylabel(0(`y_step')`y_max', labsize(small)) ///
       yscale(range(0 `y_max')) ///
       legend(off) ///
       graphregion(color(white)) plotregion(color(white)) ///
       name(g_pre_wage, replace)

graph combine g_edad g_mujer g_pre_employed g_pre_wage, ///
    rows(2) cols(2) ///
    graphregion(color(white)) ///
    iscale(0.9) ///
    xsize(8) ysize(6) ///
    name(balance_combined, replace)

graph export "$figures/balance_tstats_by_sorteo_fe.pdf", replace
graph export "$figures/balance_tstats_by_sorteo_fe.png", replace width(2400)

erase "$temp/_balance_tstats.dta"

di as text _n "  done: Figures/balance_tstats_by_sorteo_fe.pdf"
di as text   "        Figures/balance_tstats_by_sorteo_fe.png"


/*==============================================================================
  STEP 3: WITHIN-SORTEO PERMUTATION TEST (Cullen-Jacob-Levitt 2006)

  For each covariate v, perform B_PERM within-sorteo permutations of
  the winner indicator and recompute the FE-residualized coefficient.
  Compare the observed coefficient to the permutation distribution and
  report a two-sided permutation p-value.

  We use the Frisch-Waugh-Lovell (FWL) representation for speed:
      beta = sum_i v_tilde_i * g_tilde_i / sum_i g_tilde_i^2
  where v_tilde and g_tilde are within-sorteo demeaned. Under within-
  sorteo permutation of g, the per-sorteo winner count nW_s is preserved,
  so the denominator sum_s nW_s * (n_s - nW_s) / n_s is constant. Only
  the numerator changes, and it simplifies to (sum of v_tilde over the
  permuted winners), which is a single sum-if per iteration.

  Each variable is processed on its own !missing(v) subsample so the
  per-sorteo winner counts are correctly defined relative to the
  regression sample.

  Runtime: ~20-30 min per variable for B_PERM=1000 (depends on sample
  size and machine). Total ~1.5-2 hours.
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 3: Within-sorteo permutation test (B = `B_PERM')"
di as text       "==================================================================="

* Re-set seed so Step 3 is reproducible regardless of RNG consumption upstream
set seed 20260406

foreach v in edad mujer pre_employed pre_wage {

    di as text _n(2) "  --- Permuting `v' ---"

    use "$temp/cross_section_v2.dta", clear

    * Restrict to v-non-missing rows so per-sorteo winner counts are
    * correctly defined relative to the regression sample
    keep if !missing(`v')

    di as text "    Sample (v-non-miss): " %12.0fc _N

    * Within-sorteo demeaning of v (constant across permutations)
    bys sorteo_fe: egen double _mean_v = mean(`v')
    gen double v_tilde = `v' - _mean_v
    drop _mean_v

    * Per-sorteo winner count (constant across permutations on this subsample)
    bys sorteo_fe: egen long nW_s = total(ganador == 1)
    bys sorteo_fe: gen long n_s = _N

    * FWL denominator: sum over sorteos of nW_s * (n_s - nW_s) / n_s
    bys sorteo_fe: gen byte _first = (_n == 1)
    gen double _denom_contrib = nW_s * (n_s - nW_s) / n_s if _first
    qui sum _denom_contrib
    scalar denom_perm = r(sum)
    drop _denom_contrib _first

    di as text "    FWL denominator: " %12.4f denom_perm

    * Observed coefficient via FWL (numerically equal to reghdfe estimate)
    qui sum v_tilde if ganador == 1
    scalar b_obs_perm_`v' = r(sum) / denom_perm

    di as text "    Observed coef (FWL): " %12.6f b_obs_perm_`v'
    di as text "    Observed coef (reghdfe, Step 1): " %12.6f b_`v'

    * --- Postfile for permutation results ---------------------------------
    capture postclose pf
    postfile pf double b_perm using "$temp/_perm_`v'.dta", replace

    di as text _n "    Running `B_PERM' permutations..."

    quietly {
        forvalues b = 1/`B_PERM' {
            gen double _u = runiform()
            bys sorteo_fe (_u): gen long _rank = _n

            sum v_tilde if _rank <= nW_s, meanonly
            local pb = r(sum) / denom_perm
            post pf (`pb')

            drop _u _rank

            if mod(`b', 100) == 0 noisily di as text "      perm `b'/`B_PERM'"
        }
    }
    postclose pf

    di as text "    done: $temp/_perm_`v'.dta"
}

* --- 3a. Compute permutation summary statistics for each variable -----------
di as text _n "  Computing permutation summary statistics..."

foreach v in edad mujer pre_employed pre_wage {
    use "$temp/_perm_`v'.dta", clear

    qui count if abs(b_perm) >= abs(b_obs_perm_`v')
    scalar pval_perm_`v' = r(N) / `B_PERM'

    qui centile b_perm, centile(2.5 50 97.5)
    scalar perm_lo_`v'  = r(c_1)
    scalar perm_med_`v' = r(c_2)
    scalar perm_hi_`v'  = r(c_3)

    di as text "    `v': p_perm = " %5.3f pval_perm_`v' ///
              "  [2.5%, 97.5%] = [" %9.4f perm_lo_`v' ", " %9.4f perm_hi_`v' "]"
}

* Save consolidated permutation distribution
* Add perm_id to each file first so the 1:1 merges work
foreach v in edad mujer pre_employed pre_wage {
    use "$temp/_perm_`v'.dta", clear
    gen long perm_id = _n
    rename b_perm perm_b_`v'
    save "$temp/_perm_`v'.dta", replace
}

use "$temp/_perm_edad.dta", clear
foreach v in mujer pre_employed pre_wage {
    merge 1:1 perm_id using "$temp/_perm_`v'.dta", nogenerate
}
order perm_id perm_b_edad perm_b_mujer perm_b_pre_employed perm_b_pre_wage
save "$temp/balance_perm_distribution.dta", replace

* Cleanup intermediate files
foreach v in edad mujer pre_employed pre_wage {
    erase "$temp/_perm_`v'.dta"
}

* --- 3b. Build display strings for permutation table -----------------------
* For decimal columns (edad, mujer, pre_employed): 4 decimals
foreach v in edad mujer pre_employed {
    * Observed coef (use the reghdfe-based scalar from Step 1; equal to FWL)
    local bobs_`v'_s : di %9.4f b_`v'
    local bobs_`v'_s = trim("`bobs_`v'_s'")

    * Permutation 2.5 / 97.5 percentiles
    foreach pct in lo hi {
        local p_`v'_`pct'_raw : di %9.4f perm_`pct'_`v'
        local p_`v'_`pct'_raw = trim("`p_`v'_`pct'_raw'")
        local p_`v'_`pct'_neg = (perm_`pct'_`v' < 0)
        if `p_`v'_`pct'_neg' {
            local p_`v'_`pct'_mag = subinstr("`p_`v'_`pct'_raw'", "-", "", 1)
        }
        else {
            local p_`v'_`pct'_mag "`p_`v'_`pct'_raw'"
        }
    }
}

* For pre_wage (comma-separated integer)
local bobs_pre_wage_raw : di %12.0fc b_pre_wage
local bobs_pre_wage_raw = trim("`bobs_pre_wage_raw'")
local bobs_pre_wage_neg = (b_pre_wage < 0)
if `bobs_pre_wage_neg' {
    local bobs_pre_wage_mag = subinstr("`bobs_pre_wage_raw'", "-", "", 1)
}
else {
    local bobs_pre_wage_mag "`bobs_pre_wage_raw'"
}
local bobs_pre_wage_mag = subinstr("`bobs_pre_wage_mag'", ",", "{,}", .)

foreach pct in lo hi {
    local pwraw : di %12.0fc perm_`pct'_pre_wage
    local pwraw = trim("`pwraw'")
    local p_pre_wage_`pct'_neg = (perm_`pct'_pre_wage < 0)
    if `p_pre_wage_`pct'_neg' {
        local p_pre_wage_`pct'_mag = subinstr("`pwraw'", "-", "", 1)
    }
    else {
        local p_pre_wage_`pct'_mag "`pwraw'"
    }
    local p_pre_wage_`pct'_mag = subinstr("`p_pre_wage_`pct'_mag'", ",", "{,}", .)
}

* Permutation p-values (3 decimals)
foreach v in edad mujer pre_employed pre_wage {
    local pval_`v'_s : di %5.3f pval_perm_`v'
    local pval_`v'_s = trim("`pval_`v'_s'")
}

* Replication count (formatted)
local B_str : di %9.0fc `B_PERM'
local B_str = trim("`B_str'")
local B_str = subinstr("`B_str'", ",", "{,}", .)

* --- 3c. Write balance_permutation.tex --------------------------------------
file open f using "$tables/balance_permutation.tex", write replace text

file write f "\begin{table}[H]\centering" _n
file write f "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
file write f "\caption{Within-Sorteo Permutation Test (`B_str' replications)}" _n
file write f "\label{tab:balance_permutation}" _n
file write f "\begin{tabular}{l*{4}{c}}" _n
file write f "\hline\hline" _n
file write f "                       & \multicolumn{1}{c}{(1)} & \multicolumn{1}{c}{(2)} & \multicolumn{1}{c}{(3)} & \multicolumn{1}{c}{(4)} \\" _n
file write f "                       & \multicolumn{1}{c}{Age} & \multicolumn{1}{c}{Female} & \multicolumn{1}{c}{Pre-Employed} & \multicolumn{1}{c}{Pre-Wage (ARS)} \\" _n
file write f "\hline" _n

* Observed coefficient row
local obs_row "Observed coefficient  "
foreach v in edad mujer pre_employed {
    local obs_row "`obs_row'  &  `bobs_`v'_s'"
}
if `bobs_pre_wage_neg' {
    local obs_row "`obs_row'  &  \$-\$`bobs_pre_wage_mag'"
}
else {
    local obs_row "`obs_row'  &  `bobs_pre_wage_mag'"
}
local obs_row "`obs_row'  \\"
file write f "`obs_row'" _n

* Perm 2.5 percentile row
local lo_row "Perm.\ 2.5 percentile "
foreach v in edad mujer pre_employed pre_wage {
    if `p_`v'_lo_neg' {
        local lo_row "`lo_row'  &  \$-\$`p_`v'_lo_mag'"
    }
    else {
        local lo_row "`lo_row'  &  `p_`v'_lo_mag'"
    }
}
local lo_row "`lo_row'  \\"
file write f "`lo_row'" _n

* Perm 97.5 percentile row
local hi_row "Perm.\ 97.5 percentile"
foreach v in edad mujer pre_employed pre_wage {
    if `p_`v'_hi_neg' {
        local hi_row "`hi_row'  &  \$-\$`p_`v'_hi_mag'"
    }
    else {
        local hi_row "`hi_row'  &  `p_`v'_hi_mag'"
    }
}
local hi_row "`hi_row'  \\"
file write f "`hi_row'" _n

file write f "\hline" _n

* Permutation p-value row -- write directly to avoid macro re-expansion of $p$
local pv_vals ""
foreach v in edad mujer pre_employed pre_wage {
    local pv_vals "`pv_vals'  &  `pval_`v'_s'"
}
file write f "Two-sided perm.\ \$p\$-value`pv_vals'  \\" _n

* Replications row
file write f "Replications           &  `B_str'    &  `B_str'    &  `B_str'    &  `B_str'    \\" _n

file write f "\hline\hline" _n
file write f "\multicolumn{5}{p{0.92\textwidth}}{\footnotesize Within-sorteo permutation test following \citet{cullenJacobLevitt2006}: for each replication the winner indicator is randomly permuted within each sorteo (preserving the per-sorteo winner count) and the FE-residualized coefficient on the covariate is recomputed. The two-sided permutation \$p\$-value is the fraction of replications with \$|\hat{\beta}_{\text{perm}}| \ge |\hat{\beta}_{\text{obs}}|\$. Sample restricted to non-missing observations of each covariate.} \\" _n
file write f "\end{tabular}" _n
file write f "\end{table}" _n

file close f

di as text _n "  done: tables/balance_permutation.tex"


/*==============================================================================
  END
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  paper_balance.do COMPLETE"
di as text       "==================================================================="
di as text _n "  Outputs:"
di as text   "    tables/balance_pooled.tex"
di as text   "    Figures/balance_tstats_by_sorteo_fe.pdf"
di as text   "    Figures/balance_tstats_by_sorteo_fe.png"
di as text   "    tables/balance_permutation.tex"
di as text   "    " "$temp" "/balance_perm_distribution.dta (raw permutation draws)"
di as text _n
