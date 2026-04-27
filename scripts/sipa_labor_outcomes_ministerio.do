/*==============================================================================
  PROCREAR — Paper Tables: Labor Market Outcomes (SIPA — MINISTERIO variant)

  Variante de sipa_labor_outcomes.do que corre sobre la base del Ministerio
  (estructura distinta al Data_SIPA.dta original).

  Diferencias principales del ministerio file vs Data_SIPA.dta:
    - Path / filename del archivo SIPA (ver `sipa_file` abajo).
    - Columna de fecha llamada `mes` en formato YYYYMM como double
      (ya soportada por el código existente — `floor` y `mod` aceptan double).
    - Si difieren los nombres de remuneracion/sac/mujer, ajustar los locals.

  Outputs del Ministerio variant van a `$output/tables_ministerio/` para no
  pisar las tablas oficiales del paper.

  Do NOT run procrear_rq2.do after this — it overwrites table_extensive.tex
  and table_intensive.tex with a different (incorrect) specification.

  Specification:
    - Unit of observation: person × sorteo inscription
    - Sorteo FE: group(fecha_sorteo, tipo, desarrollourbanistico, tipologia, cupo)
    - Treatment: ganador (ITT) / receptor instrumented by ganador (IV)
    - SE clustered at the person level (id_anon)
    - Three control specifications per outcome:
        (1) No controls
        (2) Age only: edad
        (3) Full controls: edad, pre-employment, pre-wage

  ===========================================================================
  OUTPUT → PAPER MAPPING
  ===========================================================================

  Table file                        Paper location
  ─────────────────────────────────  ──────────────────────────────────────
  table_extensive.tex                Section 5.1 (Table: Extensive Margin)
  table_intensive.tex                Section 5.2 (Table: Intensive Margin)
  table_het_compact.tex              Section 5.2/5.3 (compact heterogeneity)
  table_het_type_year.tex            Appendix A (type × cohort year)

  ===========================================================================
  OUTLINE
  ===========================================================================

  STEP 1: Build monthly price deflator
  STEP 2: Build sorteo-level analysis sample (person × sorteo)
  STEP 3: Build SIPA person-month panel
  STEP 4: Merge → cross-section with pre-treatment outcomes
  STEP 5: Main tables — Extensive + Intensive margins (9 + 6 cols)
  STEP 6: Compact heterogeneity (IV, full controls): cohort × type × 4 outcomes
  STEP 7: Appendix — Credit type × cohort year (IV, full controls)

==============================================================================*/

clear all
set more off
set matsize 10000

* =============================================================================
* USER CONFIG (MINISTERIO) — ajustar paths y nombres de variables al armar
* =============================================================================

* Folder containing the input datasets
global data "/Users/francomartinvazquez/Dropbox (Personal)/Procrear Santanna/DATA"

* Output folder for tables (separate from official paper tables to avoid clobber)
global output "/Users/francomartinvazquez/Dropbox (Personal)/Procrear Santanna/Procrear"

* Folder for intermediate/temporary .dta files
global temp "/Users/francomartinvazquez/Dropbox (Personal)/Procrear Santanna/TEMP"

* --- Input files (MINISTERIO) ---
* Path al archivo SIPA del Ministerio. Ajustá si está en otra ubicación.
global sipa_file    "$data/Data_SIPA_ministerio.dta"

* Path al archivo de sorteos. Mismo que el original a menos que también cambie.
global sorteos_file "$data/Data_sorteos.dta"

* --- Variable name mappings (MINISTERIO) ---
* Nombre de la columna de remuneracion mensual nominal.
local wage_var "remuneracion"

* Nombre de la columna de fecha en formato YYYYMM (e.g. 202412).
* En la base del ministerio es "mes" como double — soportado tal cual.
local fecha_var "mes"

* Nombre de la columna de indicador femenino (0/1).
local mujer_var "mujer"

* Nombre de la columna del aguinaldo (SAC) — usada para deseasonalizar.
* Si la base del ministerio NO tiene `sac`, dejar vacio: el script no descontara.
local sac_var "sac"

* --- Derived paths (do not edit) ---------------------------------------------
* Tables en subcarpeta separada para no pisar las oficiales del paper.
global tables "$output/tables_ministerio"

cap mkdir "$output"
cap mkdir "$tables"
cap mkdir "$temp"

* --- REQUIRED PACKAGES -------------------------------------------------------
* ssc install estout, replace
* ssc install reghdfe, replace
* ssc install ftools, replace
* ssc install ivreghdfe, replace


/*==============================================================================
  STEP 1: BUILD MONTHLY PRICE DEFLATOR
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

  Unit: person × sorteo inscription (NOT collapsed to person).
  Each row belongs to a specific randomization pool (sorteo_fe).
==============================================================================*/

di as text _n "=== STEP 2: Building sorteo-level sample ===" _n

use "$sorteos_file", clear

di as text "Raw sorteos: N = " _N

* --- CUIL prefix → birth date mapping (for age imputation) -------------------
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

* --- Fill missings for FE grouping --------------------------------------------
replace desarrollourbanistico = 0 if desarrollourbanistico == .
replace tipologia = 0 if tipologia == .
replace cupo = 0 if cupo == .

* --- Sorteo FE = fecha_sorteo × tipo × desarrollo × tipologia × cupo ---------
*     This is the actual randomization pool.
egen sorteo_fe = group(fecha_sorteo tipo desarrollourbanistico tipologia cupo)

* --- Credit type groups -------------------------------------------------------
gen tipo_grupo = .
replace tipo_grupo = 1 if tipo == 5                              // DU
replace tipo_grupo = 2 if inlist(tipo, 2, 3, 4)                  // Construcción
replace tipo_grupo = 3 if inlist(tipo, 6)                        // Lotes
replace tipo_grupo = 4 if inlist(tipo, 1, 8, 9, 10, 11, 12, 13) // Refacción
label define tipo_grupo_lbl 1 "DU" 2 "Construccion" 3 "Lotes" 4 "Refaccion"
label values tipo_grupo tipo_grupo_lbl

* --- DROP REFACCION (tipo_grupo == 4) -----------------------------------------
di as text _n "Dropping Refaccion (tipo_grupo == 4)..."
count if tipo_grupo == 4
drop if tipo_grupo == 4

di as text _n "Credit type distribution:"
tab tipo_grupo

* --- DROP DEGENERATE SORTEOS (winrate == 0 or winrate == 1) -------------------
bys sorteo_fe: egen _winrate = mean(ganador)
di as text _n "Dropping degenerate sorteos:"
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

* Primary: individual's own fnacimiento
gen edad = sorteo_year - year(fnacimiento) if fnacimiento != .
replace edad = edad - 1 if sorteo_month_num < month(fnacimiento) & edad != .

* Fallback 1: original edad column from Data_sorteos
replace edad = edad_original if edad == . & edad_original != .

* Fallback 2: CUIL prefix → median birth date mapping (approximation)
replace edad = sorteo_year - med_birth_year if edad == . & med_birth_year != .
replace edad = edad - 1 if sorteo_month_num < med_birth_month & edad != . & fnacimiento == . & edad_original == .

drop edad_original dni_prefix_str dni_prefix med_fnac med_birth_date ///
     med_birth_year med_birth_month sorteo_year sorteo_month_num fnacimiento

di as text "Age (edad) non-missing: "
count if edad != .
di as text "  " r(N) " of " _N " (" %4.1f 100*r(N)/_N "%)"

* --- Monotributo indicator ----------------------------------------------------
replace monotributo = . if monotributo == 24
replace monotributo = . if monotributo == 1

gen byte is_monotributo = (monotributo > 0 & monotributo !=.)

save "$temp/sorteo_sample_v2.dta", replace


/*==============================================================================
  STEP 3: BUILD SIPA PERSON-MONTH PANEL
==============================================================================*/


use "$sipa_file", clear

* Filter to persons in our sample
preserve
use "$temp/sorteo_sample_v2.dta", clear
keep id_anon
duplicates drop
save "$temp/_person_list.dta", replace
restore

merge m:1 id_anon using "$temp/_person_list.dta", keep(match) nogenerate

* Create monthly date
gen int _y = floor(`fecha_var' / 100)
gen int _m = mod(`fecha_var', 100)
gen periodo_month = ym(_y, _m)
format periodo_month %tm
drop _y _m

* Deseasonalize aguinaldo. Si `sac_var' existe en la base, restamos directo:
*    wage_desest = remuneracion - sac
* Si NO existe (sac_var vacio o columna ausente), fallback al heuristico de
* dividir por 1.5 en jun/dic.
gen double wage_desest = `wage_var'
local _use_sac = 0
if "`sac_var'" != "" {
    capture confirm variable `sac_var'
    if !_rc {
        local _use_sac = 1
    }
}
if `_use_sac' == 1 {
    di as text "  Aguinaldo: usando wage_desest = `wage_var' - `sac_var'"
    replace wage_desest = `wage_var' - `sac_var' if !missing(`sac_var')
    replace wage_desest = 0 if wage_desest < 0 & !missing(wage_desest)
}
else {
    di as text "  Aguinaldo: fallback heuristico jun/dic / 1.5 (sin columna `sac_var')"
    gen int cal_month = month(dofm(periodo_month))
    replace wage_desest = `wage_var' / 1.5 if inlist(cal_month, 6, 12)
    drop cal_month
}

* Deflate to constant prices
merge m:1 periodo_month using "$temp/deflator.dta", keep(master match) nogenerate
gen double real_wage = wage_desest / deflator
replace real_wage = 0 if wage_desest == .

* Collapse to person × month
di as text _n "Collapsing to person-month..."
collapse (sum) total_wage=real_wage ///
         (firstnm) mujer=`mujer_var', ///
         by(id_anon periodo_month)

gen byte employed = 1

save "$temp/sipa_panel.dta", replace
erase "$temp/_person_list.dta"


/*==============================================================================
  STEP 4: MERGE AND BUILD CROSS-SECTION (sorteo-level)

  Person-level labor outcomes (last SIPA period) merged onto each sorteo row.
  Pre-treatment outcomes (at sorteo month) added as controls.
==============================================================================*/

* --- 4a. Build person-level labor outcomes ------------------------------------
use "$temp/sorteo_sample_v2.dta", clear
keep id_anon is_monotributo
duplicates drop

merge 1:m id_anon using "$temp/sipa_panel.dta"

replace employed    = 0 if _merge == 1
replace total_wage  = 0 if _merge == 1

drop if _merge == 2
drop _merge

* Keep last available SIPA period per person
bys id_anon (periodo_month): keep if _n == _N

* Redefine employed: currently working (recent SIPA record)
*replace employed = 1 if periodo_month >= ym(2025, 10)
replace employed = (periodo_month == ym(2025, 11))
replace employed = 0 if total_wage == 0
replace total_wage = 0 if employed == 0


* Create additional outcomes
gen double log_wage = ln(total_wage) if employed == 1 & total_wage > 0
gen byte any_work = (employed == 1 | is_monotributo == 1)

keep id_anon employed total_wage log_wage any_work periodo_month mujer

save "$temp/_person_outcomes.dta", replace

* --- 4b. Merge person outcomes onto sorteo-level sample -----------------------
use "$temp/sorteo_sample_v2.dta", clear
keep id_anon ganador receptor sorteo_fe tipo tipo_grupo sorteo_month ///
     cohort_year fecha_sorteo is_monotributo edad genero

merge m:1 id_anon using "$temp/_person_outcomes.dta", keep(master match) nogenerate

replace mujer = (genero == 1) if mujer == . & genero != .
drop genero

save "$temp/cross_section_v2.dta", replace

erase "$temp/_person_outcomes.dta"

* --- 4c. Add pre-treatment outcomes (at sorteo month) -------------------------
preserve
use "$temp/sipa_panel.dta", clear
rename total_wage pre_wage
rename employed pre_employed
replace pre_employed=0 if pre_wage==0
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
sum pre_employed pre_wage

save "$temp/cross_section_v2.dta", replace
erase "$temp/_pretreat_sipa.dta"


/*==============================================================================
  STEP 5: MAIN TABLES — EXTENSIVE + INTENSIVE MARGINS

  Paper Section 5.1: table_extensive.tex  (9 cols: 3 outcomes × 3 specs)
  Paper Section 5.2: table_intensive.tex  (6 cols: 2 outcomes × 3 specs)
==============================================================================*/

di as text _n "=== STEP 5: Main tables (paper Tables: Extensive + Intensive) ===" _n

use "$temp/cross_section_v2.dta", clear

* ======================================================================
* TABLE: EXTENSIVE MARGIN — paper Section 5.1
* 9 columns: Formal Emp (3 specs) | Monotributo (3 specs) | Any Work (3 specs)
* Panel A: ITT, Panel B: IV/2SLS
* ======================================================================

* --- Panel A: ITT ---
eststo clear

foreach spec in "noctl" "imbctl" "ctl" {
    if "`spec'" == "noctl" {
        local controls ""
        local mark_imb ""
        local mark_full ""
    }
    if "`spec'" == "imbctl" {
        local controls "edad"
        local mark_imb "\checkmark"
        local mark_full ""
    }
    if "`spec'" == "ctl" {
        local controls "edad pre_employed pre_wage"
        local mark_imb "\checkmark"
        local mark_full "\checkmark"
    }

    eststo itt_emp_`spec': reghdfe employed ganador `controls', ///
        absorb(sorteo_fe) cluster(id_anon)
    quietly sum employed if ganador == 0
    estadd scalar cmean = r(mean)
    estadd local ctl_imb "`mark_imb'"
    estadd local ctl_full "`mark_full'"

    eststo itt_mono_`spec': reghdfe is_monotributo ganador `controls', ///
        absorb(sorteo_fe) cluster(id_anon)
    quietly sum is_monotributo if ganador == 0
    estadd scalar cmean = r(mean)
    estadd local ctl_imb "`mark_imb'"
    estadd local ctl_full "`mark_full'"

    eststo itt_any_`spec': reghdfe any_work ganador `controls', ///
        absorb(sorteo_fe) cluster(id_anon)
    quietly sum any_work if ganador == 0
    estadd scalar cmean = r(mean)
    estadd local ctl_imb "`mark_imb'"
    estadd local ctl_full "`mark_full'"
}

esttab itt_emp_noctl itt_emp_imbctl itt_emp_ctl ///
       itt_mono_noctl itt_mono_imbctl itt_mono_ctl ///
       itt_any_noctl itt_any_imbctl itt_any_ctl ///
       using "$tables/table_extensive.tex", replace ///
    keep(ganador) se(%9.4f) b(%9.4f) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    nonumbers nomtitles noobs nor2 ///
    coeflabels(ganador "Ganador") ///
    prehead(`"\begin{table}[htbp]\centering"' ///
            `"\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}"' ///
            `"\caption{Extensive Margin: Employment Effects of PROCREAR Credit}"' ///
            `"\label{tab:extensive}"' ///
            `"\scriptsize"' ///
            `"\setlength{\tabcolsep}{2pt}"' ///
            `"\begin{tabular}{@{}l*{9}{c}@{}}"' ///
            `"\hline\hline"' ///
            `" & \multicolumn{3}{c}{Formal Emp} & \multicolumn{3}{c}{Monotributo} & \multicolumn{3}{c}{Any Work} \\"' ///
            `"\cline{2-4}\cline{5-7}\cline{8-10}"' ///
            `" & (1) & (2) & (3) & (4) & (5) & (6) & (7) & (8) & (9) \\"' ///
            `"\hline"' ///
            `"\multicolumn{10}{l}{\textit{Panel A: ITT}} \\"') ///
    postfoot(`"[1em]"') ///
    substitute(\_ _) fragment

* --- Panel B: IV ---
eststo clear

foreach spec in "noctl" "imbctl" "ctl" {
    if "`spec'" == "noctl" {
        local controls ""
        local mark_imb ""
        local mark_full ""
    }
    if "`spec'" == "imbctl" {
        local controls "edad"
        local mark_imb "\checkmark"
        local mark_full ""
    }
    if "`spec'" == "ctl" {
        local controls "edad pre_employed pre_wage"
        local mark_imb "\checkmark"
        local mark_full "\checkmark"
    }

    eststo iv_emp_`spec': ivreghdfe employed `controls' ///
        (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
    quietly sum employed if ganador == 0
    estadd scalar cmean = r(mean)
    estadd scalar fs_F = e(widstat)
    estadd local ctl_imb "`mark_imb'"
    estadd local ctl_full "`mark_full'"

    eststo iv_mono_`spec': ivreghdfe is_monotributo `controls' ///
        (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
    quietly sum is_monotributo if ganador == 0
    estadd scalar cmean = r(mean)
    estadd scalar fs_F = e(widstat)
    estadd local ctl_imb "`mark_imb'"
    estadd local ctl_full "`mark_full'"

    eststo iv_any_`spec': ivreghdfe any_work `controls' ///
        (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
    quietly sum any_work if ganador == 0
    estadd scalar cmean = r(mean)
    estadd scalar fs_F = e(widstat)
    estadd local ctl_imb "`mark_imb'"
    estadd local ctl_full "`mark_full'"
}

esttab iv_emp_noctl iv_emp_imbctl iv_emp_ctl ///
       iv_mono_noctl iv_mono_imbctl iv_mono_ctl ///
       iv_any_noctl iv_any_imbctl iv_any_ctl ///
       using "$tables/table_extensive.tex", append ///
    keep(receptor) se(%9.4f) b(%9.4f) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    nonumbers nomtitles ///
    coeflabels(receptor "Receptor") ///
    prehead(`"\multicolumn{10}{l}{\textit{Panel B: IV / 2SLS}} \\"') ///
    prefoot(`"\hline"') ///
    stats(cmean fs_F N ctl_imb ctl_full, ///
          labels("Control mean" "First-stage F" "Observations" ///
                 "Age only" "All controls") ///
          fmt(%9.3f %9.1f %9.0fc %s %s)) ///
    postfoot(`"\hline\hline"' ///
             `"\multicolumn{10}{p{0.95\textwidth}}{\scriptsize 2SLS. Instrument: ganador. Cols (1),(4),(7): no controls. (2),(5),(8): age only. (3),(6),(9): all controls (add pre-employed, pre-wage). SE clustered at person level. Sorteo FE absorbed.}\\"' ///
             `"\multicolumn{10}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}"' ///
             `"\end{tabular}"' ///
             `"\end{table}"') ///
    substitute(\_ _) fragment

di as text "  table_extensive.tex saved (paper Section 5.1)"


* ======================================================================
* TABLE: INTENSIVE MARGIN — paper Section 5.2
* 6 columns: Wage levels (3 specs) | Log Wage|Emp (3 specs)
* Panel A: ITT, Panel B: IV/2SLS
* ======================================================================

* --- Panel A: ITT ---
eststo clear

foreach spec in "noctl" "imbctl" "ctl" {
    if "`spec'" == "noctl" {
        local controls ""
        local mark_imb ""
        local mark_full ""
    }
    if "`spec'" == "imbctl" {
        local controls "edad"
        local mark_imb "\checkmark"
        local mark_full ""
    }
    if "`spec'" == "ctl" {
        local controls "edad pre_employed pre_wage"
        local mark_imb "\checkmark"
        local mark_full "\checkmark"
    }

    eststo itt_wage_`spec': reghdfe total_wage ganador `controls', ///
        absorb(sorteo_fe) cluster(id_anon)
    quietly sum total_wage if ganador == 0
    estadd scalar cmean = r(mean)
    estadd local ctl_imb "`mark_imb'"
    estadd local ctl_full "`mark_full'"

    eststo itt_logw_`spec': reghdfe log_wage ganador `controls' ///
        if employed == 1, absorb(sorteo_fe) cluster(id_anon)
    quietly sum log_wage if ganador == 0 & employed == 1
    estadd scalar cmean = r(mean)
    estadd local ctl_imb "`mark_imb'"
    estadd local ctl_full "`mark_full'"
}

esttab itt_wage_noctl itt_wage_imbctl itt_wage_ctl ///
       itt_logw_noctl itt_logw_imbctl itt_logw_ctl ///
       using "$tables/table_intensive.tex", replace ///
    keep(ganador) ///
    b(%9.0fc %9.0fc %9.0fc %9.4f %9.4f %9.4f) ///
    se(%9.0fc %9.0fc %9.0fc %9.4f %9.4f %9.4f) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    nonumbers nomtitles noobs nor2 ///
    coeflabels(ganador "Ganador") ///
    prehead(`"\begin{table}[htbp]\centering"' ///
            `"\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}"' ///
            `"\caption{Intensive Margin: Wage Effects of PROCREAR Credit}"' ///
            `"\label{tab:intensive}"' ///
            `"\scriptsize"' ///
            `"\begin{tabular}{l*{6}{c}}"' ///
            `"\hline\hline"' ///
            `" & \multicolumn{3}{c}{Wage (levels)} & \multicolumn{3}{c}{Log Wage|Emp} \\"' ///
            `"\cline{2-4}\cline{5-7}"' ///
            `" & (1) & (2) & (3) & (4) & (5) & (6) \\"' ///
            `"\hline"' ///
            `"\multicolumn{7}{l}{\textit{Panel A: ITT}} \\"') ///
    postfoot(`"[1em]"') ///
    substitute(\_ _) fragment

* --- Panel B: IV ---
eststo clear

foreach spec in "noctl" "imbctl" "ctl" {
    if "`spec'" == "noctl" {
        local controls ""
        local mark_imb ""
        local mark_full ""
    }
    if "`spec'" == "imbctl" {
        local controls "edad"
        local mark_imb "\checkmark"
        local mark_full ""
    }
    if "`spec'" == "ctl" {
        local controls "edad pre_employed pre_wage"
        local mark_imb "\checkmark"
        local mark_full "\checkmark"
    }

    eststo iv_wage_`spec': ivreghdfe total_wage `controls' ///
        (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
    local _wid = e(widstat)
    quietly sum total_wage if ganador == 0
    local _cmval = r(mean)
    estadd scalar cmean = `_cmval'
    local _cm: display %12.0fc `_cmval'
    estadd local cmean_s = strtrim("`_cm'")
    estadd scalar fs_F = `_wid'
    estadd local ctl_imb "`mark_imb'"
    estadd local ctl_full "`mark_full'"

    eststo iv_logw_`spec': ivreghdfe log_wage `controls' ///
        (receptor = ganador) if employed == 1, absorb(sorteo_fe) cluster(id_anon)
    local _wid = e(widstat)
    quietly sum log_wage if ganador == 0 & employed == 1
    local _cmval = r(mean)
    estadd scalar cmean = `_cmval'
    local _cm: display %9.3f `_cmval'
    estadd local cmean_s = strtrim("`_cm'")
    estadd scalar fs_F = `_wid'
    estadd local ctl_imb "`mark_imb'"
    estadd local ctl_full "`mark_full'"
}

esttab iv_wage_noctl iv_wage_imbctl iv_wage_ctl ///
       iv_logw_noctl iv_logw_imbctl iv_logw_ctl ///
       using "$tables/table_intensive.tex", append ///
    keep(receptor) ///
    b(%9.0fc %9.0fc %9.0fc %9.4f %9.4f %9.4f) ///
    se(%9.0fc %9.0fc %9.0fc %9.4f %9.4f %9.4f) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    nonumbers nomtitles ///
    coeflabels(receptor "Receptor") ///
    prehead(`"\multicolumn{7}{l}{\textit{Panel B: IV / 2SLS}} \\"') ///
    prefoot(`"\hline"') ///
    stats(cmean_s fs_F N ctl_imb ctl_full, ///
          labels("Control mean" "First-stage F" "Observations" ///
                 "Age only" "All controls") ///
          fmt(%s %9.0fc %9.0fc %s %s)) ///
    postfoot(`"\hline\hline"' ///
             `"\multicolumn{7}{p{0.95\textwidth}}{\scriptsize 2SLS. Instrument: ganador. Cols (1),(4): no controls. (2),(5): age only. (3),(6): all controls (add pre-employed, pre-wage). Wages: real, SAC-adjusted. Log Wage|Emp on employed subsample. SE clustered at person level. Sorteo FE absorbed.}\\"' ///
             `"\multicolumn{7}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}"' ///
             `"\end{tabular}"' ///
             `"\end{table}"') ///
    substitute(\_ _) fragment

di as text "  table_intensive.tex saved (paper Section 5.2)"


/*==============================================================================
  STEP 6: COMPACT HETEROGENEITY TABLE

  Single table with 4 outcome columns (Formal Emp, Monotributo, Any Work,
  Log Wage|Emp). Panel A: rows by cohort year. Panel B: rows by credit type.
  IV/2SLS with full controls only.
  table_het_compact.tex — Paper Section: Heterogeneity
==============================================================================*/

di as text _n "=== STEP 6: Compact heterogeneity table ===" _n

use "$temp/cross_section_v2.dta", clear

local controls "edad pre_employed pre_wage"

capture file close fh
file open fh using "$tables/table_het_compact.tex", write replace

file write fh "\begin{table}[H]\centering" _n
file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
file write fh "\caption{Heterogeneity: IV Estimates with Full Controls}" _n
file write fh "\label{tab:het_compact}" _n
file write fh "\scriptsize" _n
file write fh "\begin{tabular}{@{}lcccc@{}}" _n
file write fh "\hline\hline" _n
file write fh " & Formal Emp & Monotributo & Any Work & Log Wage\textbar Emp \\" _n
file write fh " & (1) & (2) & (3) & (4) \\" _n
file write fh "\hline" _n

* =========== Panel A: By Cohort Year ===========
file write fh "\multicolumn{5}{l}{\textit{Panel A: By Cohort Year}} \\" _n
file write fh "\hline" _n

forvalues y = 2020/2023 {

    * --- Run 4 IV regressions ---
    * 1. Formal Employment
    ivreghdfe employed `controls' (receptor = ganador) ///
        if cohort_year == `y', absorb(sorteo_fe) cluster(id_anon)
    local b1 = _b[receptor]
    local se1 = _se[receptor]
    local n1 = e(N)
    quietly sum employed if ganador == 0 & cohort_year == `y'
    local cm1 = r(mean)

    * 2. Monotributo
    ivreghdfe is_monotributo `controls' (receptor = ganador) ///
        if cohort_year == `y', absorb(sorteo_fe) cluster(id_anon)
    local b2 = _b[receptor]
    local se2 = _se[receptor]
    quietly sum is_monotributo if ganador == 0 & cohort_year == `y'
    local cm2 = r(mean)

    * 3. Any Work
    ivreghdfe any_work `controls' (receptor = ganador) ///
        if cohort_year == `y', absorb(sorteo_fe) cluster(id_anon)
    local b3 = _b[receptor]
    local se3 = _se[receptor]
    quietly sum any_work if ganador == 0 & cohort_year == `y'
    local cm3 = r(mean)

    * 4. Log Wage|Emp
    ivreghdfe log_wage `controls' (receptor = ganador) ///
        if cohort_year == `y' & employed == 1, absorb(sorteo_fe) cluster(id_anon)
    local b4 = _b[receptor]
    local se4 = _se[receptor]
    local n4 = e(N)
    quietly sum log_wage if ganador == 0 & cohort_year == `y' & employed == 1
    local cm4 = r(mean)

    * --- Significance stars ---
    forvalues j = 1/4 {
        local t = abs(`b`j''/`se`j'')
        if `t' > 2.576      local star`j' "\sym{***}"
        else if `t' > 1.960 local star`j' "\sym{**}"
        else if `t' > 1.645 local star`j' "\sym{*}"
        else                local star`j' ""
    }

    * --- Format numbers ---
    local b1s: display %9.4f `b1'
    local b2s: display %9.4f `b2'
    local b3s: display %9.4f `b3'
    local b4s: display %9.4f `b4'
    local se1s: display %9.4f `se1'
    local se2s: display %9.4f `se2'
    local se3s: display %9.4f `se3'
    local se4s: display %9.4f `se4'
    local cm1s: display %5.3f `cm1'
    local cm2s: display %5.3f `cm2'
    local cm3s: display %5.3f `cm3'
    local cm4s: display %5.3f `cm4'
    local n1s: display %12.0fc `n1'
    local n4s: display %12.0fc `n4'

    * --- Write rows ---
    file write fh "`y'    & `b1s'`star1' & `b2s'`star2' & `b3s'`star3' & `b4s'`star4'\\" _n
    file write fh "       & (`se1s') & (`se2s') & (`se3s') & (`se4s')\\" _n
    file write fh "       & [`cm1s'; N=`=strtrim("`n1s'")'] & [`cm2s'] & [`cm3s'] & [`cm4s'; N=`=strtrim("`n4s'")']\\" _n

    if `y' < 2023 file write fh "[0.5em]" _n
}

file write fh "\hline" _n

* =========== Panel B: By Credit Type ===========
file write fh "\multicolumn{5}{l}{\textit{Panel B: By Credit Type}} \\" _n
file write fh "\hline" _n

local grp_num = 0
foreach grp_name in "DU" "Construcci\'{o}n" "Lotes" {
    local ++grp_num

    * --- Run 4 IV regressions ---
    ivreghdfe employed `controls' (receptor = ganador) ///
        if tipo_grupo == `grp_num', absorb(sorteo_fe) cluster(id_anon)
    local b1 = _b[receptor]
    local se1 = _se[receptor]
    local n1 = e(N)
    quietly sum employed if ganador == 0 & tipo_grupo == `grp_num'
    local cm1 = r(mean)

    ivreghdfe is_monotributo `controls' (receptor = ganador) ///
        if tipo_grupo == `grp_num', absorb(sorteo_fe) cluster(id_anon)
    local b2 = _b[receptor]
    local se2 = _se[receptor]
    quietly sum is_monotributo if ganador == 0 & tipo_grupo == `grp_num'
    local cm2 = r(mean)

    ivreghdfe any_work `controls' (receptor = ganador) ///
        if tipo_grupo == `grp_num', absorb(sorteo_fe) cluster(id_anon)
    local b3 = _b[receptor]
    local se3 = _se[receptor]
    quietly sum any_work if ganador == 0 & tipo_grupo == `grp_num'
    local cm3 = r(mean)

    ivreghdfe log_wage `controls' (receptor = ganador) ///
        if tipo_grupo == `grp_num' & employed == 1, absorb(sorteo_fe) cluster(id_anon)
    local b4 = _b[receptor]
    local se4 = _se[receptor]
    local n4 = e(N)
    quietly sum log_wage if ganador == 0 & tipo_grupo == `grp_num' & employed == 1
    local cm4 = r(mean)

    * --- Significance stars ---
    forvalues j = 1/4 {
        local t = abs(`b`j''/`se`j'')
        if `t' > 2.576      local star`j' "\sym{***}"
        else if `t' > 1.960 local star`j' "\sym{**}"
        else if `t' > 1.645 local star`j' "\sym{*}"
        else                local star`j' ""
    }

    * --- Format numbers ---
    local b1s: display %9.4f `b1'
    local b2s: display %9.4f `b2'
    local b3s: display %9.4f `b3'
    local b4s: display %9.4f `b4'
    local se1s: display %9.4f `se1'
    local se2s: display %9.4f `se2'
    local se3s: display %9.4f `se3'
    local se4s: display %9.4f `se4'
    local cm1s: display %5.3f `cm1'
    local cm2s: display %5.3f `cm2'
    local cm3s: display %5.3f `cm3'
    local cm4s: display %5.3f `cm4'
    local n1s: display %12.0fc `n1'
    local n4s: display %12.0fc `n4'

    * --- Write rows ---
    file write fh "`grp_name' & `b1s'`star1' & `b2s'`star2' & `b3s'`star3' & `b4s'`star4'\\" _n
    file write fh "       & (`se1s') & (`se2s') & (`se3s') & (`se4s')\\" _n
    file write fh "       & [`cm1s'; N=`=strtrim("`n1s'")'] & [`cm2s'] & [`cm3s'] & [`cm4s'; N=`=strtrim("`n4s'")']\\" _n

    if `grp_num' < 3 file write fh "[0.5em]" _n
}

file write fh "\hline\hline" _n
file write fh "\multicolumn{5}{p{0.85\textwidth}}{\scriptsize IV/2SLS with full controls (edad, pre-employment, pre-wage). Instrument: \emph{ganador}. SE clustered at person level (in parentheses). Control means and N in brackets. Log Wage\textbar Emp estimated on employed subsample. Sorteo FE absorbed.}" _n
file write fh "\multicolumn{5}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}" _n
file write fh "\end{tabular}" _n
file write fh "\end{table}" _n

file close fh

di as text "  table_het_compact.tex saved"


/*==============================================================================
  STEP 7: APPENDIX — CREDIT TYPE × COHORT YEAR

  Rows: cohort years (2020–2023).
  Columns: credit types (DU, Construcción, Lotes) × 2 outcomes (Formal Emp, Log Wage).
  IV/2SLS with full controls only.
  table_het_type_year.tex — Appendix A
==============================================================================*/

di as text _n "=== STEP 7: Credit type × cohort year (appendix) ===" _n

use "$temp/cross_section_v2.dta", clear

local controls "edad pre_employed pre_wage"

capture file close fh
file open fh using "$tables/table_het_type_year.tex", write replace

file write fh "\begin{table}[H]\centering" _n
file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
file write fh "\caption{Heterogeneity by Credit Type and Cohort Year: IV Estimates}" _n
file write fh "\label{tab:het_type_year}" _n
file write fh "\scriptsize" _n
file write fh "\begin{tabular}{@{}lcccccc@{}}" _n
file write fh "\hline\hline" _n
file write fh " & \multicolumn{2}{c}{DU} & \multicolumn{2}{c}{Construcci\'{o}n} & \multicolumn{2}{c}{Lotes} \\" _n
file write fh "\cline{2-3}\cline{4-5}\cline{6-7}" _n
file write fh " & Formal Emp & Log Wage & Formal Emp & Log Wage & Formal Emp & Log Wage \\" _n
file write fh " & (1) & (2) & (3) & (4) & (5) & (6) \\" _n
file write fh "\hline" _n

forvalues y = 2020/2023 {

    * Run 6 regressions: 3 credit types × 2 outcomes
    local grp_num = 0
    foreach grp in "du" "con" "lot" {
        local ++grp_num

        * Formal Employment
        capture ivreghdfe employed `controls' (receptor = ganador) ///
            if tipo_grupo == `grp_num' & cohort_year == `y', ///
            absorb(sorteo_fe) cluster(id_anon)
        if _rc == 0 {
            local b_`grp'_e: display %9.4f _b[receptor]
            local se_`grp'_e: display %9.4f _se[receptor]
            local t = abs(_b[receptor] / _se[receptor])
            if `t' > 2.576      local star_`grp'_e "\sym{***}"
            else if `t' > 1.960 local star_`grp'_e "\sym{**}"
            else if `t' > 1.645 local star_`grp'_e "\sym{*}"
            else                local star_`grp'_e ""
            local ok_`grp'_e = 1
        }
        else {
            local ok_`grp'_e = 0
        }

        * Log Wage|Emp
        capture ivreghdfe log_wage `controls' (receptor = ganador) ///
            if tipo_grupo == `grp_num' & cohort_year == `y' & employed == 1, ///
            absorb(sorteo_fe) cluster(id_anon)
        if _rc == 0 {
            local b_`grp'_w: display %9.4f _b[receptor]
            local se_`grp'_w: display %9.4f _se[receptor]
            local t = abs(_b[receptor] / _se[receptor])
            if `t' > 2.576      local star_`grp'_w "\sym{***}"
            else if `t' > 1.960 local star_`grp'_w "\sym{**}"
            else if `t' > 1.645 local star_`grp'_w "\sym{*}"
            else                local star_`grp'_w ""
            local ok_`grp'_w = 1
        }
        else {
            local ok_`grp'_w = 0
        }
    }

    * Write coefficient row
    file write fh "`y'"
    foreach grp in "du" "con" "lot" {
        foreach oc in "e" "w" {
            if `ok_`grp'_`oc'' == 1 {
                file write fh " & `b_`grp'_`oc''`star_`grp'_`oc''"
            }
            else {
                file write fh " & "
            }
        }
    }
    file write fh "\\" _n

    * Write SE row
    file write fh "       "
    foreach grp in "du" "con" "lot" {
        foreach oc in "e" "w" {
            if `ok_`grp'_`oc'' == 1 {
                file write fh " & (`se_`grp'_`oc'')"
            }
            else {
                file write fh " & "
            }
        }
    }
    file write fh "\\" _n

    if `y' < 2023 file write fh "[0.5em]" _n
}

file write fh "\hline\hline" _n
file write fh "\multicolumn{7}{p{0.90\textwidth}}{\scriptsize IV/2SLS with full controls (edad, pre-employment, pre-wage). Instrument: \emph{ganador}. SE clustered at person level. Log Wage on employed subsample. Sorteo FE absorbed.}" _n
file write fh "\multicolumn{7}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}" _n
file write fh "\end{tabular}" _n
file write fh "\end{table}" _n

file close fh

di as text "  table_het_type_year.tex saved (appendix)"


/*==============================================================================
  SUMMARY
==============================================================================*/

di as text _n(3) "========================================"
di as text       "  sipa_labor_outcomes.do — Complete"
di as text       "========================================"
di as text _n "Specification: person × sorteo, reghdfe, cluster(id_anon)"
di as text "sorteo_fe = group(fecha_sorteo, tipo, desarrollo, tipologia, cupo)"
di as text "3 control specs: (1) none, (2) age only, (3) all controls (edad+pre-emp+pre-wage)"
di as text _n "Tables saved to: $tables/"
di as text _n "  PAPER TABLES (directly \\input'd):"
di as text "    table_extensive.tex     — Section 5.1 (9 cols)"
di as text "    table_intensive.tex     — Section 5.2 (6 cols)"
di as text "    table_het_compact.tex   — Heterogeneity (4 cols, Panels A+B)"
di as text "    table_het_type_year.tex — Appendix A (6 cols × 4 years)"
di as text _n "WARNING: Do NOT run procrear_rq2.do after this script."
di as text "         It overwrites table_extensive.tex and table_intensive.tex"
di as text "         with a different (person-level, no controls) specification."
