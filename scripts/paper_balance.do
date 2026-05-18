/*==============================================================================
  PROCREAR — Paper Tables: Sample Balance

  THIS SCRIPT GENERATES THE OFFICIAL PAPER OUTPUT FOR THE SAMPLE BALANCE
  SECTION. It produces one table:

    tables/balance_pooled.tex
        Pooled balance regression: 5 columns (Age, Female, Pre-Employed,
        Pre-Wage, N Kids Pre). Cols 1-4 are OLS of each covariate on the
        winner indicator with sorteo FE absorbed (no controls); col 5
        additionally controls for age to net out the small age channel.
        SE clustered at person level. Reports coefficient, SE, control
        mean, control SD, standardized difference (b/csd), and N.

  SELF-CONTAINED: this script builds its own balance cross-section from
  raw inputs (Data_sorteos.dta, Data_SIPA.dta, Inflacion_desde_Ene2007.dta,
  TEMP/cross_section_hijos_full.dta) and writes to
  $temp/cross_section_balance.dta. Does NOT depend on paper_labor_outcomes.do
  or other pipelines.

  ===========================================================================
  OUTPUT → PAPER MAPPING
  ===========================================================================

  Output file                                   Paper location
  --------------------------------------------- ---------------------------
  tables/balance_pooled.tex                     Sample Balance
                                                  (tab:balance_pooled)

  ===========================================================================
  OUTLINE
  ===========================================================================

  STEP 0: Build self-contained cross-section for balance
          0.1  Deflator from Inflacion_desde_Ene2007.dta
          0.2  Sorteo sample (edad_sorteo + CUIL imputation + mujer)
          0.3  SIPA pre-treatment panel (filtered, deseasonalized, deflated)
          0.4  Merge at sorteo_month → cross_section_balance.dta
          0.5  Merge kids info from cross_section_hijos_full.dta
  STEP 1:    Pooled balance table — reghdfe of each covariate on ganador

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

* RNG seed for reproducibility (kept although no permutation block uses it now;
* harmless to leave in for future stochastic steps)
set seed 20260406


/*==============================================================================
  STEP 0: BUILD SELF-CONTAINED CROSS-SECTION FOR BALANCE

  Self-contained pipeline: produces $temp/cross_section_balance.dta with the
  4 balance covariates (edad, mujer, pre_employed, pre_wage) plus keys
  (id_anon, ganador, sorteo_fe, fecha_sorteo). Uses its own intermediate
  files (prefixed _balance_) to avoid conflicts with other scripts that
  also write cross_section_v2.dta or sipa_panel.dta.

  Sub-steps:
    0.1  Deflator    : Inflacion_desde_Ene2007.dta → _balance_deflator.dta
    0.2  Sorteos     : Data_sorteos.dta → _balance_sorteo.dta
         * sorteo_fe = group(fecha_sorteo tipo desarrollo tipologia cupo)
         * drop tipo_grupo == 4 (Refacción) and degenerate sorteos (winrate
           == 0 or == 1)
         * edad: exact age at sorteo date from fnacimiento (no imputation).
                 Rows with edad >= 66 are set to missing (outlier filter).
                 Rows with missing fnacimiento remain missing edad.
         * mujer: taken directly from Data_sorteos.mujer (1=mujer, 0=varon,
           .=desconocido)
    0.3  SIPA pre-tx : Data_SIPA.dta → _balance_sipa_pretreat.dta
         * filter to sample id_anon
         * deseasonalize: wage_desest = remuneracion - sac (exact)
         * deflate to constant prices, collapse (sum real_wage)
         * by id_anon periodo_month
    0.4  Merge       : sorteo × SIPA at periodo_month == sorteo_month
                       → cross_section_balance.dta
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 0: Build self-contained cross-section for balance"
di as text       "==================================================================="


/*----------------------------------------------------------------------------*/
/*  0.1  DEFLATOR                                                              */
/*----------------------------------------------------------------------------*/
di as text _n "--- 0.1 Building deflator ---"

use "$data/Inflacion_desde_Ene2007.dta", clear
rename Periodo       periodo_month
rename Inflacion     tasa_inflacion
format periodo_month %tm
sort periodo_month

gen double ipc = 100 in 1
replace ipc = ipc[_n-1] * (1 + tasa_inflacion / 100) in 2/L

quietly sum ipc if _n == _N
local ipc_base = r(mean)
gen double deflator = ipc / `ipc_base'

keep periodo_month deflator
save "$temp/_balance_deflator.dta", replace
di as text "    deflator saved (" _N " months)"


/*----------------------------------------------------------------------------*/
/*  0.2  SORTEO SAMPLE (edad exacta + mujer direct from Data_sorteos)          */
/*----------------------------------------------------------------------------*/
di as text _n "--- 0.2 Building sorteo sample ---"

use "$data/Data_sorteos.dta", clear

* --- Fill missings for FE grouping and construct sorteo_fe ------------------
replace desarrollourbanistico = 0 if desarrollourbanistico == .
replace tipologia             = 0 if tipologia == .
replace cupo                  = 0 if cupo == .
egen sorteo_fe = group(fecha_sorteo tipo desarrollourbanistico tipologia cupo)

* --- Credit type groups and drop Refacción ----------------------------------
gen tipo_grupo = .
replace tipo_grupo = 1 if tipo == 5
replace tipo_grupo = 2 if inlist(tipo, 2, 3, 4)
replace tipo_grupo = 3 if inlist(tipo, 6)
replace tipo_grupo = 4 if inlist(tipo, 1, 8, 9, 10, 11, 12, 13)
label define tipo_grupo_lbl 1 "DU" 2 "Construccion" 3 "Lotes" 4 "Refaccion", replace
label values tipo_grupo tipo_grupo_lbl

drop if tipo_grupo == 4

* --- Drop degenerate sorteos (winrate 0 or 1) -------------------------------
bys sorteo_fe: egen _winrate = mean(ganador)
drop if _winrate == 0 | _winrate == 1
drop _winrate

* --- Drop sorteos with zero receptors ----------------------------------------
*     Cells where no lottery winner ended up taking the loan provide zero
*     treatment variation. Excluding them matches the analysis sample used
*     in the labor and BCRA tables (see paper_labor_outcomes.do).
bys sorteo_fe: egen _n_rec = total(receptor)
drop if _n_rec == 0
drop _n_rec

* --- Time variables ---------------------------------------------------------
gen sorteo_month = mofd(fecha_sorteo)
format sorteo_month %tm

* --- edad: edad_sorteo directly from Data_sorteos -------------------------
*     Primary source: edad_sorteo (already present in Data_sorteos).
*     If missing, impute via CUIL-prefix matching: extract digits 3-6 of
*     CUIL as a 4-digit key, but only if digits 3-4 are in [00, 45].
*     Donor = median edad_sorteo among OTHER rows with the same 4-digit
*     key. If no donor matches, edad stays missing.
*     Final outlier filter: drop edad >= 66 (PROCREAR eligibility cap 64).

capture drop edad
gen int edad = edad_sorteo

count if missing(edad)
local n_miss_pre = r(N)
di as text "    edad_sorteo missing (pre-imputation): " %12.0fc `n_miss_pre'

* --- CUIL-prefix imputation -----------------------------------------------

* Confirm cuil is string (Data_sorteos.cuil should be a string column)
capture confirm string variable cuil
if _rc {
    di as error "cuil expected to be a string variable in Data_sorteos"
    exit 198
}

* Strip common separators (hyphens, spaces) so digit positions are clean
gen str11 _cuil_clean = subinstr(subinstr(cuil, "-", "", .), " ", "", .)

* Extract digits 3-6 as a 4-digit key; empty if CUIL too short
gen str4 _cuil_key = substr(_cuil_clean, 3, 4)
replace _cuil_key = "" if strlen(_cuil_clean) < 6

* Validity check: digits 3-4 of CUIL (first 2 of the key) must be in [00, 45]
gen int _key_first2 = real(substr(_cuil_key, 1, 2))
gen byte _key_valid = (_key_first2 >= 0 & _key_first2 <= 45) ///
    if !missing(_key_first2)

* Build donor lookup: median edad_sorteo among rows with valid key + known edad
preserve
    keep if !missing(edad) & _key_valid == 1
    collapse (median) _edad_donor = edad, by(_cuil_key)
    save "$temp/_balance_edad_donor.dta", replace
restore

merge m:1 _cuil_key using "$temp/_balance_edad_donor.dta", ///
    keep(master match) nogenerate
erase "$temp/_balance_edad_donor.dta"

* Apply imputation: only where edad is missing, key is valid, AND a donor exists
replace edad = _edad_donor if missing(edad) & _key_valid == 1 & !missing(_edad_donor)

count if missing(edad)
local n_miss_post = r(N)
di as text "    edad missing (post-imputation):       " %12.0fc `n_miss_post'
di as text "    edad imputed via CUIL prefix:         " %12.0fc `n_miss_pre' - `n_miss_post'

drop _cuil_clean _cuil_key _key_first2 _key_valid _edad_donor

* --- Outlier filter: edad >= 66 -------------------------------------------
*count if edad >= 66 & !missing(edad)
*di as text "    edad >= 66 seteadas a missing: " r(N)
*replace edad = . if edad >= 66 & !missing(edad)

label variable edad "Edad al sorteo (edad_sorteo + CUIL-prefix imputation, edad>=66 missing)"

* --- mujer: directly from Data_sorteos.mujer --------------------------------
*   1=mujer, 0=varon, .=desconocido (kept as-is).
label variable mujer "Genero (1=mujer, 0=varon, .=desconocido) de Data_sorteos"
label define mujer_lbl 0 "Varon" 1 "Mujer", replace
label values mujer mujer_lbl

* --- Keep only what balance needs downstream --------------------------------
keep id_anon ganador sorteo_fe fecha_sorteo sorteo_month edad mujer

di as text "    rows: " _N
di as text "    edad non-missing:"
count if !missing(edad)
di as text "      " r(N) " (" %5.2f 100*r(N)/_N "%)"
di as text "    mujer distribution:"
tab mujer, m

* (sin auxiliares: la imputacion CUIL-prefix fue removida)

save "$temp/_balance_sorteo.dta", replace


/*----------------------------------------------------------------------------*/
/*  0.3  SIPA PRE-TREATMENT PANEL                                              */
/*----------------------------------------------------------------------------*/
di as text _n "--- 0.3 Building SIPA pre-treatment panel ---"

* Build id_anon list from sorteo sample (filter SIPA to these)
preserve
    use "$temp/_balance_sorteo.dta", clear
    keep id_anon
    duplicates drop
    save "$temp/_balance_id_list.dta", replace
restore

use "$data/Data_SIPA.dta", clear

merge m:1 id_anon using "$temp/_balance_id_list.dta", keep(match) nogenerate

gen int _y = floor(mes / 100)
gen int _m = mod(mes, 100)
gen periodo_month = ym(_y, _m)
format periodo_month %tm
drop _y _m

* Aguinaldo deseasonalization: restar el SAC (sueldo anual complementario)
* Supersedes the prior jun/dec ÷ 1.5 heuristic. The `sac` column in SIPA
* gives the exact SAC paid that month, so subtraction is cleaner than the
* 1.5 divisor (which assumed exactly 50/50 split in jun/dec).
gen double wage_desest = remuneracion
replace wage_desest = remuneracion - sac if !missing(sac)
replace wage_desest = 0 if wage_desest < 0 & !missing(wage_desest)

* Deflate to constant prices
merge m:1 periodo_month using "$temp/_balance_deflator.dta", keep(master match) nogenerate
gen double real_wage = wage_desest / deflator
replace real_wage = 0 if wage_desest == .

* Collapse to person-month (drop mujer from SIPA: we use Data_sorteos.mujer)
di as text "    collapsing SIPA to person-month..."
collapse (sum) pre_wage = real_wage, by(id_anon periodo_month)
gen byte pre_employed = 1
replace pre_employed = 0 if pre_wage == 0

save "$temp/_balance_sipa_pretreat.dta", replace
erase "$temp/_balance_id_list.dta"
di as text "    SIPA panel rows: " _N


/*----------------------------------------------------------------------------*/
/*  0.4  MERGE AT sorteo_month → cross_section_balance.dta                    */
/*----------------------------------------------------------------------------*/
di as text _n "--- 0.4 Merging pre-treatment at sorteo_month ---"

use "$temp/_balance_sorteo.dta", clear
gen periodo_month = sorteo_month
format periodo_month %tm

merge m:1 id_anon periodo_month using "$temp/_balance_sipa_pretreat.dta", ///
    keep(master match) nogenerate

replace pre_wage     = 0 if missing(pre_wage)
replace pre_employed = 0 if missing(pre_employed)

drop periodo_month

label variable pre_wage     "Salario real (ARS const.) en mes del sorteo (SIPA)"
label variable pre_employed "Indicador: aparece en SIPA en mes del sorteo"

di as text "    final rows: " _N
di as text "    pre-treatment summary:"
sum pre_employed pre_wage


/*----------------------------------------------------------------------------*/
/*  0.5  MERGE KIDS INFO (n_kids_pre, had_kid_pre) from hijos cross-section   */
/*----------------------------------------------------------------------------*/
di as text _n "--- 0.5 Merging kids info (n_kids_pre, had_kid_pre) ---"

preserve
    use id_anon sorteo_fe n_kids_pre had_kid_pre ///
        using "$temp/cross_section_hijos_full.dta", clear
    * Deduplicate keys (a small number of (id_anon, sorteo_fe) pairs have
    * multiple rows in the hijos file; keep first to make the merge 1:1)
    duplicates drop id_anon sorteo_fe, force
    save "$temp/_balance_kids_lookup.dta", replace
restore

merge m:1 id_anon sorteo_fe using "$temp/_balance_kids_lookup.dta", ///
    keep(master match) nogenerate
erase "$temp/_balance_kids_lookup.dta"

label variable n_kids_pre  "# hijos al cierre del año (sorteo - 1)"
label variable had_kid_pre "1 si tenia al menos un hijo al cierre del año (sorteo - 1)"

count if missing(n_kids_pre)
di as text "    n_kids_pre missing after merge: " %12.0fc r(N)
count if missing(had_kid_pre)
di as text "    had_kid_pre missing after merge: " %12.0fc r(N)

di as text _n "    kids summary:"
sum n_kids_pre had_kid_pre

save "$temp/cross_section_balance.dta", replace

* --- 0.6 Cleanup ------------------------------------------------------------
erase "$temp/_balance_deflator.dta"
erase "$temp/_balance_sorteo.dta"
erase "$temp/_balance_sipa_pretreat.dta"

di as text _n "  done: cross_section_balance.dta built from scratch"


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

use "$temp/cross_section_balance.dta", clear

* Sanity check: required variables exist
foreach v in edad mujer pre_employed pre_wage n_kids_pre had_kid_pre ganador sorteo_fe id_anon {
    capture confirm variable `v'
    if _rc {
        di as error "Variable `v' not found in cross_section_balance.dta"
        di as error "STEP 0 failed to produce the expected schema. Re-run STEP 0."
        exit 111
    }
}

di as text _n "Sample size: " %12.0fc _N
quietly egen _sg = group(sorteo_fe)
quietly sum _sg
di as text "Unique sorteos: " %9.0fc r(max)
drop _sg

* --- 1a. Run regressions and capture stats -----------------------------------
foreach v in edad mujer pre_employed pre_wage n_kids_pre had_kid_pre {
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

* --- 1a.bis. n_kids_pre controlling for edad (for the main balance table) ----
di as text _n "  reghdfe n_kids_pre ganador edad, absorb(sorteo_fe) cluster(id_anon)"
qui reghdfe n_kids_pre ganador edad, absorb(sorteo_fe) cluster(id_anon)

scalar bC_n_kids_pre      = _b[ganador]
scalar seC_n_kids_pre     = _se[ganador]
scalar nC_n_kids_pre      = e(N)
scalar pC_n_kids_pre      = 2 * ttail(e(df_r), abs(bC_n_kids_pre / seC_n_kids_pre))

qui sum n_kids_pre if ganador == 0
scalar cmeanC_n_kids_pre  = r(mean)
scalar csdC_n_kids_pre    = r(sd)
scalar stddifC_n_kids_pre = bC_n_kids_pre / csdC_n_kids_pre

di as text "    b = " %12.4f bC_n_kids_pre "   se = " %12.4f seC_n_kids_pre "   N = " %12.0fc nC_n_kids_pre
di as text "    cmean = " %12.4f cmeanC_n_kids_pre "   csd = " %12.4f csdC_n_kids_pre "   stddif = " %9.4f stddifC_n_kids_pre

* --- 1b. Build display strings -----------------------------------------------
* Stars (based on p-values)
foreach v in edad mujer pre_employed pre_wage n_kids_pre had_kid_pre {
    local star_`v' ""
    if p_`v' < 0.10  local star_`v' "\sym{*}"
    if p_`v' < 0.05  local star_`v' "\sym{**}"
    if p_`v' < 0.01  local star_`v' "\sym{***}"
}

* Stars for the edad-conditioned n_kids_pre
local starC_n_kids_pre ""
if pC_n_kids_pre < 0.10  local starC_n_kids_pre "\sym{*}"
if pC_n_kids_pre < 0.05  local starC_n_kids_pre "\sym{**}"
if pC_n_kids_pre < 0.01  local starC_n_kids_pre "\sym{***}"

* Display strings for the edad-conditioned n_kids_pre
local bC_n_kids_pre_s  : di %9.4f bC_n_kids_pre
local bC_n_kids_pre_s  = trim("`bC_n_kids_pre_s'")
local seC_n_kids_pre_s : di %9.4f seC_n_kids_pre
local seC_n_kids_pre_s = trim("`seC_n_kids_pre_s'")
local cmeanC_n_kids_pre_s : di %9.3f cmeanC_n_kids_pre
local cmeanC_n_kids_pre_s = trim("`cmeanC_n_kids_pre_s'")
local csdC_n_kids_pre_s : di %9.3f csdC_n_kids_pre
local csdC_n_kids_pre_s = trim("`csdC_n_kids_pre_s'")
local stdC_n_kids_pre_raw : di %9.3f stddifC_n_kids_pre
local stdC_n_kids_pre_raw = trim("`stdC_n_kids_pre_raw'")
local stdC_n_kids_pre_neg = (stddifC_n_kids_pre < 0)
if `stdC_n_kids_pre_neg' {
    local stdC_n_kids_pre_mag = subinstr("`stdC_n_kids_pre_raw'", "-", "", 1)
}
else {
    local stdC_n_kids_pre_mag "`stdC_n_kids_pre_raw'"
}
local nC_n_kids_pre_raw : di %12.0fc nC_n_kids_pre
local nC_n_kids_pre_raw = trim("`nC_n_kids_pre_raw'")
local nC_n_kids_pre_s = subinstr("`nC_n_kids_pre_raw'", ",", "{,}", .)

* Coefficient + SE strings (4-decimal columns: edad, mujer, pre_employed, n_kids_pre, had_kid_pre)
foreach v in edad mujer pre_employed n_kids_pre had_kid_pre {
    local b_`v'_s  : di %9.4f b_`v'
    local b_`v'_s  = trim("`b_`v'_s'")
    local b_`v'_neg = (b_`v' < 0)
    if `b_`v'_neg' {
        local b_`v'_mag = subinstr("`b_`v'_s'", "-", "", 1)
    }
    else {
        local b_`v'_mag "`b_`v'_s'"
    }
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
foreach v in edad mujer pre_employed n_kids_pre had_kid_pre {
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
foreach v in edad mujer pre_employed pre_wage n_kids_pre had_kid_pre {
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
foreach v in edad mujer pre_employed pre_wage n_kids_pre had_kid_pre {
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
file write f "\begin{tabular}{l*{5}{c}}" _n
file write f "\hline\hline" _n
file write f "                    & \multicolumn{1}{c}{(1)} & \multicolumn{1}{c}{(2)} & \multicolumn{1}{c}{(3)} & \multicolumn{1}{c}{(4)} & \multicolumn{1}{c}{(5)} \\" _n
file write f "                    & \multicolumn{1}{c}{Age} & \multicolumn{1}{c}{Female} & \multicolumn{1}{c}{Pre-Employed} & \multicolumn{1}{c}{Pre-Wage} & \multicolumn{1}{c}{N Kids Pre} \\" _n
file write f "\hline" _n

* Coefficient row (math-mode minus for negative wage coefficient)
if `b_pre_wage_neg' {
    file write f "Lottery Winner      &  `b_edad_s'`star_edad'  &  `b_mujer_s'`star_mujer'  &  `b_pre_employed_s'`star_pre_employed'  &  \$-\$`b_pre_wage_mag'`star_pre_wage'  &  `bC_n_kids_pre_s'`starC_n_kids_pre'  \\" _n
}
else {
    file write f "Lottery Winner      &  `b_edad_s'`star_edad'  &  `b_mujer_s'`star_mujer'  &  `b_pre_employed_s'`star_pre_employed'  &  `b_pre_wage_mag'`star_pre_wage'  &  `bC_n_kids_pre_s'`starC_n_kids_pre'  \\" _n
}

* SE row (parentheses)
file write f "                    &  (`se_edad_s')         &  (`se_mujer_s')          &  (`se_pre_employed_s')          &  (`se_pre_wage_s')            &  (`seC_n_kids_pre_s')  \\" _n

file write f "\hline" _n
file write f "Control mean        &  `cmean_edad_s'         &  `cmean_mujer_s'          &  `cmean_pre_employed_s'          &  `cmean_pre_wage_s'          &  `cmeanC_n_kids_pre_s'  \\" _n
file write f "Control SD          &  `csd_edad_s'         &  `csd_mujer_s'          &  `csd_pre_employed_s'          &  `csd_pre_wage_s'          &  `csdC_n_kids_pre_s'  \\" _n

* Std diff row — handle each cell's sign individually (col 5 uses conditional std diff)
local std_row "Std.\ difference   "
foreach v in edad mujer pre_employed pre_wage {
    if `std_`v'_neg' {
        local std_row "`std_row'  &  \$-\$`std_`v'_mag'"
    }
    else {
        local std_row "`std_row'  &  `std_`v'_mag'"
    }
}
if `stdC_n_kids_pre_neg' {
    local std_row "`std_row'  &  \$-\$`stdC_n_kids_pre_mag'"
}
else {
    local std_row "`std_row'  &  `stdC_n_kids_pre_mag'"
}
local std_row "`std_row'  \\"
file write f "`std_row'" _n

file write f "Observations        &  `n_edad_s'      &  `n_mujer_s'        &  `n_pre_employed_s'      &  `n_pre_wage_s'         &  `nC_n_kids_pre_s'  \\" _n
file write f "Controls for age    &  --  &  --  &  --  &  --  &  \checkmark  \\" _n

file write f "\hline\hline" _n
file write f "\multicolumn{6}{p{0.95\textwidth}}{\footnotesize OLS with sorteo FE absorbed. SE clustered at person level. Pre-treatment covariates measured at sorteo month from SIPA. \emph{N Kids Pre} is the cumulative number of children born to the applicant by the end of the calendar year before the sorteo (column~5). All regressions include sorteo FE only, \emph{except column~5 which additionally controls for age at the sorteo} (the unconditional regression for \emph{N Kids Pre} shows an imbalance fully explained by the small age difference reported in column~1). Standardized difference \$=\$ coefficient \$/\$ control-group SD.} \\" _n
file write f "\multicolumn{6}{l}{\footnotesize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)} \\" _n
file write f "\end{tabular}" _n
file write f "\end{table}" _n

file close f

di as text _n "  done: tables/balance_pooled.tex"



/*==============================================================================
  END
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  paper_balance.do COMPLETE"
di as text       "==================================================================="
di as text _n "  Outputs:"
di as text   "    tables/balance_pooled.tex"
di as text _n
