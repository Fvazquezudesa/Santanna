/*==============================================================================
  PROCREAR — Paper Tables: BCRA (Financial Inclusion) Outcomes

  THIS SCRIPT GENERATES THE OFFICIAL PAPER TABLES FOR BCRA OUTCOMES.
  Do NOT run procrear_rq1_v2.do after this — it overwrites the same table
  files with a different formatting specification.

  Specification:
    - Unit of observation: person × sorteo inscription
    - Sorteo FE: group(fecha_sorteo, tipo, desarrollourbanistico, tipologia, cupo)
    - Treatment: ganador (ITT) / receptor instrumented by ganador (IV)
    - SE clustered at the person level (id_anon)
    - Three control specifications per outcome:
        (1) No controls
        (2) Age only: edad
        (3) Full controls: edad, pre-employment, pre-wage

  SELF-CONTAINED: this script builds its own upstream artifacts (deflator,
  sorteo cross-section, SIPA person-month panel, BCRA entity-cost ranking)
  from raw data in $data/. Does NOT depend on paper_labor_outcomes.do or
  ranking_bcra.do having been run before.

  Caveat: STEP 0 overwrites the standard $temp files (deflator.dta,
  sorteo_sample_v2.dta, sipa_panel.dta, ranking_entidades_costo.dta). Don't
  run paper_bcra_outcomes concurrently with paper_labor_outcomes.

  ===========================================================================
  OUTPUT → PAPER MAPPING
  ===========================================================================

  Table file                        Paper location
  ─────────────────────────────────  ──────────────────────────────────────
  bcra_core_a.tex                    Section 5.5 — Credit Access
                                       (N Entities + Total Debt, 6 cols)
  bcra_core_b.tex                    Section 5.5 — Credit Quality
                                       (Max Sit. + Any Default, 6 cols)
  bcra_core_c.tex                    Section 5.5 — Credit Cost
                                       (Entity Cost + Active BCRA + Q4 Cost, 9 cols)
  bcra_nohipo_core_a.tex             Section 5.5 — Credit Access (excl. Hipo)
  bcra_nohipo_core_b.tex             Section 5.5 — Credit Quality (excl. Hipo)
  bcra_nohipo_core_c.tex             Section 5.5 — Credit Cost (excl. Hipo)

  ===========================================================================
  OUTLINE
  ===========================================================================

  STEP 0: Self-contained upstream build (deflator + sorteo + SIPA + ranking)
  STEP 1: Build sorteo-level sample (reuses sorteo_sample_v2.dta from STEP 0)
  STEP 2: Build BCRA person-month panels (all entities + nohipo)
  STEP 3: Merge → sorteo-level cross-sections + pre-treatment SIPA controls
  STEP 4: ITT estimation (Panel A) — core_a, core_b, core_c per sample
  STEP 5: IV estimation (Panel B) — appended to same table files

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
cap mkdir "$temp"

* --- REQUIRED PACKAGES --------------------------------------------------------
* ssc install estout, replace
* ssc install reghdfe, replace
* ssc install ftools, replace
* ssc install ivreghdfe, replace


/*==============================================================================
  STEP 0: SELF-CONTAINED UPSTREAM BUILD

  Builds the 4 intermediates that paper_bcra_outcomes needs from raw data:
    0.1  Deflator                  -> $temp/deflator.dta
    0.2  Sorteo cross-section      -> $temp/sorteo_sample_v2.dta
    0.3  SIPA person-month panel   -> $temp/sipa_panel.dta
    0.4  Ranking entidades costo   -> $temp/ranking_entidades_costo.dta

  Logic mirrors paper_labor_outcomes.do (Steps 1-3) and ranking_bcra.do.
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 0: Self-contained upstream build"
di as text       "==================================================================="


/*--- 0.1 DEFLATOR -----------------------------------------------------------*/
di as text _n "--- 0.1 Deflator ---"

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

keep periodo_month deflator
save "$temp/deflator.dta", replace
di as text "    deflator saved (" _N " months)"


/*--- 0.2 SORTEO CROSS-SECTION ----------------------------------------------*/
di as text _n "--- 0.2 Sorteo cross-section ---"

use "$data/Data_sorteos.dta", clear
di as text "    Raw sorteos: N = " _N

* Fill missings for FE grouping
replace desarrollourbanistico = 0 if desarrollourbanistico == .
replace tipologia             = 0 if tipologia == .
replace cupo                  = 0 if cupo == .

* Sorteo FE = randomization pool
egen sorteo_fe = group(fecha_sorteo tipo desarrollourbanistico tipologia cupo)

* Credit type groups + drop Refacción
gen tipo_grupo = .
replace tipo_grupo = 1 if tipo == 5
replace tipo_grupo = 2 if inlist(tipo, 2, 3, 4)
replace tipo_grupo = 3 if inlist(tipo, 6)
replace tipo_grupo = 4 if inlist(tipo, 1, 8, 9, 10, 11, 12, 13)
label define tipo_grupo_lbl 1 "DU" 2 "Construccion" 3 "Lotes" 4 "Refaccion", replace
label values tipo_grupo tipo_grupo_lbl
drop if tipo_grupo == 4

* Drop degenerate sorteos (winrate 0 or 1)
bys sorteo_fe: egen _winrate = mean(ganador)
drop if _winrate == 0 | _winrate == 1
drop _winrate

* Time variables
gen sorteo_month = mofd(fecha_sorteo)
format sorteo_month %tm
gen cohort_year = year(fecha_sorteo)

* edad: from Data_sorteos.edad_sorteo (no imputation, no fallbacks)
drop edad
rename edad_sorteo edad
label variable edad "Edad (anos) al dia del sorteo (de Data_sorteos)"
cap drop fnacimiento

* Monotributo indicator (used in labor pipeline; harmless here)
replace monotributo = . if monotributo == 24
replace monotributo = . if monotributo == 1
gen byte is_monotributo = (monotributo > 0 & monotributo != .)

di as text "    Sorteo sample saved: N = " _N
save "$temp/sorteo_sample_v2.dta", replace


/*--- 0.3 SIPA PERSON-MONTH PANEL --------------------------------------------*/
di as text _n "--- 0.3 SIPA person-month panel ---"

* Filter list
preserve
    use "$temp/sorteo_sample_v2.dta", clear
    keep id_anon
    duplicates drop
    save "$temp/_person_list.dta", replace
restore

use "$data/Data_SIPA.dta", clear
merge m:1 id_anon using "$temp/_person_list.dta", keep(match) nogenerate

* Calendar month
gen int _y = floor(mes / 100)
gen int _m = mod(mes, 100)
gen periodo_month = ym(_y, _m)
format periodo_month %tm
drop _y _m

* Aguinaldo deseasonalization via SAC subtraction (exact)
gen double wage_desest = remuneracion
replace wage_desest = remuneracion - sac if !missing(sac)
replace wage_desest = 0 if wage_desest < 0 & !missing(wage_desest)

* Deflate to constant prices
merge m:1 periodo_month using "$temp/deflator.dta", keep(master match) nogenerate
gen double real_wage = wage_desest / deflator
replace real_wage = 0 if wage_desest == .

* Collapse to person × month
collapse (sum) total_wage = real_wage, by(id_anon periodo_month)
gen byte employed = 1

di as text "    SIPA panel saved: N = " _N
save "$temp/sipa_panel.dta", replace
erase "$temp/_person_list.dta"


/*--- 0.4 RANKING ENTIDADES POR COSTO FINANCIERO ----------------------------*/
di as text _n "--- 0.4 Ranking entidades costo ---"

import delimited "$data/Data_préstamos_bancos_BCRA.CSV", ///
    delimiter(";") encoding("latin1") clear
di as text "    Raw rows: " _N

* Keep peso-denominated, fixed-rate
keep if denominación == "Pesos"
drop if tipodetasa == "Variable"
di as text "    After Pesos/fixed-rate filter: " _N

* Parse costo
rename costofinancieroefectivototalmáxi costo_str
replace costo_str = subinstr(costo_str, ",", ".", .)
destring costo_str, gen(costo) force

drop if costo <= 0
drop if costo == .
di as text "    After dropping zero/missing costo: " _N

capture rename códigodeentidad cod_entidad
if _rc != 0 capture rename codigodeentidad cod_entidad
capture rename descripcióndeentidad entidad
if _rc != 0 capture rename descripciondeentidad entidad

collapse (mean) mean_costo=costo (median) median_costo=costo (count) n_products=costo, ///
    by(cod_entidad entidad)

sort median_costo

di as text "    Ranking entities saved: " _N
save "$temp/ranking_entidades_costo.dta", replace


/*==============================================================================
  STEP 1: BUILD SORTEO-LEVEL ANALYSIS SAMPLE
  (Reuses $temp/sorteo_sample_v2.dta from STEP 0)
==============================================================================*/

use "$temp/sorteo_sample_v2.dta", clear



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

replace entidad_str="BANCO DE GALICIA Y BUENOS AIRES S.A." if entidad_str=="BANCO GGAL SA"

gen byte is_hipotecario = (strpos(entidad_str, "BANCO HIPOTECARIO S.A.") > 0)

gen byte top10 = 0
replace top10 = 1 if entidad_str=="BANCO BBVA ARGENTINA S.A."
replace top10 = 1 if entidad_str=="BANCO DE GALICIA Y BUENOS AIRES S.A."
replace top10 = 1 if entidad_str=="BANCO DE LA NACION ARGENTINA"
replace top10 = 1 if entidad_str=="BANCO DE LA PROVINCIA DE BUENOS AIRES"
replace top10 = 1 if entidad_str=="BANCO DE LA PROVINCIA DE CORDOBA S.A."
replace top10 = 1 if entidad_str=="BANCO MACRO S.A."
replace top10 = 1 if entidad_str=="BANCO PATAGONIA S.A."
replace top10 = 1 if entidad_str=="BANCO SANTANDER ARGENTINA SOCIEDAD ANONIMA"
replace top10 = 1 if entidad_str=="NUEVO BANCO DE ENTRE RÍOS S.A."
replace top10 = 1 if entidad_str=="NUEVO BANCO DE SANTA FE SA"
replace top10 = 1 if is_hipotecario == 1

gen byte not_top10 = 1 - top10

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
preserve
keep entidad_str median_costo
duplicates drop
quietly sum median_costo, detail
local q4_cutoff = r(p75)
gen byte is_q4_costo = (median_costo >= `q4_cutoff') if median_costo != .
replace is_q4_costo = 0 if is_q4_costo == .
di as text "Entity cost Q4 cutoff (p75): " %9.1f `q4_cutoff'
count if is_q4_costo == 1
di as text "  Rows at Q4 entities: " r(N)
save "$temp/median_costo.dta", replace


restore
merge m:1 entidad_str using "$temp/median_costo.dta", keep(master match) nogenerate

drop entidad_str

* --- Save entity-level data before collapse (need for both panels) -----------
save "$temp/_bcra_entity_level.dta", replace


collapse (max) max_situacion=situacion ///
               has_top10=top10 has_other=not_top10 ///
               in_q4_costo=is_q4_costo ///
         (sum) total_deuda=monto_deuda ///
         (mean) costo_entidad=median_costo ///
         (count) n_entities=entidad, ///
         by(id_anon periodo)

gen any_default = (max_situacion ==5) if max_situacion < .
gen has_credit = 1

gen int py = floor(periodo / 100)
gen int pm = mod(periodo, 100)
gen periodo_month = ym(py, pm)
format periodo_month %tm
drop py pm

save "$temp/bcra_panel.dta", replace

use "$temp/_bcra_entity_level.dta", clear
drop if is_hipotecario == 1
di as text "After dropping Hipotecario rows: N = " _N

collapse (max) max_situacion=situacion ///
               has_top10=top10 has_other=not_top10 ///
               in_q4_costo=is_q4_costo ///
         (sum) total_deuda=monto_deuda ///
         (mean) costo_entidad=median_costo ///
         (count) n_entities=entidad, ///
         by(id_anon periodo)

gen any_default = (max_situacion == 5) if max_situacion < .
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


use "$temp/sipa_panel.dta", clear
rename total_wage pre_wage
replace employed =0 if pre_wage==0
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

    * Total Debt: take the value of the last row only if it is from Nov 2025
    * or later (i.e., the person was still active in BCRA at end of panel);
    * otherwise treat the person as carrying no current outstanding debt.
    replace total_deuda = 0 if periodo_month < ym(2025, 11)

    gen byte active_bcra = (periodo_month >= `max_month' - 2) if has_credit == 1
    replace active_bcra = 0 if active_bcra == .

    keep id_anon n_entities max_situacion any_default total_deuda ///
         has_credit has_top10 has_other costo_entidad in_q4_costo active_bcra

    save "$temp/_bcra_person_outcomes.dta", replace

    * 3b. Merge onto sorteo-level sample
    use "$temp/sorteo_sample_v2.dta", clear
    keep id_anon ganador receptor sorteo_fe tipo tipo_grupo sorteo_month ///
         cohort_year fecha_sorteo edad mujer

    merge m:1 id_anon using "$temp/_bcra_person_outcomes.dta", ///
        keep(master match) nogenerate

    * 3c. Add pre-treatment SIPA controls
    gen periodo_month = sorteo_month
    format periodo_month %tm
    merge m:1 id_anon periodo_month using "$temp/_pretreat_sipa_bcra.dta", ///
        keep(master match) nogenerate
    replace pre_wage = 0 if pre_wage == .
    replace pre_employed = 0 if pre_employed == .
	replace pre_employed = 0 if pre_wage == 0

    drop periodo_month

    * mujer comes directly from Data_sorteos.mujer (no fallback from genero needed;
    *  Data_sorteos was updated earlier to have mujer as the canonical column)

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
  STEPS 4–5: ESTIMATION (looped over both samples)

  Two samples:
    "all"    — all entities including Banco Hipotecario  → prefix: bcra_
    "nohipo" — excluding Banco Hipotecario rows          → prefix: bcra_nohipo_

  For each sample, produce:
    Step 4: ITT (Panel A) — core_a, core_b, core_c
    Step 5: IV  (Panel B) — appended to same files
==============================================================================*/

foreach smp in "all" "nohipo" {

    if "`smp'" == "all" {
        local dta "cross_section_bcra_v2.dta"
        local pfx "bcra"
        local smp_note ""
        local smp_label "ALL entities"
        local cap_smp ""
    }
    if "`smp'" == "nohipo" {
        local dta "cross_section_bcra_nohipo_v2.dta"
        local pfx "bcra_nohipo"
        local smp_note " Excl.\ Banco Hipotecario."
        local smp_label "EXCL. Hipotecario"
        local cap_smp " (Excl.\ Banco Hipotecario)"
    }

    di as text _n(3) "########################################################"
    di as text       "  SAMPLE: `smp_label'"
    di as text       "  Prefix: `pfx'_*"
    di as text       "########################################################"


    * ==========================================================================
    * STEP 4: ITT — PANEL A (replace, fragment)
    * ==========================================================================

    di as text _n "=== STEP 4 [`smp_label']: ITT ===" _n

    use "$temp/`dta'", clear

    * --- Core outcomes: credit access + quality + cost -------------------------
    eststo clear
    foreach var in n_entities total_deuda max_situacion any_default ///
                   costo_entidad active_bcra in_q4_costo {
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
            eststo itt_`var'_`spec': reghdfe `var' ganador `controls', ///
                absorb(sorteo_fe) cluster(id_anon)
            quietly sum `var' if ganador == 0
            estadd scalar cmean = r(mean)
            estadd local ctl_imb "`mark_imb'"
            estadd local ctl_full "`mark_full'"
        }
    }

    * --- Panel A: ITT — core_a: Credit Access (N Entities + Total Debt, 6 cols) ---
    esttab itt_n_entities_noctl itt_n_entities_imbctl itt_n_entities_ctl ///
           itt_total_deuda_noctl itt_total_deuda_imbctl itt_total_deuda_ctl ///
        using "$tables/`pfx'_core_a.tex", replace ///
        keep(ganador) se(%9.4f) b(%9.4f) ///
        star(* 0.10 ** 0.05 *** 0.01) ///
        nonumbers nomtitles noobs nor2 ///
        coeflabels(ganador "Ganador") ///
        prehead(`"\begin{table}[H]\centering"' ///
                `"\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}"' ///
                `"\caption{BCRA Outcomes --- Credit Access`cap_smp'}"' ///
                `"\label{tab:`pfx'_core_a}"' ///
                `"\scriptsize"' ///
                `"\begin{tabular}{@{}l*{6}{c}@{}}"' ///
                `"\hline\hline"' ///
                `" & \multicolumn{3}{c}{N Entities} & \multicolumn{3}{c}{Total Debt} \\"' ///
                `"\cline{2-4}\cline{5-7}"' ///
                `" & (1) & (2) & (3) & (4) & (5) & (6) \\"' ///
                `"\hline"' ///
                `"\multicolumn{7}{l}{\textit{Panel A: ITT}} \\"') ///
        postfoot(`"[1em]"') ///
        substitute(\_ _) ///
        fragment

    * --- Panel A: ITT — core_b: Credit Quality (Max Sit. + Any Default, 6 cols) ---
    esttab itt_max_situacion_noctl itt_max_situacion_imbctl itt_max_situacion_ctl ///
           itt_any_default_noctl itt_any_default_imbctl itt_any_default_ctl ///
        using "$tables/`pfx'_core_b.tex", replace ///
        keep(ganador) se(%9.4f) b(%9.4f) ///
        star(* 0.10 ** 0.05 *** 0.01) ///
        nonumbers nomtitles noobs nor2 ///
        coeflabels(ganador "Ganador") ///
        prehead(`"\begin{table}[H]\centering"' ///
                `"\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}"' ///
                `"\caption{BCRA Outcomes --- Credit Quality`cap_smp'}"' ///
                `"\label{tab:`pfx'_core_b}"' ///
                `"\scriptsize"' ///
                `"\begin{tabular}{@{}l*{6}{c}@{}}"' ///
                `"\hline\hline"' ///
                `" & \multicolumn{3}{c}{Max Sit.} & \multicolumn{3}{c}{Any Default} \\"' ///
                `"\cline{2-4}\cline{5-7}"' ///
                `" & (1) & (2) & (3) & (4) & (5) & (6) \\"' ///
                `"\hline"' ///
                `"\multicolumn{7}{l}{\textit{Panel A: ITT}} \\"') ///
        postfoot(`"[1em]"') ///
        substitute(\_ _) ///
        fragment

    * --- Panel A: ITT — core_c: Credit Cost (Entity Cost + Active BCRA + Q4 Cost, 9 cols) ---
    esttab itt_costo_entidad_noctl itt_costo_entidad_imbctl itt_costo_entidad_ctl ///
           itt_active_bcra_noctl itt_active_bcra_imbctl itt_active_bcra_ctl ///
           itt_in_q4_costo_noctl itt_in_q4_costo_imbctl itt_in_q4_costo_ctl ///
        using "$tables/`pfx'_core_c.tex", replace ///
        keep(ganador) se(%9.4f) b(%9.4f) ///
        star(* 0.10 ** 0.05 *** 0.01) ///
        nonumbers nomtitles noobs nor2 ///
        coeflabels(ganador "Ganador") ///
        prehead(`"\begin{table}[H]\centering"' ///
                `"\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}"' ///
                `"\caption{BCRA Outcomes --- Credit Cost`cap_smp'}"' ///
                `"\label{tab:`pfx'_core_c}"' ///
                `"\scriptsize"' ///
                `"\setlength{\tabcolsep}{2pt}"' ///
                `"\begin{tabular}{@{}l*{9}{c}@{}}"' ///
                `"\hline\hline"' ///
                `" & \multicolumn{3}{c}{Entity Cost} & \multicolumn{3}{c}{Active BCRA} & \multicolumn{3}{c}{Q4 Cost} \\"' ///
                `"\cline{2-4}\cline{5-7}\cline{8-10}"' ///
                `" & (1) & (2) & (3) & (4) & (5) & (6) & (7) & (8) & (9) \\"' ///
                `"\hline"' ///
                `"\multicolumn{10}{l}{\textit{Panel A: ITT}} \\"') ///
        postfoot(`"[1em]"') ///
        substitute(\_ _) ///
        fragment


    * ==========================================================================
    * STEP 5: IV / 2SLS — PANEL B (append, fragment → closes table)
    * ==========================================================================

    di as text _n "=== STEP 5 [`smp_label']: IV ===" _n

    use "$temp/`dta'", clear

    * --- Core outcomes: credit access + quality + cost -------------------------
    eststo clear
    foreach var in n_entities total_deuda max_situacion any_default ///
                   costo_entidad active_bcra in_q4_costo {
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
            eststo iv_`var'_`spec': ivreghdfe `var' `controls' ///
                (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
            quietly sum `var' if ganador == 0
            estadd scalar cmean = r(mean)
            estadd scalar fs_F = e(widstat)
            estadd local ctl_imb "`mark_imb'"
            estadd local ctl_full "`mark_full'"
        }
    }

    * --- Panel B: IV — core_a: Credit Access (6 cols) -------------------------
    esttab iv_n_entities_noctl iv_n_entities_imbctl iv_n_entities_ctl ///
           iv_total_deuda_noctl iv_total_deuda_imbctl iv_total_deuda_ctl ///
        using "$tables/`pfx'_core_a.tex", append ///
        keep(receptor) se(%9.4f) b(%9.4f) ///
        star(* 0.10 ** 0.05 *** 0.01) ///
        nonumbers nomtitles ///
        coeflabels(receptor "Receptor") ///
        prehead(`"\multicolumn{7}{l}{\textit{Panel B: IV / 2SLS}} \\"') ///
        prefoot(`"\hline"') ///
        stats(cmean fs_F N ctl_imb ctl_full, ///
              labels("Control mean" "First-stage F" "Observations" ///
                     "Age only" "All controls") ///
              fmt(%9.3f %9.0fc %9.0fc %s %s)) ///
        postfoot(`"\hline\hline"' ///
                 `"\multicolumn{7}{p{0.95\textwidth}}{\scriptsize 2SLS. Instrument: ganador.`smp_note' Cols (1),(4): no controls. (2),(5): age only. (3),(6): all controls (add pre-employed, pre-wage). SE clustered at person level. Sorteo FE absorbed.}\\"' ///
                 `"\multicolumn{7}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}"' ///
                 `"\end{tabular}"' ///
                 `"\end{table}"') ///
        substitute(\_ _) ///
        fragment

    * --- Panel B: IV — core_b: Credit Quality (6 cols) ------------------------
    esttab iv_max_situacion_noctl iv_max_situacion_imbctl iv_max_situacion_ctl ///
           iv_any_default_noctl iv_any_default_imbctl iv_any_default_ctl ///
        using "$tables/`pfx'_core_b.tex", append ///
        keep(receptor) se(%9.4f) b(%9.4f) ///
        star(* 0.10 ** 0.05 *** 0.01) ///
        nonumbers nomtitles ///
        coeflabels(receptor "Receptor") ///
        prehead(`"\multicolumn{7}{l}{\textit{Panel B: IV / 2SLS}} \\"') ///
        prefoot(`"\hline"') ///
        stats(cmean fs_F N ctl_imb ctl_full, ///
              labels("Control mean" "First-stage F" "Observations" ///
                     "Age only" "All controls") ///
              fmt(%9.3f %9.0fc %9.0fc %s %s)) ///
        postfoot(`"\hline\hline"' ///
                 `"\multicolumn{7}{p{0.95\textwidth}}{\scriptsize 2SLS. Instrument: ganador.`smp_note' Cols (1),(4): no controls. (2),(5): age only. (3),(6): all controls (add pre-employed, pre-wage). SE clustered at person level. Sorteo FE absorbed.}\\"' ///
                 `"\multicolumn{7}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}"' ///
                 `"\end{tabular}"' ///
                 `"\end{table}"') ///
        substitute(\_ _) ///
        fragment

    * --- Panel B: IV — core_c: Credit Cost (9 cols) ---------------------------
    esttab iv_costo_entidad_noctl iv_costo_entidad_imbctl iv_costo_entidad_ctl ///
           iv_active_bcra_noctl iv_active_bcra_imbctl iv_active_bcra_ctl ///
           iv_in_q4_costo_noctl iv_in_q4_costo_imbctl iv_in_q4_costo_ctl ///
        using "$tables/`pfx'_core_c.tex", append ///
        keep(receptor) se(%9.4f) b(%9.4f) ///
        star(* 0.10 ** 0.05 *** 0.01) ///
        nonumbers nomtitles ///
        coeflabels(receptor "Receptor") ///
        prehead(`"\multicolumn{10}{l}{\textit{Panel B: IV / 2SLS}} \\"') ///
        prefoot(`"\hline"') ///
        stats(cmean fs_F N ctl_imb ctl_full, ///
              labels("Control mean" "First-stage F" "Observations" ///
                     "Age only" "All controls") ///
              fmt(%9.3f %9.0fc %9.0fc %s %s)) ///
        postfoot(`"\hline\hline"' ///
                 `"\multicolumn{10}{p{0.85\textwidth}}{\scriptsize 2SLS. Instrument: ganador.`smp_note' Cols (1),(4),(7): no controls. (2),(5),(8): age only. (3),(6),(9): all controls (add pre-employed, pre-wage). SE clustered at person level. Sorteo FE absorbed.}"' ///
                 `"\multicolumn{10}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}"' ///
                 `"\end{tabular}"' ///
                 `"\end{table}"') ///
        substitute(\_ _) ///
        fragment

}  // end foreach smp


/*==============================================================================
  STEP 6: COMPACT BY-CREDIT-TYPE TABLE (B1-style, Financial Stability)

  Rows    : DU / Construccion / Lotes (tipo_grupo 1-3)
  Columns : Total Debt | Max Sit. | Any Default | Entity Cost | Q4 Cost
                                                  (5 outcomes, no N Entities, no Active BCRA)
  Method  : IV / 2SLS with full controls (edad pre_employed pre_wage).
            ALL entities sample (includes Banco Hipotecario).

  Output  : $tables/bcra_type_compact.tex  —  Appendix B companion to
            stabfull_type_compact.tex (B1 in the paper).
==============================================================================*/

di as text _n "=== STEP 6: Compact by-credit-type BCRA table ===" _n

use "$temp/cross_section_bcra_v2.dta", clear

local controls "edad pre_employed pre_wage"
local outcomes "total_deuda max_situacion any_default costo_entidad in_q4_costo"

capture file close fh
file open fh using "$tables/bcra_type_compact.tex", write replace

file write fh "\begin{table}[H]\centering" _n
file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
file write fh "\caption{Financial Stability by Credit Type: IV Estimates with Full Controls}" _n
file write fh "\label{tab:bcra_type_compact}" _n
file write fh "\scriptsize" _n
file write fh "\begin{tabular}{@{}lccccc@{}}" _n
file write fh "\hline\hline" _n
file write fh " & Total Debt & Max Sit. & Any Default & Entity Cost & Q4 Cost \\" _n
file write fh " & (1) & (2) & (3) & (4) & (5) \\" _n
file write fh "\hline" _n

local grp_num = 0
foreach grp_name in "Apartment Purchases (DU)" "House Construction" "Land Purchases" {
    local ++grp_num

    * --- Run 5 IV regressions ---
    local j = 0
    foreach var of local outcomes {
        local ++j
        ivreghdfe `var' `controls' (receptor = ganador) ///
            if tipo_grupo == `grp_num', absorb(sorteo_fe) cluster(id_anon)
        local b`j' = _b[receptor]
        local se`j' = _se[receptor]
        local n`j' = e(N)
        quietly sum `var' if ganador == 0 & tipo_grupo == `grp_num'
        local cm`j' = r(mean)
    }

    * --- Significance stars ---
    forvalues j = 1/5 {
        local t = abs(`b`j''/`se`j'')
        if `t' > 2.576      local star`j' "\sym{***}"
        else if `t' > 1.960 local star`j' "\sym{**}"
        else if `t' > 1.645 local star`j' "\sym{*}"
        else                local star`j' ""
    }

    * --- Format numbers: total_deuda is large (ARS), others are proportions ---
    local b1s:  display %9.1fc `b1'
    local se1s: display %9.1fc `se1'
    local cm1s: display %9.1fc `cm1'
    forvalues j = 2/5 {
        local b`j's:  display %9.4f `b`j''
        local se`j's: display %9.4f `se`j''
        local cm`j's: display %5.3f `cm`j''
    }
    local n1s: display %12.0fc `n1'

    * --- Write rows ---
    file write fh "`grp_name' & `b1s'`star1' & `b2s'`star2' & `b3s'`star3' & `b4s'`star4' & `b5s'`star5'\\" _n
    file write fh "   & (`se1s') & (`se2s') & (`se3s') & (`se4s') & (`se5s')\\" _n
    file write fh "   & [`cm1s'; N=`=strtrim("`n1s'")'] & [`cm2s'] & [`cm3s'] & [`cm4s'] & [`cm5s']\\" _n

    if `grp_num' < 3 file write fh "[0.5em]" _n
}

file write fh "\hline\hline" _n
file write fh "\multicolumn{6}{p{0.95\textwidth}}{\scriptsize IV/2SLS with full controls (edad, pre-employment, pre-wage). Instrument: \emph{Winner}. SE clustered at person level (in parentheses). Control means and $N$ in brackets. BCRA credit registry, all entities (incl.\ Banco Hipotecario). Total Debt in ARS. Max Sit.: worst BCRA situation code (1=normal, 5=irrecoverable). Any Default: indicator for Max Sit.\ \(\geq 5\). Entity Cost: borrower's mean cost rank across entities. Q4 Cost: indicator for borrowing from a top-quartile-cost entity. Lottery-round FE absorbed.} \\" _n
file write fh "\multicolumn{6}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}" _n
file write fh "\end{tabular}" _n
file write fh "\end{table}" _n

file close fh

di as text "  bcra_type_compact.tex saved"

