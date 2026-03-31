/*==============================================================================
  PROCREAR — RQ1 v2: Financial Inclusion (Sorteo-Level)

  Effect of PROCREAR housing credit on financial outcomes (BCRA).
  Mirrors procrear_labor_v2.do structure.

  KEY CHANGES FROM v1 (procrear_rq1.do):
    - Unit of observation = person × sorteo inscription (not person)
    - Treatment: ganador/receptor at each sorteo (not ever_ganador/ever_receptor)
    - sorteo_fe = group(fecha_sorteo, tipo, DU, tipologia, cupo)
    - reghdfe / ivreghdfe with absorbed FE (not reg ... i.sorteo_fe)
    - SE clustered at person level
    - noctl / ctl loop (pre-treatment SIPA controls)
    - Heterogeneity by credit type and credit type × cohort year

  Outcomes (BCRA, last available period per person):
    Core: n_entities, max_situacion, any_default, total_deuda
    Entity type: has_top10, has_other

  REQUIRES: $temp/sipa_panel.dta from procrear_labor_v2.do (for pre-treatment
  controls). Run labor v2 Steps 1-3 first if not available.

  ===========================================================================
  OUTLINE
  ===========================================================================

  STEP 1: Build sorteo-level sample (reuses sorteo_sample_v2.dta if available)
  STEP 2: Build BCRA person-month panel (entity type flags)
  STEP 3: Merge → sorteo-level cross-section + pre-treatment SIPA controls
  STEP 4: Balance check + First stage
  STEP 5: ITT — reduced form (reghdfe)
  STEP 6: IV / 2SLS (ivreghdfe)
  STEP 7: Heterogeneity by lottery cohort
  STEP 8: Full estimation by credit type
  STEP 9: Heterogeneity by cohort year × credit type

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


/*==============================================================================
  STEP 1: BUILD SORTEO-LEVEL ANALYSIS SAMPLE
  (Reuses $temp/sorteo_sample_v2.dta if already built by labor v2)
==============================================================================*/

di as text _n "=== STEP 1: Sorteo-level sample ===" _n

capture confirm file "$temp/sorteo_sample_v2.dta"
if _rc == 0 {
    di as text "Reusing existing sorteo_sample_v2.dta"
    use "$temp/sorteo_sample_v2.dta", clear
}
else {
    di as text "Building sorteo sample from scratch..."
    use "$data/Data_sorteos.dta", clear

    * --- CUIL prefix → birth date mapping (built before filtering) ---
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

    replace desarrollourbanistico = 0 if desarrollourbanistico == .
    replace tipologia = 0 if tipologia == .
    replace cupo = 0 if cupo == .

    egen sorteo_fe = group(fecha_sorteo tipo desarrollourbanistico tipologia cupo)

    gen tipo_grupo = .
    replace tipo_grupo = 1 if tipo == 5                              // DU
    replace tipo_grupo = 2 if inlist(tipo, 2, 3, 4)                  // Construccion
    replace tipo_grupo = 3 if inlist(tipo, 6)                        // Lotes
    replace tipo_grupo = 4 if inlist(tipo, 1, 8, 9, 10, 11, 12, 13) // Refaccion
    label define tipo_grupo_lbl 1 "DU" 2 "Construccion" 3 "Lotes" 4 "Refaccion"
    label values tipo_grupo tipo_grupo_lbl

    * --- DROP REFACCION ---
    drop if tipo_grupo == 4

    * --- DROP DEGENERATE SORTEOS (winrate == 0 or winrate == 1) ---
    bys sorteo_fe: egen _winrate = mean(ganador)
    di as text _n "Dropping degenerate sorteos (winrate == 0 or winrate == 1):"
    count if _winrate == 0 | _winrate == 1
    drop if _winrate == 0 | _winrate == 1
    drop _winrate

    gen sorteo_month = mofd(fecha_sorteo)
    format sorteo_month %tm
    gen cohort_year = year(fecha_sorteo)

    * --- Derive edad from CUIL (with fallbacks) ---
    gen str3 dni_prefix_str = substr(cuil, 3, 3)
    destring dni_prefix_str, gen(dni_prefix) force

    merge m:1 dni_prefix using `prefix_map', keep(master match) nogenerate

    gen sorteo_year = year(fecha_sorteo)
    gen sorteo_month_num = month(fecha_sorteo)

    rename edad edad_original

    gen edad = sorteo_year - med_birth_year
    replace edad = edad - 1 if sorteo_month_num < med_birth_month & edad != .
    replace edad = sorteo_year - year(fnacimiento) if edad == . & fnacimiento != .
    replace edad = edad - 1 if sorteo_month_num < month(fnacimiento) & edad != . & med_birth_year == .
    replace edad = edad_original if edad == . & edad_original != .

    drop edad_original dni_prefix_str dni_prefix med_fnac med_birth_date ///
         med_birth_year med_birth_month sorteo_year sorteo_month_num fnacimiento

    replace monotributo = . if monotributo == 24
    replace monotributo = . if monotributo == 1
    gen byte is_monotributo = (monotributo > 0 & monotributo != .)

    save "$temp/sorteo_sample_v2.dta", replace
}

di as text "Sorteo sample: N = " _N
tab tipo_grupo


/*==============================================================================
  STEP 2: BUILD BCRA PERSON-MONTH PANELS (with Entity Type Flags)

  Produces TWO panels:
    - bcra_panel.dta:       all entities (incl. Banco Hipotecario)
    - bcra_panel_nohipo.dta: excluding Banco Hipotecario rows before collapse

  Rationale for nohipo: BCRA debt records for Hipotecario do NOT include
  the PROCREAR loan itself, so these are other credit products. Dropping
  Hipotecario rows isolates effects on non-PROCREAR-lender credit.
==============================================================================*/

di as text _n "=== STEP 2: Building BCRA panels ===" _n
di as text "Loading BCRA data (~2.7 GB, may take several minutes)..."

use "$data/Data_BCRA.dta", clear
di as text "BCRA loaded. N = " _N

* --- Keep only persons in analysis sample ------------------------------------
preserve
use "$temp/sorteo_sample_v2.dta", clear
keep id_anon
duplicates drop
save "$temp/_person_list_bcra.dta", replace
restore

merge m:1 id_anon using "$temp/_person_list_bcra.dta", keep(match) nogenerate
di as text "After filtering to analysis sample: N = " _N

* --- Flag entities -----------------------------------------------------------
*   Top-10 (BCRA Jan 2026) + Banco Hipotecario (PROCREAR lender)

capture confirm string variable entidad
if _rc == 0 {
    gen entidad_str = upper(strtrim(entidad))
}
else {
    decode entidad, gen(entidad_str)
    replace entidad_str = upper(strtrim(entidad_str))
}

gen byte is_hipotecario = (strpos(entidad_str, "HIPOTECARIO") > 0)

gen byte top10 = 0
replace top10 = 1 if strpos(entidad_str, "BBVA") > 0
replace top10 = 1 if strpos(entidad_str, "GALICIA") > 0
replace top10 = 1 if strpos(entidad_str, "NACION") > 0
replace top10 = 1 if strpos(entidad_str, "PROVINCIA DE BUENOS") > 0
replace top10 = 1 if strpos(entidad_str, "PROVINCIA DE CORD") > 0
replace top10 = 1 if strpos(entidad_str, "MACRO") > 0
replace top10 = 1 if strpos(entidad_str, "PATAGONIA") > 0
replace top10 = 1 if strpos(entidad_str, "SANTANDER") > 0
replace top10 = 1 if strpos(entidad_str, "ENTRE R") > 0
replace top10 = 1 if strpos(entidad_str, "SANTA FE") > 0
replace top10 = 1 if is_hipotecario == 1

gen byte not_top10 = 1 - top10

di as text _n "=== ENTITY MATCHING DIAGNOSTIC ==="
di as text "Major entities (top-10 + Hipotecario):"
tab entidad_str if top10 == 1, sort
di as text _n "Hipotecario rows:"
count if is_hipotecario == 1
di as text _n "Overall:"
tab top10

* --- Merge entity-level cost ranking (from ranking_bcra.do) ------------------
preserve
use "$temp/ranking_entidades_costo.dta", clear
gen entidad_str = upper(strtrim(entidad))
keep entidad_str median_costo
save "$temp/_cost_lookup.dta", replace
restore

merge m:1 entidad_str using "$temp/_cost_lookup.dta", keep(master match) nogenerate
count if median_costo != .
di as text _n "Rows matched with cost ranking: " r(N) " of " _N
erase "$temp/_cost_lookup.dta"

* --- Compute Q4 entity cost flag (top quartile = most expensive) --------------
quietly sum median_costo, detail
local q4_cutoff = r(p75)
gen byte is_q4_costo = (median_costo >= `q4_cutoff') if median_costo != .
replace is_q4_costo = 0 if is_q4_costo == .
di as text "Entity cost Q4 cutoff (p75): " %9.1f `q4_cutoff'
count if is_q4_costo == 1
di as text "  Rows at Q4 entities: " r(N)

drop entidad_str

* --- Save entity-level data before collapse (need for both panels) -----------
save "$temp/_bcra_entity_level.dta", replace

* --- Panel A: ALL entities (including Hipotecario) ---------------------------
di as text _n "Collapsing FULL panel (all entities)..."

collapse (max) max_situacion=situacion ///
               has_top10=top10 has_other=not_top10 ///
               in_q4_costo=is_q4_costo ///
         (sum) total_deuda=monto_deuda ///
         (mean) costo_entidad=median_costo ///
         (count) n_entities=entidad, ///
         by(id_anon periodo)

gen any_default = (max_situacion >= 3) if max_situacion < .
gen has_credit = 1

gen int py = floor(periodo / 100)
gen int pm = mod(periodo, 100)
gen periodo_month = ym(py, pm)
format periodo_month %tm
drop py pm

di as text "BCRA panel (all): N = " _N
save "$temp/bcra_panel.dta", replace

* --- Panel B: EXCLUDING Hipotecario rows -------------------------------------
di as text _n "Collapsing NO-HIPO panel (excl. Banco Hipotecario)..."

use "$temp/_bcra_entity_level.dta", clear
drop if is_hipotecario == 1
di as text "After dropping Hipotecario rows: N = " _N

* Recompute top10 without Hipotecario (top10 flag already excludes it
* for dropped rows, but the variable still has Hipo=1 on remaining rows)
* Actually: we dropped all Hipo rows, so top10 on remaining rows is
* correctly just the top-10 banks without Hipotecario.

collapse (max) max_situacion=situacion ///
               has_top10=top10 has_other=not_top10 ///
               in_q4_costo=is_q4_costo ///
         (sum) total_deuda=monto_deuda ///
         (mean) costo_entidad=median_costo ///
         (count) n_entities=entidad, ///
         by(id_anon periodo)

gen any_default = (max_situacion >= 3) if max_situacion < .
gen has_credit = 1

gen int py = floor(periodo / 100)
gen int pm = mod(periodo, 100)
gen periodo_month = ym(py, pm)
format periodo_month %tm
drop py pm

di as text "BCRA panel (no-hipo): N = " _N
save "$temp/bcra_panel_nohipo.dta", replace

erase "$temp/_bcra_entity_level.dta"
erase "$temp/_person_list_bcra.dta"


/*==============================================================================
  STEP 3: MERGE AND BUILD CROSS-SECTIONS (sorteo-level)

  For each panel (all / nohipo):
    - Person-level BCRA outcomes (last period)
    - Merged onto sorteo-level sample
    - Pre-treatment controls from SIPA

  Output: cross_section_bcra_v2.dta, cross_section_bcra_nohipo_v2.dta
==============================================================================*/

di as text _n "=== STEP 3: Building cross-sections ===" _n

* --- Prepare pre-treatment SIPA controls (shared) ----------------------------
capture confirm file "$temp/sipa_panel.dta"
if _rc != 0 {
    di as error "ERROR: $temp/sipa_panel.dta not found."
    di as error "Run procrear_labor_v2.do Steps 1-3 first, then re-run this script."
    error 601
}

use "$temp/sipa_panel.dta", clear
rename total_wage pre_wage
rename employed pre_employed
save "$temp/_pretreat_sipa_bcra.dta", replace

* --- Build cross-section for each panel --------------------------------------
foreach smp in "all" "nohipo" {

    if "`smp'" == "all" {
        local panel_dta "bcra_panel.dta"
        local out_dta "cross_section_bcra_v2.dta"
        local label "ALL entities"
    }
    if "`smp'" == "nohipo" {
        local panel_dta "bcra_panel_nohipo.dta"
        local out_dta "cross_section_bcra_nohipo_v2.dta"
        local label "EXCL. Hipotecario"
    }

    di as text _n "--- Building cross-section: `label' ---"

    * 3a. Person-level BCRA outcomes (last period)
    use "$temp/sorteo_sample_v2.dta", clear
    keep id_anon
    duplicates drop

    merge 1:m id_anon using "$temp/`panel_dta'"

    foreach var in has_credit total_deuda n_entities any_default has_top10 has_other in_q4_costo {
        replace `var' = 0 if _merge == 1
    }

    drop if _merge == 2
    drop _merge

    * Active in last 3 months of BCRA panel
    quietly sum periodo_month
    local max_month = r(max)

    bys id_anon (periodo_month): keep if _n == _N

    gen byte active_bcra = (periodo_month >= `max_month' - 2) if has_credit == 1
    replace active_bcra = 0 if active_bcra == .

    keep id_anon n_entities max_situacion any_default total_deuda ///
         has_credit has_top10 has_other costo_entidad in_q4_costo active_bcra

    save "$temp/_bcra_person_outcomes.dta", replace

    * 3b. Merge onto sorteo-level sample
    use "$temp/sorteo_sample_v2.dta", clear
    keep id_anon ganador receptor sorteo_fe tipo tipo_grupo sorteo_month ///
         cohort_year fecha_sorteo edad genero

    merge m:1 id_anon using "$temp/_bcra_person_outcomes.dta", ///
        keep(master match) nogenerate

    * 3c. Add pre-treatment SIPA controls
    gen periodo_month = sorteo_month
    format periodo_month %tm
    merge m:1 id_anon periodo_month using "$temp/_pretreat_sipa_bcra.dta", ///
        keep(master match) nogenerate
    replace pre_wage = 0 if pre_wage == .
    replace pre_employed = 0 if pre_employed == .
    drop periodo_month

    * Fill missing mujer from Data_sorteos genero (encoded: 1=mujer, 2=hombre)
    replace mujer = (genero == 1) if mujer == . & genero != .
    drop genero

    di as text "Cross-section (`label'): N = " _N
    di as text _n "Control group means (`label'):"
    foreach var in n_entities max_situacion any_default total_deuda ///
                  has_credit has_top10 has_other costo_entidad ///
                  in_q4_costo active_bcra {
        quietly sum `var' if ganador == 0
        di as text "  `var': " %9.3f r(mean) " (N = " r(N) ")"
    }

    save "$temp/`out_dta'", replace
    erase "$temp/_bcra_person_outcomes.dta"
}

erase "$temp/_pretreat_sipa_bcra.dta"


/*==============================================================================
  STEP 4: BALANCE CHECK + FIRST STAGE
==============================================================================*/

di as text _n "=== STEP 4: Balance Check + First Stage ===" _n

* --- 4a. Balance check -------------------------------------------------------
use "$temp/sorteo_sample_v2.dta", clear

local balvars "edad ingresosdeclarados conyuge hijos"

eststo clear
foreach var of local balvars {
    di as text "Balance: `var'"
    eststo bal_`var': reghdfe `var' ganador, absorb(sorteo_fe) cluster(id_anon)
}

esttab bal_* using "$tables/bcra_balance.tex", replace ///
    keep(ganador) se(%9.4f) b(%9.4f) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    stats(N r2, labels("Observations" "R-squared") fmt(%9.0fc %9.3f)) ///
    mtitles("Age" "Income" "Spouse" "Children") ///
    title("Balance Check — Demographics") ///
    note("SE clustered at person level. Sorteo FE absorbed.") ///
    label

* --- 4b. First stage ---------------------------------------------------------
use "$temp/cross_section_bcra_v2.dta", clear

eststo clear

eststo fs1: reghdfe receptor ganador, absorb(sorteo_fe) cluster(id_anon)
di as text "First-stage coef: " %6.4f _b[ganador]

eststo fs2: reghdfe receptor ganador pre_wage pre_employed edad mujer, ///
    absorb(sorteo_fe) cluster(id_anon)

esttab fs1 fs2 using "$tables/bcra_firststage.tex", replace ///
    keep(ganador) se(%9.4f) b(%9.4f) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    stats(N r2, labels("Observations" "R-squared") fmt(%9.0fc %9.3f)) ///
    mtitles("No controls" "With controls") ///
    title("First Stage — Lottery Win on Credit Receipt") ///
    note("Dep var: receptor. SE clustered at person level. Sorteo FE absorbed.") ///
    label


/*==============================================================================
  STEPS 5–9: ESTIMATION (looped over both samples)

  Two samples:
    "all"    — all entities including Banco Hipotecario  → prefix: bcra_
    "nohipo" — excluding Banco Hipotecario rows          → prefix: bcra_nohipo_

  For each sample, produce:
    Step 5: ITT (core + entities)
    Step 6: IV  (core + entities)
    Step 7: Heterogeneity by cohort
    Step 8: By credit type
    Step 9: Credit type × cohort year
==============================================================================*/

foreach smp in "all" "nohipo" {

    if "`smp'" == "all" {
        local dta "cross_section_bcra_v2.dta"
        local pfx "bcra"
        local smp_note ""
        local smp_label "ALL entities"
        local ent_note "Major = BCRA Top-10 + Banco Hipotecario."
        local cap_smp ""
    }
    if "`smp'" == "nohipo" {
        local dta "cross_section_bcra_nohipo_v2.dta"
        local pfx "bcra_nohipo"
        local smp_note " Excl.\ Banco Hipotecario."
        local smp_label "EXCL. Hipotecario"
        local ent_note "Major = BCRA Top-10 (excl. Hipotecario)."
        local cap_smp " (Excl.\ Banco Hipotecario)"
    }

    di as text _n(3) "########################################################"
    di as text       "  SAMPLE: `smp_label'"
    di as text       "  Prefix: `pfx'_*"
    di as text       "########################################################"


    * === STEP 5: ITT ==========================================================

    di as text _n "=== STEP 5 [`smp_label']: ITT ===" _n

    use "$temp/`dta'", clear

    foreach ctl in "noctl" "ctl" {
        if "`ctl'" == "noctl" local controls ""
        if "`ctl'" == "noctl" local note_ctl "No pre-treatment controls."
        if "`ctl'" == "ctl"   local controls "pre_wage pre_employed edad mujer"
        if "`ctl'" == "ctl"   local note_ctl "Controls: pre-wage, pre-employment, age, gender."

        * --- Core BCRA outcomes ---
        eststo clear

        foreach var in n_entities max_situacion any_default total_deuda costo_entidad active_bcra in_q4_costo {
            eststo itt_`var': reghdfe `var' ganador `controls', ///
                absorb(sorteo_fe) cluster(id_anon)
            quietly sum `var' if ganador == 0
            estadd scalar cmean = r(mean)
        }

        esttab itt_* using "$tables/`pfx'_itt_core_`ctl'.tex", replace ///
            keep(ganador) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean N r2, labels("Control mean" "Observations" "R-squared") ///
                  fmt(%9.3f %9.0fc %9.3f)) ///
            mtitles("N Entities" "Max Sit." "Any Default" "Total Debt" "Entity Cost" "Active BCRA" "Q4 Cost") ///
            title("ITT — BCRA Outcomes") ///
            note("`note_ctl'`smp_note' SE clustered at person level. Sorteo FE absorbed.") ///
            label

        * --- Entity-type outcomes ---
        eststo clear

        foreach var in has_top10 has_other {
            eststo itt_`var': reghdfe `var' ganador `controls', ///
                absorb(sorteo_fe) cluster(id_anon)
            quietly sum `var' if ganador == 0
            estadd scalar cmean = r(mean)
        }

        esttab itt_* using "$tables/`pfx'_itt_entities_`ctl'.tex", replace ///
            keep(ganador) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean N r2, labels("Control mean" "Observations" "R-squared") ///
                  fmt(%9.3f %9.0fc %9.3f)) ///
            mtitles("Has Major Entity" "Has Other Entity") ///
            title("ITT — Entity Type") ///
            note("`ent_note' `note_ctl'`smp_note' SE clustered at person level. Sorteo FE absorbed.") ///
            label
    }


    * === STEP 6: IV / 2SLS ====================================================

    di as text _n "=== STEP 6 [`smp_label']: IV ===" _n

    use "$temp/`dta'", clear

    foreach ctl in "noctl" "ctl" {
        if "`ctl'" == "noctl" local controls ""
        if "`ctl'" == "noctl" local note_ctl "No pre-treatment controls."
        if "`ctl'" == "ctl"   local controls "pre_wage pre_employed edad mujer"
        if "`ctl'" == "ctl"   local note_ctl "Controls: pre-wage, pre-employment, age, gender."

        * --- Core BCRA outcomes ---
        eststo clear

        foreach var in n_entities max_situacion any_default total_deuda costo_entidad active_bcra in_q4_costo {
            eststo iv_`var': ivreghdfe `var' `controls' ///
                (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
            quietly sum `var' if ganador == 0
            estadd scalar cmean = r(mean)
            estadd scalar fs_F = e(widstat)
        }

        esttab iv_* using "$tables/`pfx'_iv_core_`ctl'.tex", replace ///
            keep(receptor) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
                  fmt(%9.3f %9.1f %9.0fc)) ///
            mtitles("N Entities" "Max Sit." "Any Default" "Total Debt" "Entity Cost" "Active BCRA" "Q4 Cost") ///
            title(`"IV — BCRA Outcomes`cap_smp'"') ///
            note("2SLS. Instrument: ganador. `note_ctl'`smp_note' SE clustered at person level. Sorteo FE absorbed.") ///
            substitute(`"\begin{tabular}"' `"\label{tab:`pfx'}\scriptsize\begin{tabular}"' `"\multicolumn{8}{l}{\footnotesize"' `"\multicolumn{8}{p{0.95\textwidth}}{\scriptsize"') ///
            label

        * --- Entity-type outcomes ---
        eststo clear

        foreach var in has_top10 has_other {
            eststo iv_`var': ivreghdfe `var' `controls' ///
                (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
            quietly sum `var' if ganador == 0
            estadd scalar cmean = r(mean)
            estadd scalar fs_F = e(widstat)
        }

        esttab iv_* using "$tables/`pfx'_iv_entities_`ctl'.tex", replace ///
            keep(receptor) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
                  fmt(%9.3f %9.1f %9.0fc)) ///
            mtitles("Has Major Entity" "Has Other Entity") ///
            title("IV — Entity Type") ///
            note("2SLS. Instrument: ganador. `ent_note' `note_ctl'`smp_note' SE clustered at person level. Sorteo FE absorbed.") ///
            label
    }


    * === STEP 7: HETEROGENEITY BY COHORT =======================================

    di as text _n "=== STEP 7 [`smp_label']: Het by Cohort ===" _n

    use "$temp/`dta'", clear

    foreach ctl in "noctl" "ctl" {
        if "`ctl'" == "noctl" local controls ""
        if "`ctl'" == "noctl" local note_ctl "No pre-treatment controls."
        if "`ctl'" == "ctl"   local controls "pre_wage pre_employed edad mujer"
        if "`ctl'" == "ctl"   local note_ctl "Controls: pre-wage, pre-employment, age, gender."

        * --- ITT N Entities by cohort ---
        eststo clear
        forvalues y = 2020/2023 {
            eststo het_`y': reghdfe n_entities ganador `controls' ///
                if cohort_year == `y', absorb(sorteo_fe) cluster(id_anon)
            quietly sum n_entities if ganador == 0 & cohort_year == `y'
            estadd scalar cmean = r(mean)
        }
        esttab het_* using "$tables/`pfx'_het_itt_nent_year_`ctl'.tex", replace ///
            keep(ganador) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean N r2, labels("Control mean" "Observations" "R-squared") ///
                  fmt(%9.3f %9.0fc %9.3f)) ///
            mtitles("2020" "2021" "2022" "2023") ///
            title("ITT by Cohort — N Entities") ///
            note("`note_ctl'`smp_note' SE clustered at person level. Sorteo FE absorbed.") ///
            label

        * --- IV N Entities by cohort ---
        eststo clear
        forvalues y = 2020/2023 {
            eststo iv_`y': ivreghdfe n_entities `controls' ///
                (receptor = ganador) if cohort_year == `y', ///
                absorb(sorteo_fe) cluster(id_anon)
            quietly sum n_entities if ganador == 0 & cohort_year == `y'
            estadd scalar cmean = r(mean)
            estadd scalar fs_F = e(widstat)
        }
        esttab iv_* using "$tables/`pfx'_het_iv_nent_year_`ctl'.tex", replace ///
            keep(receptor) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
                  fmt(%9.3f %9.1f %9.0fc)) ///
            mtitles("2020" "2021" "2022" "2023") ///
            title("IV by Cohort — N Entities") ///
            note("2SLS. Instrument: ganador. `note_ctl'`smp_note' SE clustered at person level. Sorteo FE absorbed.") ///
            label

        * --- IV Total Deuda by cohort ---
        eststo clear
        forvalues y = 2020/2023 {
            eststo iv_d_`y': ivreghdfe total_deuda `controls' ///
                (receptor = ganador) if cohort_year == `y', ///
                absorb(sorteo_fe) cluster(id_anon)
            quietly sum total_deuda if ganador == 0 & cohort_year == `y'
            estadd scalar cmean = r(mean)
            estadd scalar fs_F = e(widstat)
        }
        esttab iv_d_* using "$tables/`pfx'_het_iv_deuda_year_`ctl'.tex", replace ///
            keep(receptor) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
                  fmt(%12.0f %9.1f %9.0fc)) ///
            mtitles("2020" "2021" "2022" "2023") ///
            title("IV by Cohort — Total Debt") ///
            note("2SLS. Instrument: ganador. `note_ctl'`smp_note' SE clustered at person level. Sorteo FE absorbed.") ///
            label
    }


    * === STEP 8: BY CREDIT TYPE ================================================

    di as text _n "=== STEP 8 [`smp_label']: By Credit Type ===" _n

    use "$temp/`dta'", clear

    local grp_names `" "DU" "Construccion" "Lotes" "'

    forvalues g = 1/3 {
        local grp : word `g' of `grp_names'
        local grp_lower = lower("`grp'")

        di as text _n "  Credit type: `grp'"

        foreach ctl in "noctl" "ctl" {
            if "`ctl'" == "noctl" local controls ""
            if "`ctl'" == "noctl" local note_ctl "No pre-treatment controls."
            if "`ctl'" == "ctl"   local controls "pre_wage pre_employed edad mujer"
            if "`ctl'" == "ctl"   local note_ctl "Controls: pre-wage, pre-employment, age, gender."

            * ---- ITT Core ----
            eststo clear
            foreach var in n_entities max_situacion any_default total_deuda costo_entidad active_bcra in_q4_costo {
                eststo itt_`var': reghdfe `var' ganador `controls' ///
                    if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
                quietly sum `var' if ganador == 0 & tipo_grupo == `g'
                estadd scalar cmean = r(mean)
            }
            esttab itt_* using "$tables/`pfx'_type_`grp_lower'_itt_core_`ctl'.tex", replace ///
                keep(ganador) se(%9.4f) b(%9.4f) ///
                star(* 0.10 ** 0.05 *** 0.01) ///
                stats(cmean N r2, labels("Control mean" "Observations" "R-squared") ///
                      fmt(%9.3f %9.0fc %9.3f)) ///
                mtitles("N Entities" "Max Sit." "Any Default" "Total Debt" "Entity Cost" "Active BCRA" "Q4 Cost") ///
                title("ITT — BCRA Outcomes (`grp')") ///
                note("`note_ctl'`smp_note' SE clustered at person level. Sorteo FE absorbed.") ///
                label

            * ---- ITT Entities ----
            eststo clear
            foreach var in has_top10 has_other {
                eststo itt_`var': reghdfe `var' ganador `controls' ///
                    if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
                quietly sum `var' if ganador == 0 & tipo_grupo == `g'
                estadd scalar cmean = r(mean)
            }
            esttab itt_* using "$tables/`pfx'_type_`grp_lower'_itt_entities_`ctl'.tex", replace ///
                keep(ganador) se(%9.4f) b(%9.4f) ///
                star(* 0.10 ** 0.05 *** 0.01) ///
                stats(cmean N r2, labels("Control mean" "Observations" "R-squared") ///
                      fmt(%9.3f %9.0fc %9.3f)) ///
                mtitles("Has Major Entity" "Has Other Entity") ///
                title("ITT — Entity Type (`grp')") ///
                note("`ent_note' `note_ctl'`smp_note' SE clustered at person level. Sorteo FE absorbed.") ///
                label

            * ---- IV Core ----
            eststo clear
            foreach var in n_entities max_situacion any_default total_deuda costo_entidad active_bcra in_q4_costo {
                capture eststo iv_`var': ivreghdfe `var' `controls' ///
                    (receptor = ganador) if tipo_grupo == `g', ///
                    absorb(sorteo_fe) cluster(id_anon)
                if _rc == 0 {
                    quietly sum `var' if ganador == 0 & tipo_grupo == `g'
                    estadd scalar cmean = r(mean)
                    estadd scalar fs_F = e(widstat)
                }
            }
            esttab iv_* using "$tables/`pfx'_type_`grp_lower'_iv_core_`ctl'.tex", replace ///
                keep(receptor) se(%9.4f) b(%9.4f) ///
                star(* 0.10 ** 0.05 *** 0.01) ///
                stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
                      fmt(%9.3f %9.1f %9.0fc)) ///
                mtitles("N Entities" "Max Sit." "Any Default" "Total Debt" "Entity Cost" "Active BCRA" "Q4 Cost") ///
                title("IV — BCRA Outcomes (`grp')") ///
                note("2SLS. Instrument: ganador. `note_ctl'`smp_note' SE clustered at person level. Sorteo FE absorbed.") ///
                label

            * ---- IV Entities ----
            eststo clear
            foreach var in has_top10 has_other {
                capture eststo iv_`var': ivreghdfe `var' `controls' ///
                    (receptor = ganador) if tipo_grupo == `g', ///
                    absorb(sorteo_fe) cluster(id_anon)
                if _rc == 0 {
                    quietly sum `var' if ganador == 0 & tipo_grupo == `g'
                    estadd scalar cmean = r(mean)
                    estadd scalar fs_F = e(widstat)
                }
            }
            esttab iv_* using "$tables/`pfx'_type_`grp_lower'_iv_entities_`ctl'.tex", replace ///
                keep(receptor) se(%9.4f) b(%9.4f) ///
                star(* 0.10 ** 0.05 *** 0.01) ///
                stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
                      fmt(%9.3f %9.1f %9.0fc)) ///
                mtitles("Has Major Entity" "Has Other Entity") ///
                title("IV — Entity Type (`grp')") ///
                note("2SLS. `ent_note' `note_ctl'`smp_note' SE clustered at person level. Sorteo FE absorbed.") ///
                label
        }
    }


    * === STEP 9: CREDIT TYPE × COHORT YEAR =====================================

    di as text _n "=== STEP 9 [`smp_label']: Type × Year ===" _n

    use "$temp/`dta'", clear

    local grp_names `" "DU" "Construccion" "Lotes" "'

    forvalues g = 1/3 {
        local grp : word `g' of `grp_names'
        local grp_lower = lower("`grp'")

        di as text "  `grp' × year..."

        foreach ctl in "noctl" "ctl" {
            if "`ctl'" == "noctl" local controls ""
            if "`ctl'" == "noctl" local note_ctl "No pre-treatment controls."
            if "`ctl'" == "ctl"   local controls "pre_wage pre_employed edad mujer"
            if "`ctl'" == "ctl"   local note_ctl "Controls: pre-wage, pre-employment, age, gender."

            * ---- ITT N Entities by year ----
            eststo clear
            forvalues y = 2020/2023 {
                capture eststo itt_`y': reghdfe n_entities ganador `controls' ///
                    if tipo_grupo == `g' & cohort_year == `y', ///
                    absorb(sorteo_fe) cluster(id_anon)
                if _rc == 0 {
                    quietly sum n_entities if ganador == 0 & tipo_grupo == `g' & cohort_year == `y'
                    estadd scalar cmean = r(mean)
                }
            }
            esttab itt_* using "$tables/`pfx'_type_`grp_lower'_het_itt_nent_year_`ctl'.tex", replace ///
                keep(ganador) se(%9.4f) b(%9.4f) ///
                star(* 0.10 ** 0.05 *** 0.01) ///
                stats(cmean N r2, labels("Control mean" "Observations" "R-squared") ///
                      fmt(%9.3f %9.0fc %9.3f)) ///
                mtitles("2020" "2021" "2022" "2023") ///
                title("ITT by Cohort — N Entities (`grp')") ///
                note("`note_ctl'`smp_note' SE clustered at person level. Sorteo FE absorbed.") ///
                label

            * ---- IV N Entities by year ----
            eststo clear
            forvalues y = 2020/2023 {
                capture eststo iv_`y': ivreghdfe n_entities `controls' ///
                    (receptor = ganador) if tipo_grupo == `g' & cohort_year == `y', ///
                    absorb(sorteo_fe) cluster(id_anon)
                if _rc == 0 {
                    quietly sum n_entities if ganador == 0 & tipo_grupo == `g' & cohort_year == `y'
                    estadd scalar cmean = r(mean)
                    estadd scalar fs_F = e(widstat)
                }
            }
            esttab iv_* using "$tables/`pfx'_type_`grp_lower'_het_iv_nent_year_`ctl'.tex", replace ///
                keep(receptor) se(%9.4f) b(%9.4f) ///
                star(* 0.10 ** 0.05 *** 0.01) ///
                stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
                      fmt(%9.3f %9.1f %9.0fc)) ///
                mtitles("2020" "2021" "2022" "2023") ///
                title("IV by Cohort — N Entities (`grp')") ///
                note("2SLS. Instrument: ganador. `note_ctl'`smp_note' SE clustered at person level. Sorteo FE absorbed.") ///
                label

            * ---- ITT Total Deuda by year ----
            eststo clear
            forvalues y = 2020/2023 {
                capture eststo itt_d_`y': reghdfe total_deuda ganador `controls' ///
                    if tipo_grupo == `g' & cohort_year == `y', ///
                    absorb(sorteo_fe) cluster(id_anon)
                if _rc == 0 {
                    quietly sum total_deuda if ganador == 0 & tipo_grupo == `g' & cohort_year == `y'
                    estadd scalar cmean = r(mean)
                }
            }
            esttab itt_d_* using "$tables/`pfx'_type_`grp_lower'_het_itt_deuda_year_`ctl'.tex", replace ///
                keep(ganador) se(%9.4f) b(%9.4f) ///
                star(* 0.10 ** 0.05 *** 0.01) ///
                stats(cmean N r2, labels("Control mean" "Observations" "R-squared") ///
                      fmt(%12.0f %9.0fc %9.3f)) ///
                mtitles("2020" "2021" "2022" "2023") ///
                title("ITT by Cohort — Total Debt (`grp')") ///
                note("`note_ctl'`smp_note' SE clustered at person level. Sorteo FE absorbed.") ///
                label

            * ---- IV Total Deuda by year ----
            eststo clear
            forvalues y = 2020/2023 {
                capture eststo iv_d_`y': ivreghdfe total_deuda `controls' ///
                    (receptor = ganador) if tipo_grupo == `g' & cohort_year == `y', ///
                    absorb(sorteo_fe) cluster(id_anon)
                if _rc == 0 {
                    quietly sum total_deuda if ganador == 0 & tipo_grupo == `g' & cohort_year == `y'
                    estadd scalar cmean = r(mean)
                    estadd scalar fs_F = e(widstat)
                }
            }
            esttab iv_d_* using "$tables/`pfx'_type_`grp_lower'_het_iv_deuda_year_`ctl'.tex", replace ///
                keep(receptor) se(%9.4f) b(%9.4f) ///
                star(* 0.10 ** 0.05 *** 0.01) ///
                stats(cmean fs_F N, labels("Control mean" "First-stage F" "Observations") ///
                      fmt(%12.0f %9.1f %9.0fc)) ///
                mtitles("2020" "2021" "2022" "2023") ///
                title("IV by Cohort — Total Debt (`grp')") ///
                note("2SLS. Instrument: ganador. `note_ctl'`smp_note' SE clustered at person level. Sorteo FE absorbed.") ///
                label
        }
    }

    di as text _n "  Sample `smp_label' complete."

} /* end sample loop */


/*==============================================================================
  SUMMARY
==============================================================================*/

di as text _n(3) "========================================"
di as text       "  PROCREAR RQ1 v2 — Complete"
di as text       "========================================"
di as text _n "Two samples: ALL entities (bcra_*) and EXCL. Hipotecario (bcra_nohipo_*)"
di as text "Unit of observation: person × sorteo inscription"
di as text "SE clustered at person level throughout"
di as text "sorteo_fe = group(fecha_sorteo, tipo, DU, tipologia, cupo)"
di as text "Each table produced in _noctl and _ctl variants."
di as text _n "Tables saved to: $tables/"
di as text "  For each prefix (bcra_ and bcra_nohipo_):"
di as text "  --- Diagnostics (shared) ---"
di as text "  bcra_balance.tex                    — Balance check"
di as text "  bcra_firststage.tex                  — First stage"
di as text "  --- Pooled (×2: noctl, ctl) ---"
di as text "  {pfx}_itt_core_*.tex                — ITT: n_entities, max_sit, default, debt"
di as text "  {pfx}_itt_entities_*.tex            — ITT: has_top10, has_other"
di as text "  {pfx}_iv_core_*.tex                 — IV: n_entities, max_sit, default, debt"
di as text "  {pfx}_iv_entities_*.tex             — IV: has_top10, has_other"
di as text "  --- By cohort (×2: noctl, ctl) ---"
di as text "  {pfx}_het_itt_nent_year_*.tex       — ITT n_entities by year"
di as text "  {pfx}_het_iv_nent_year_*.tex        — IV n_entities by year"
di as text "  {pfx}_het_iv_deuda_year_*.tex       — IV total_deuda by year"
di as text "  --- By credit type (×2: noctl, ctl) ---"
di as text "  {pfx}_type_{grp}_itt_core_*.tex     — ITT core by type"
di as text "  {pfx}_type_{grp}_iv_core_*.tex      — IV core by type"
di as text "  --- By credit type × cohort year (×2: noctl, ctl) ---"
di as text "  {pfx}_type_{grp}_het_*_year_*.tex   — ITT/IV by type × year"
