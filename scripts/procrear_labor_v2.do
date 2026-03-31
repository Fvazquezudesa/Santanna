/*==============================================================================
  PROCREAR — Labor Market Analysis (v2: sorteo-level unit of observation)

  Effect of PROCREAR housing credit on labor market outcomes.

  Identification: Lottery assignment (ganador) as IV for credit receipt
                  (receptor). Sorteo FE absorb randomization pools.

  KEY DIFFERENCE FROM v1:
    Unit of observation = person × sorteo inscription (not person).
    A person who entered 3 lotteries appears 3 times.
    This correctly assigns each observation to its randomization pool
    (fecha_sorteo × tipo) and avoids misattributing credit types.
    SE clustered at the person level throughout.

  Intermediate datasets are saved to $root/TEMP/ so you can skip Steps 1-4
  on re-runs. To start from estimation only, jump to STEP 5.

  ===========================================================================
  OUTLINE
  ===========================================================================

  STEP 1: Build the monthly price deflator (Inflacion_desde_Ene2007.dta)
          - Output: $temp/deflator.dta

  STEP 2: Build sorteo-level analysis sample (Data_sorteos.dta)
          - One observation per person × sorteo inscription
          - Treatment: ganador, receptor (at this sorteo)
          - FE: sorteo_fe = group(fecha_sorteo, tipo)
          - Drop non-lottery sorteos (100% win rate)
          - Output: $temp/sorteo_sample_v2.dta

  STEP 3: Build SIPA person-month panel (Data_SIPA.dta, ~6 GB)
          - Output: $temp/sipa_panel.dta (reuses v1 if already built)

  STEP 4: Merge sorteo sample with SIPA panel → cross-section
          - Last SIPA period per person, merged onto each sorteo row
          - Output: $temp/cross_section_v2.dta

  STEP 5: Estimation — ITT (Tables 6a, 6b)
  STEP 6: Estimation — IV / 2SLS (Tables 7a, 7b)
  STEP 7: Heterogeneity by lottery cohort (Tables 8, 9, 10)
  STEP 8: Heterogeneity by credit type (Tables 11, 12, 13)

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
* ssc install estout, replace
* ssc install reghdfe, replace
* ssc install ftools, replace


/*==============================================================================
  STEP 1: BUILD MONTHLY PRICE DEFLATOR
  (Identical to v1 — reuses $temp/deflator.dta if already built)
==============================================================================*/

di as text _n "=== STEP 1: Building price deflator ===" _n

use "$data/Inflacion_desde_Ene2007.dta", clear

rename Periodo periodo_month
rename Inflacion tasa_inflacion
format periodo_month %tm

sort periodo_month

gen double ipc = 100 in 1
replace ipc = ipc[_n-1] * (1 + tasa_inflacion / 100) in 2/L

quietly sum ipc if _n == _N
local ipc_base = r(mean)
gen double deflator = ipc / `ipc_base'

di as text "Deflator: first and last values"
list periodo_month tasa_inflacion ipc deflator in 1/3
list periodo_month tasa_inflacion ipc deflator in -3/L

keep periodo_month deflator

save "$temp/deflator.dta", replace

di as text "Deflator saved. " _N " months."



/*==============================================================================
  STEP 2: BUILD SORTEO-LEVEL ANALYSIS SAMPLE

  Source: Data_sorteos.dta
  Unit: person × sorteo inscription

  Each row is one inscription. A person can appear multiple times.
  We keep ALL inscriptions (not just the first), because:
    - Each inscription belongs to a specific (fecha_sorteo, tipo) pool
    - Randomization happens within each pool
    - Collapsing to person level misattributes types for multi-inscribers

  Variables:
    - ganador: won THIS specific lottery (0/1)
    - receptor: received credit from THIS lottery (0/1)
    - sorteo_fe: group(fecha_sorteo, tipo) — randomization pool
    - tipo / tipo_grupo: credit type and grouped type
==============================================================================*/

di as text _n "=== STEP 2: Building sorteo-level sample ===" _n

use "$data/Data_sorteos.dta", clear

di as text "Raw sorteos: N = " _N

* --- CUIL prefix → birth date mapping (built before filtering) ----------------
di as text "Building CUIL prefix → birth date mapping..."

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
gen med_birth_year = year(med_birth_date)
gen med_birth_month = month(med_birth_date)

tempfile prefix_map
save `prefix_map'
restore

* --- Fill missings for FE grouping -------------------------------------------
replace desarrollourbanistico = 0 if desarrollourbanistico == .
replace tipologia = 0 if tipologia == .
replace cupo = 0 if cupo == .


* --- Sorteo FE = fecha_sorteo × tipo × desarrollourbanistico × tipologia -----
*     This is the actual randomization pool.
egen sorteo_fe = group(fecha_sorteo tipo desarrollourbanistico tipologia cupo)

* --- Credit type groups -------------------------------------------------------
* tipo is encoded: 1=AM 2=CCP 3=CO 4=CP 5=DU 6=LS 7=LSC 8=MI
*                  9=RCP 10=RE100 11=RE240 12=RE250 13=RE500
gen tipo_grupo = .
replace tipo_grupo = 1 if tipo == 5                              // DU
replace tipo_grupo = 2 if inlist(tipo, 2, 3, 4)                  // Construcción
replace tipo_grupo = 3 if inlist(tipo, 6)                     // Lotes
replace tipo_grupo = 4 if inlist(tipo, 1, 8, 9, 10, 11, 12, 13) // Refacción
label define tipo_grupo_lbl 1 "DU" 2 "Construccion" 3 "Lotes" 4 "Refaccion"
label values tipo_grupo tipo_grupo_lbl

* --- DROP REFACCION (tipo_grupo == 4) from all analyses ---
di as text _n "Dropping Refaccion (tipo_grupo == 4)..."
count if tipo_grupo == 4
drop if tipo_grupo == 4

di as text _n "Credit type distribution (after dropping Refaccion):"
tab tipo
di as text _n "Credit type groups:"
tab tipo_grupo

* --- DROP DEGENERATE SORTEOS (winrate == 0 or winrate == 1) ------------------
bys sorteo_fe: egen _winrate = mean(ganador)
di as text _n "Dropping degenerate sorteos (winrate == 0 or winrate == 1):"
count if _winrate == 0 | _winrate == 1
drop if _winrate == 0 | _winrate == 1
drop _winrate

* --- Time variables -----------------------------------------------------------
gen sorteo_month = mofd(fecha_sorteo)
format sorteo_month %tm
gen cohort_year = year(fecha_sorteo)

* --- Derive edad from CUIL (with fallbacks) -----------------------------------
gen str3 dni_prefix_str = substr(cuil, 3, 3)
destring dni_prefix_str, gen(dni_prefix) force

merge m:1 dni_prefix using `prefix_map', keep(master match) nogenerate

gen sorteo_year = year(fecha_sorteo)
gen sorteo_month_num = month(fecha_sorteo)

rename edad edad_original

* Primary: CUIL prefix → median birth date mapping
gen edad = sorteo_year - med_birth_year
replace edad = edad - 1 if sorteo_month_num < med_birth_month & edad != .

* Fallback 1: individual's own fnacimiento
replace edad = sorteo_year - year(fnacimiento) if edad == . & fnacimiento != .
replace edad = edad - 1 if sorteo_month_num < month(fnacimiento) & edad != . & med_birth_year == .

* Fallback 2: original edad column from Data_sorteos
replace edad = edad_original if edad == . & edad_original != .

drop edad_original dni_prefix_str dni_prefix med_fnac med_birth_date ///
     med_birth_year med_birth_month sorteo_year sorteo_month_num fnacimiento

di as text "Age (edad) non-missing: "
count if edad != .
di as text "  " r(N) " of " _N " (" %4.1f 100*r(N)/_N "%)"

* --- Monotributo indicator ----------------------------------------------------
di as text _n "=== Monotributo diagnostic ==="
tab monotributo, m

* monotributo == 24 is "No inscripto" — treat as missing (not a monotributista)
replace monotributo = . if monotributo == 24
replace monotributo = . if monotributo == 1

gen byte is_monotributo = (monotributo > 0 & monotributo !=.)

save "$temp/sorteo_sample_v2.dta", replace


/*==============================================================================
  STEP 3: BUILD SIPA PERSON-MONTH PANEL
  (Same as v1 — we need person-level SIPA, then merge onto sorteo rows)
==============================================================================*/
    
	use "$data/Data_SIPA.dta", clear
    di as text "SIPA loaded. N = " _N

    * Filter to persons in our sample
    * Need unique person list from sorteo sample
    preserve
    use "$temp/sorteo_sample_v2.dta", clear
    keep id_anon
    duplicates drop
    save "$temp/_person_list.dta", replace
    restore

    merge m:1 id_anon using "$temp/_person_list.dta", keep(match) nogenerate
    di as text "After filtering to analysis sample: N = " _N

    * Create monthly date
    gen int _y = floor(mes / 100)
    gen int _m = mod(mes, 100)
    gen periodo_month = ym(_y, _m)
    format periodo_month %tm
    drop _y _m

    * Deseasonalize (aguinaldo adjustment)
    gen int cal_month = month(dofm(periodo_month))
    gen double wage_desest = remuneracion
    replace wage_desest = remuneracion / 1.5 if inlist(cal_month, 6, 12)
    drop cal_month

    * Deflate to constant prices
    merge m:1 periodo_month using "$temp/deflator.dta", keep(master match) nogenerat
    gen double real_wage = wage_desest / deflator
	replace real_wage=0 if wage_desest==.

    * Collapse to person × month
    di as text _n "Collapsing to person-month..."
    collapse (sum) total_wage=real_wage ///
             (firstnm) mujer, ///
             by(id_anon periodo_month)

    gen byte employed = 1

    save "$temp/sipa_panel.dta", replace
    erase "$temp/_person_list.dta"



/*==============================================================================
  STEP 4: MERGE AND BUILD CROSS-SECTION (v2: sorteo-level)

  We build PERSON-level labor outcomes first (last SIPA period, employed, wage),
  then merge these onto the sorteo-level sample.

  Result: each row = one person × sorteo inscription, with labor outcomes
  attached from the person's most recent SIPA record.
==============================================================================*/

di as text _n "=== STEP 4: Building cross-section (sorteo-level) ===" _n

* --- 4a. Build person-level labor outcomes ------------------------------------
* Start from unique persons in sorteo sample
use "$temp/sorteo_sample_v2.dta", clear
keep id_anon is_monotributo
duplicates drop id_anon, force

merge 1:m id_anon using "$temp/sipa_panel.dta"

* Fill zeros for persons without SIPA records
replace employed    = 0 if _merge == 1
replace total_wage  = 0 if _merge == 1

drop if _merge == 2
drop _merge

* Keep last available SIPA period per person
bys id_anon (periodo_month): keep if _n == _N

* Redefine employed: currently working
replace employed = (periodo_month >= ym(2025, 10))
replace employed = 0 if total_wage == 0
replace total_wage = 0 if employed == 0


di as text _n "=== Employed redefined: periodo_month >= 2025m10 ==="
tab employed

* Create additional outcomes
gen double log_wage = ln(total_wage) if employed == 1 & total_wage > 0
gen byte any_work = (employed == 1 | is_monotributo == 1)

* Keep only what we need for merge
keep id_anon employed total_wage log_wage any_work periodo_month mujer

save "$temp/_person_outcomes.dta", replace


* --- 4b. Merge person outcomes onto sorteo-level sample -----------------------
use "$temp/sorteo_sample_v2.dta", clear
keep id_anon ganador receptor sorteo_fe tipo tipo_grupo sorteo_month ///
     cohort_year fecha_sorteo is_monotributo edad genero

merge m:1 id_anon using "$temp/_person_outcomes.dta", keep(master match) nogenerate

* Fill missing mujer from Data_sorteos genero (encoded: 1=mujer, 2=hombre)
replace mujer = (genero == 1) if mujer == . & genero != .
drop genero

di as text _n "=== Cross-section (sorteo-level) ==="
di as text "N (person × sorteo) = " _N
di as text _n "Treatment status:"

save "$temp/cross_section_v2.dta", replace

erase "$temp/_person_outcomes.dta"

* --- 4c. Add pre-treatment outcomes (at sorteo month) -------------------------
* For each sorteo row, get the person's SIPA record at the month of the lottery.
* This serves as a baseline control for pre-existing wage/employment differences.

preserve
use "$temp/sipa_panel.dta", clear
rename total_wage pre_wage
rename employed pre_employed
save "$temp/_pretreat_sipa.dta", replace
restore

use "$temp/cross_section_v2.dta", clear
drop periodo_month
gen periodo_month = sorteo_month
format periodo_month %tm
merge m:1 id_anon periodo_month using "$temp/_pretreat_sipa.dta", ///
    keep(master match) nogenerate
replace pre_wage = 0 if pre_wage == .
replace pre_employed = 0 if pre_employed == .
drop periodo_month

di as text _n "=== Pre-treatment outcomes ==="
di as text "Pre-treatment employment rate:"
sum pre_employed
di as text "Pre-treatment wage (mean):"
sum pre_wage

save "$temp/cross_section_v2.dta", replace
erase "$temp/_pretreat_sipa.dta"


/*==============================================================================
  STEP 5: ITT — INTENT TO TREAT

  Reduced-form effect of winning the lottery (ganador) on outcomes.
  Sorteo FE absorbed via reghdfe.
  SE clustered at person level (same person can appear in multiple sorteos).
  Each table produced twice: without and with pre-treatment controls.

  Table 6a — Extensive margin: employed, monotributo, any_work
  Table 6b — Intensive margin: wage (levels), log wage|employed
==============================================================================*/

di as text _n "=== STEP 5: ITT ===" _n

use "$temp/cross_section_v2.dta", clear

foreach ctl in "noctl" "ctl" {
    if "`ctl'" == "noctl" local controls ""
    if "`ctl'" == "noctl" local note_ctl "No pre-treatment controls."
    if "`ctl'" == "ctl"   local controls "pre_wage pre_employed edad mujer"
    if "`ctl'" == "ctl"   local note_ctl "Controls: pre-wage, pre-employment, age, gender."

    di as text _n "--- ITT (`ctl') ---"

    * --- Table 6a: Extensive margin ---
    eststo clear

    eststo itt_emp: reghdfe employed ganador `controls', ///
        absorb(sorteo_fe) cluster(id_anon)
    quietly sum employed if ganador == 0
    estadd scalar cmean = r(mean)

    eststo itt_mono: reghdfe is_monotributo ganador `controls', ///
        absorb(sorteo_fe) cluster(id_anon)
    quietly sum is_monotributo if ganador == 0
    estadd scalar cmean = r(mean)

    eststo itt_any: reghdfe any_work ganador `controls', ///
        absorb(sorteo_fe) cluster(id_anon)
    quietly sum any_work if ganador == 0
    estadd scalar cmean = r(mean)

    esttab itt_* using "$tables/table6a_itt_extensive_`ctl'.tex", replace ///
        keep(ganador) se(%9.4f) b(%9.4f) ///
        star(* 0.10 ** 0.05 *** 0.01) ///
        stats(cmean N r2, labels("Control mean" "Observations" "R-squared") ///
              fmt(%9.3f %9.0fc %9.3f)) ///
        mtitles("Formal Emp" "Monotributo" "Any Work") ///
        title("ITT — Extensive Margin") ///
        note("`note_ctl' SE clustered at person level. Sorteo FE absorbed.") ///
        substitute(`"\begin{tabular}"' `"\label{tab:itt_extensive}\begin{tabular}"' `"\multicolumn{4}{l}{"' `"\multicolumn{4}{p{0.95\textwidth}}{"') ///
        label

    * --- Table 6b: Intensive margin ---
    eststo clear

    eststo itt_wage: reghdfe total_wage ganador `controls', ///
        absorb(sorteo_fe) cluster(id_anon)
    quietly sum total_wage if ganador == 0
    estadd scalar cmean = r(mean)

    eststo itt_logw: reghdfe log_wage ganador `controls' ///
        if employed == 1, absorb(sorteo_fe) cluster(id_anon)
    quietly sum log_wage if ganador == 0 & employed == 1
    estadd scalar cmean = r(mean)

    esttab itt_* using "$tables/table6b_itt_intensive_`ctl'.tex", replace ///
        keep(ganador) se(%9.4f) b(%9.4f) ///
        star(* 0.10 ** 0.05 *** 0.01) ///
        stats(cmean N r2, labels("Control mean" "Observations" "R-squared") ///
              fmt(%9.3f %9.0fc %9.3f)) ///
        mtitles("Wage (levels)" "Log Wage|Emp") ///
        title("ITT — Intensive Margin") ///
        note("`note_ctl' Wages: real, SAC-adjusted. SE clustered at person level. Sorteo FE absorbed.") ///
        label
}


/*==============================================================================
  STEP 6: IV / 2SLS

  receptor instrumented by ganador via ivreghdfe.
  SE clustered at person level.
  Each table produced twice: without and with pre-treatment controls.

  Table 7a — Extensive margin: employed, monotributo, any_work
  Table 7b — Intensive margin: wage (levels), log wage|employed
==============================================================================*/

di as text _n "=== STEP 6: IV / 2SLS ===" _n

use "$temp/cross_section_v2.dta", clear

foreach ctl in "noctl" "ctl" {
    if "`ctl'" == "noctl" local controls ""
    if "`ctl'" == "noctl" local note_ctl "No pre-treatment controls."
    if "`ctl'" == "ctl"   local controls "pre_wage pre_employed edad mujer"
    if "`ctl'" == "ctl"   local note_ctl "Controls: pre-wage, pre-employment, age, gender."

    di as text _n "--- IV (`ctl') ---"

    * --- Table 7a: Extensive margin ---
    eststo clear

    eststo iv_emp: ivreghdfe employed `controls' ///
        (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
    quietly sum employed if ganador == 0
    estadd scalar cmean = r(mean)
    estadd scalar fs_F = e(widstat)

    eststo iv_mono: ivreghdfe is_monotributo `controls' ///
        (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
    quietly sum is_monotributo if ganador == 0
    estadd scalar cmean = r(mean)
    estadd scalar fs_F = e(widstat)

    eststo iv_any: ivreghdfe any_work `controls' ///
        (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
    quietly sum any_work if ganador == 0
    estadd scalar cmean = r(mean)
    estadd scalar fs_F = e(widstat)

    esttab iv_* using "$tables/table7a_iv_extensive_`ctl'.tex", replace ///
        keep(receptor) se(%9.4f) b(%9.4f) ///
        star(* 0.10 ** 0.05 *** 0.01) ///
        stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
              fmt(%9.3f %9.1f %9.0fc)) ///
        mtitles("Formal Emp" "Monotributo" "Any Work") ///
        title("IV — Extensive Margin") ///
        note("2SLS. Instrument: ganador. `note_ctl' SE clustered at person level. Sorteo FE absorbed.") ///
        substitute(`"\begin{tabular}"' `"\label{tab:iv_extensive}\begin{tabular}"' `"\multicolumn{4}{l}{"' `"\multicolumn{4}{p{0.95\textwidth}}{"') ///
        label

    * --- Table 7b: Intensive margin ---
    eststo clear

    eststo iv_wage: ivreghdfe total_wage `controls' ///
        (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
    quietly sum total_wage if ganador == 0
    estadd scalar cmean = r(mean)
    estadd scalar fs_F = e(widstat)

    eststo iv_logw: ivreghdfe log_wage `controls' ///
        (receptor = ganador) if employed == 1, absorb(sorteo_fe) cluster(id_anon)
    quietly sum log_wage if ganador == 0 & employed == 1
    estadd scalar cmean = r(mean)
    estadd scalar fs_F = e(widstat)

    esttab iv_* using "$tables/table7b_iv_intensive_`ctl'.tex", replace ///
        keep(receptor) se(%9.4f) b(%9.4f) ///
        star(* 0.10 ** 0.05 *** 0.01) ///
        stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
              fmt(%9.3f %9.1f %9.0fc)) ///
        mtitles("Wage (levels)" "Log Wage|Emp") ///
        title("IV — Intensive Margin") ///
        note("2SLS. Instrument: ganador. `note_ctl' Wages: real, SAC-adjusted. SE clustered at person level. Sorteo FE absorbed.") ///
        substitute(`"\begin{tabular}"' `"\label{tab:iv_intensive}\begin{tabular}"' `"\multicolumn{3}{l}{"' `"\multicolumn{3}{p{0.75\textwidth}}{"') ///
        label
}


/*==============================================================================
  STEP 7: HETEROGENEITY BY LOTTERY COHORT

  Tables 8, 9, 10: ITT and IV on employment and wages by cohort year.
  SE clustered at person level.
  Each table produced twice: without and with pre-treatment controls.
==============================================================================*/

di as text _n "=== STEP 7: Heterogeneity by Cohort ===" _n

use "$temp/cross_section_v2.dta", clear

foreach ctl in "noctl" "ctl" {
    if "`ctl'" == "noctl" local controls ""
    if "`ctl'" == "noctl" local note_ctl "No pre-treatment controls."
    if "`ctl'" == "ctl"   local controls "pre_wage pre_employed edad mujer"
    if "`ctl'" == "ctl"   local note_ctl "Controls: pre-wage, pre-employment, age, gender."

    * --- Table 8: ITT Employment by cohort ---
    eststo clear

    forvalues y = 2020/2023 {
        eststo het_`y': reghdfe employed ganador `controls' ///
            if cohort_year == `y', absorb(sorteo_fe) cluster(id_anon)
        quietly sum employed if ganador == 0 & cohort_year == `y'
        estadd scalar cmean = r(mean)
    }

    esttab het_* using "$tables/table8_het_employed_`ctl'.tex", replace ///
        keep(ganador) se(%9.4f) b(%9.4f) ///
        star(* 0.10 ** 0.05 *** 0.01) ///
        stats(cmean N r2, labels("Control mean" "Observations" "R-squared") ///
              fmt(%9.3f %9.0fc %9.3f)) ///
        mtitles("2020" "2021" "2022" "2023") ///
        title("ITT Heterogeneity by Cohort (Formal Employment)") ///
        note("`note_ctl' SE clustered at person level. Sorteo FE absorbed.") ///
        label

    * --- Table 9: IV Employment by cohort ---
    eststo clear

    forvalues y = 2020/2023 {
        eststo iv_het_`y': ivreghdfe employed `controls' ///
            (receptor = ganador) if cohort_year == `y', absorb(sorteo_fe) cluster(id_anon)
        quietly sum employed if ganador == 0 & cohort_year == `y'
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)
    }

    esttab iv_het_* using "$tables/table9_het_iv_employed_`ctl'.tex", replace ///
        keep(receptor) se(%9.4f) b(%9.4f) ///
        star(* 0.10 ** 0.05 *** 0.01) ///
        stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
              fmt(%9.3f %9.1f %9.0fc)) ///
        mtitles("2020" "2021" "2022" "2023") ///
        title("IV Heterogeneity by Cohort (Formal Employment)") ///
        note("2SLS. Instrument: ganador. `note_ctl' SE clustered at person level. Sorteo FE absorbed.") ///
        label

    * --- Table 10: IV Wage by cohort ---
    eststo clear

    forvalues y = 2020/2023 {
        eststo iv_w_`y': ivreghdfe total_wage `controls' ///
            (receptor = ganador) if cohort_year == `y', absorb(sorteo_fe) cluster(id_anon)
        quietly sum total_wage if ganador == 0 & cohort_year == `y'
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)
    }

    esttab iv_w_* using "$tables/table10_het_iv_wage_`ctl'.tex", replace ///
        keep(receptor) se(%9.4f) b(%9.4f) ///
        star(* 0.10 ** 0.05 *** 0.01) ///
        stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
              fmt(%12.0f %9.1f %9.0fc)) ///
        mtitles("2020" "2021" "2022" "2023") ///
        title("IV Heterogeneity by Cohort (Wage)") ///
        note("2SLS. Instrument: ganador. `note_ctl' Wages: real, SAC-adjusted. SE clustered at person level. Sorteo FE absorbed.") ///
        label
}


/*==============================================================================
  STEP 8: FULL ESTIMATION BY CREDIT TYPE GROUP

  For each tipo_grupo (DU, Construcción, Lotes, Refacción), produce the
  same 4 core tables as Steps 5-6, each without and with controls.

  Output: tables/type_{grp}_{table}_{noctl|ctl}.tex

  Groups: 1=DU, 2=Construccion, 3=Lotes (Refaccion excluded)
  SE clustered at person level.
==============================================================================*/

di as text _n "=== STEP 8: Full Estimation by Credit Type Group ===" _n

use "$temp/cross_section_v2.dta", clear

local grp_names `" "DU" "Construccion" "Lotes" "'

forvalues g = 1/3 {
    local grp : word `g' of `grp_names'
    local grp_lower = lower("`grp'")

    di as text _n "============================================"
    di as text "  Credit type group: `grp' (tipo_grupo == `g')"
    di as text "============================================" _n

    foreach ctl in "noctl" "ctl" {
        if "`ctl'" == "noctl" local controls ""
        if "`ctl'" == "noctl" local note_ctl "No pre-treatment controls."
        if "`ctl'" == "ctl"   local controls "pre_wage pre_employed edad mujer"
        if "`ctl'" == "ctl"   local note_ctl "Controls: pre-wage, pre-employment, age, gender."

        * ---- ITT Extensive ----
        eststo clear

        eststo itt_emp: reghdfe employed ganador `controls' ///
            if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
        quietly sum employed if ganador == 0 & tipo_grupo == `g'
        estadd scalar cmean = r(mean)

        eststo itt_mono: reghdfe is_monotributo ganador `controls' ///
            if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
        quietly sum is_monotributo if ganador == 0 & tipo_grupo == `g'
        estadd scalar cmean = r(mean)

        eststo itt_any: reghdfe any_work ganador `controls' ///
            if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
        quietly sum any_work if ganador == 0 & tipo_grupo == `g'
        estadd scalar cmean = r(mean)

        esttab itt_* using "$tables/type_`grp_lower'_itt_ext_`ctl'.tex", replace ///
            keep(ganador) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean N r2, labels("Control mean" "Observations" "R-squared") ///
                  fmt(%9.3f %9.0fc %9.3f)) ///
            mtitles("Formal Emp" "Monotributo" "Any Work") ///
            title("ITT — Extensive Margin (`grp')") ///
            note("`note_ctl' SE clustered at person level. Sorteo FE absorbed.") ///
            label

        * ---- ITT Intensive ----
        eststo clear

        eststo itt_wage: reghdfe total_wage ganador `controls' ///
            if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
        quietly sum total_wage if ganador == 0 & tipo_grupo == `g'
        estadd scalar cmean = r(mean)

        eststo itt_logw: reghdfe log_wage ganador `controls' ///
            if tipo_grupo == `g' & employed == 1, absorb(sorteo_fe) cluster(id_anon)
        quietly sum log_wage if ganador == 0 & tipo_grupo == `g' & employed == 1
        estadd scalar cmean = r(mean)

        esttab itt_* using "$tables/type_`grp_lower'_itt_int_`ctl'.tex", replace ///
            keep(ganador) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean N r2, labels("Control mean" "Observations" "R-squared") ///
                  fmt(%9.3f %9.0fc %9.3f)) ///
            mtitles("Wage (levels)" "Log Wage|Emp") ///
            title("ITT — Intensive Margin (`grp')") ///
            note("`note_ctl' Wages: real, SAC-adjusted. SE clustered at person level. Sorteo FE absorbed.") ///
            label

        * ---- IV Extensive ----
        eststo clear

        eststo iv_emp: ivreghdfe employed `controls' ///
            (receptor = ganador) if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
        quietly sum employed if ganador == 0 & tipo_grupo == `g'
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)

        eststo iv_mono: ivreghdfe is_monotributo `controls' ///
            (receptor = ganador) if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
        quietly sum is_monotributo if ganador == 0 & tipo_grupo == `g'
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)

        eststo iv_any: ivreghdfe any_work `controls' ///
            (receptor = ganador) if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
        quietly sum any_work if ganador == 0 & tipo_grupo == `g'
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)

        esttab iv_* using "$tables/type_`grp_lower'_iv_ext_`ctl'.tex", replace ///
            keep(receptor) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
                  fmt(%9.3f %9.1f %9.0fc)) ///
            mtitles("Formal Emp" "Monotributo" "Any Work") ///
            title("IV — Extensive Margin (`grp')") ///
            note("2SLS. Instrument: ganador. `note_ctl' SE clustered at person level. Sorteo FE absorbed.") ///
            label

        * ---- IV Intensive ----
        eststo clear

        eststo iv_wage: ivreghdfe total_wage `controls' ///
            (receptor = ganador) if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
        quietly sum total_wage if ganador == 0 & tipo_grupo == `g'
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)

        eststo iv_logw: ivreghdfe log_wage `controls' ///
            (receptor = ganador) if tipo_grupo == `g' & employed == 1, ///
            absorb(sorteo_fe) cluster(id_anon)
        quietly sum log_wage if ganador == 0 & tipo_grupo == `g' & employed == 1
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)

        esttab iv_* using "$tables/type_`grp_lower'_iv_int_`ctl'.tex", replace ///
            keep(receptor) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
                  fmt(%9.3f %9.1f %9.0fc)) ///
            mtitles("Wage (levels)" "Log Wage|Emp") ///
            title("IV — Intensive Margin (`grp')") ///
            note("2SLS. Instrument: ganador. `note_ctl' Wages: real, SAC-adjusted. SE clustered at person level. Sorteo FE absorbed.") ///
            label
    }

    di as text _n "  `grp' complete — 8 tables saved (4 noctl + 4 ctl)."
}


/*==============================================================================
  STEP 9: HETEROGENEITY BY COHORT YEAR × CREDIT TYPE

  For each tipo_grupo, produce ITT and IV tables on formal employment
  with columns = cohort years (2020–2023). Each with and without controls.

  Output: tables/type_{grp}_het_itt_year_{noctl|ctl}.tex
          tables/type_{grp}_het_iv_year_{noctl|ctl}.tex

  Groups: 1=DU, 2=Construccion, 3=Lotes (Refaccion excluded)
  SE clustered at person level.
==============================================================================*/

di as text _n "=== STEP 9: Heterogeneity by Cohort Year × Credit Type ===" _n

use "$temp/cross_section_v2.dta", clear

local grp_names `" "DU" "Construccion" "Lotes" "'

forvalues g = 1/3 {
    local grp : word `g' of `grp_names'
    local grp_lower = lower("`grp'")

    di as text _n "============================================"
    di as text "  Credit type: `grp' — by cohort year"
    di as text "============================================" _n

    foreach ctl in "noctl" "ctl" {
        if "`ctl'" == "noctl" local controls ""
        if "`ctl'" == "noctl" local note_ctl "No pre-treatment controls."
        if "`ctl'" == "ctl"   local controls "pre_wage pre_employed edad mujer"
        if "`ctl'" == "ctl"   local note_ctl "Controls: pre-wage, pre-employment, age, gender."

        * ---- ITT Employment by year ----
        eststo clear

        forvalues y = 2020/2023 {
            capture eststo itt_`y': reghdfe employed ganador `controls' ///
                if tipo_grupo == `g' & cohort_year == `y', absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                quietly sum employed if ganador == 0 & tipo_grupo == `g' & cohort_year == `y'
                estadd scalar cmean = r(mean)
            }
        }

        esttab itt_* using "$tables/type_`grp_lower'_het_itt_year_`ctl'.tex", replace ///
            keep(ganador) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean N r2, labels("Control mean" "Observations" "R-squared") ///
                  fmt(%9.3f %9.0fc %9.3f)) ///
            mtitles("2020" "2021" "2022" "2023") ///
            title("ITT by Cohort Year — Formal Employment (`grp')") ///
            note("`note_ctl' SE clustered at person level. Sorteo FE absorbed.") ///
            label

        * ---- IV Employment by year ----
        eststo clear

        forvalues y = 2020/2023 {
            capture eststo iv_`y': ivreghdfe employed `controls' ///
                (receptor = ganador) if tipo_grupo == `g' & cohort_year == `y', ///
                absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                quietly sum employed if ganador == 0 & tipo_grupo == `g' & cohort_year == `y'
                estadd scalar cmean = r(mean)
                estadd scalar fs_F = e(widstat)
            }
        }

        esttab iv_* using "$tables/type_`grp_lower'_het_iv_year_`ctl'.tex", replace ///
            keep(receptor) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
                  fmt(%9.3f %9.1f %9.0fc)) ///
            mtitles("2020" "2021" "2022" "2023") ///
            title("IV by Cohort Year — Formal Employment (`grp')") ///
            note("2SLS. Instrument: ganador. `note_ctl' SE clustered at person level. Sorteo FE absorbed.") ///
            label

        * ---- ITT Wage by year ----
        eststo clear

        forvalues y = 2020/2023 {
            capture eststo itt_w_`y': reghdfe total_wage ganador `controls' ///
                if tipo_grupo == `g' & cohort_year == `y', absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                quietly sum total_wage if ganador == 0 & tipo_grupo == `g' & cohort_year == `y'
                estadd scalar cmean = r(mean)
            }
        }

        esttab itt_w_* using "$tables/type_`grp_lower'_het_itt_wage_year_`ctl'.tex", replace ///
            keep(ganador) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean N r2, labels("Control mean" "Observations" "R-squared") ///
                  fmt(%12.0f %9.0fc %9.3f)) ///
            mtitles("2020" "2021" "2022" "2023") ///
            title("ITT by Cohort Year — Wage (`grp')") ///
            note("`note_ctl' Wages: real, SAC-adjusted. SE clustered at person level. Sorteo FE absorbed.") ///
            label

        * ---- IV Wage by year ----
        eststo clear

        forvalues y = 2020/2023 {
            capture eststo iv_w_`y': ivreghdfe total_wage `controls' ///
                (receptor = ganador) if tipo_grupo == `g' & cohort_year == `y', ///
                absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                quietly sum total_wage if ganador == 0 & tipo_grupo == `g' & cohort_year == `y'
                estadd scalar cmean = r(mean)
                estadd scalar fs_F = e(widstat)
            }
        }

        esttab iv_w_* using "$tables/type_`grp_lower'_het_iv_wage_year_`ctl'.tex", replace ///
            keep(receptor) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
                  fmt(%12.0f %9.1f %9.0fc)) ///
            mtitles("2020" "2021" "2022" "2023") ///
            title("IV by Cohort Year — Wage (`grp')") ///
            note("2SLS. Instrument: ganador. `note_ctl' Wages: real, SAC-adjusted. SE clustered at person level. Sorteo FE absorbed.") ///
            label
    }

    di as text _n "  `grp' by-year complete — 8 tables saved (4 × noctl/ctl)."
}


/*==============================================================================
  SUMMARY
==============================================================================*/

di as text _n(3) "========================================"
di as text       "  PROCREAR Labor Market v2 — Complete"
di as text       "========================================"
di as text _n "Unit of observation: person × sorteo inscription"
di as text "SE clustered at person level throughout"
di as text "sorteo_fe = group(fecha_sorteo, tipo, desarrollourbanistico, tipologia, cupo)"
di as text "Each table produced in _noctl and _ctl variants."
di as text _n "Tables saved to: $tables/"
di as text "  --- Pooled (×2: noctl, ctl) ---"
di as text "  table6a_itt_extensive_*.tex  — ITT: employed, monotributo, any work"
di as text "  table6b_itt_intensive_*.tex  — ITT: wage (levels), log wage|emp"
di as text "  table7a_iv_extensive_*.tex   — IV:  employed, monotributo, any work"
di as text "  table7b_iv_intensive_*.tex   — IV:  wage (levels), log wage|emp"
di as text "  --- By cohort (×2: noctl, ctl) ---"
di as text "  table8_het_employed_*.tex    — ITT by cohort: formal employment"
di as text "  table9_het_iv_employed_*.tex — IV by cohort: formal employment"
di as text "  table10_het_iv_wage_*.tex    — IV by cohort: wage (levels)"
di as text "  --- By credit type group (8 tables each: 4 × noctl/ctl) ---"
di as text "  type_du_*_*.tex              — Desarrollos Urbanísticos"
di as text "  type_construccion_*_*.tex    — Construcción (CCP + CO + CP)"
di as text "  type_lotes_*_*.tex           — Lotes (LS)"
di as text "  (Refacción excluded from analysis)"
di as text "  --- By credit type × cohort year (8 tables each: 4 × noctl/ctl) ---"
di as text "  type_*_het_itt_year_*.tex       — ITT employment by year"
di as text "  type_*_het_iv_year_*.tex        — IV employment by year"
di as text "  type_*_het_itt_wage_year_*.tex  — ITT wage by year"
di as text "  type_*_het_iv_wage_year_*.tex   — IV wage by year"
