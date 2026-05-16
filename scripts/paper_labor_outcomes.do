/*==============================================================================
  PROCREAR — Paper Tables: Labor Market Outcomes

  THIS SCRIPT GENERATES THE OFFICIAL PAPER TABLES FOR LABOR OUTCOMES.

  Specification:
    - Unit of observation: person × sorteo inscription
    - Sorteo FE: group(fecha_sorteo, tipo, desarrollourbanistico, tipologia, cupo)
    - Treatment: ganador (ITT) / receptor instrumented by ganador (IV)
    - SE clustered at the person level (id_anon)
    - Three control specs per outcome (steps 5–8 main tables):
        (1) No controls
        (2) Age only: edad
        (3) Full controls: edad, pre-employment, pre-wage, mujer
    - Wages are EXCLUDED from main pooled regressions (step 5); they appear
      only in heterogeneity tables that condition on cohort/type (steps 6–8).
    - Step 5c uses interaction IV with sorteo × mujer fixed effects.

  ===========================================================================
  OUTPUT → PAPER MAPPING
  ===========================================================================

  Table file                        Paper section
  ─────────────────────────────────  ──────────────────────────────────────
  table_first_stage.tex              First stage: receptor on ganador (3 specs)
  table_extensive.tex                Extensive margin (2 outcomes × 3 specs)
  table_emp_share_<k>plus.tex        Post-k-month emp share (3 specs, IV)
  table_het_gender.tex               Gender heterogeneity (interaction IV)
  table_het_type.tex                 Heterogeneity by credit type (IV)
  table_het_cohort.tex               Heterogeneity by cohort year (IV)
  table_het_type_cohort.tex          Heterogeneity by type × cohort (IV)

  ===========================================================================
  OUTLINE
  ===========================================================================

  STEP 1:  Build monthly price deflator
  STEP 2:  Build sorteo-level analysis sample (person × sorteo)
  STEP 3:  Build SIPA person-month panel
  STEP 4:  Merge → cross-section with pre-treatment outcomes
  STEP 4d: New outcome — emp_share_<k>plus (post-k-month employment share)
  STEP 4e: First stage diagnostic — receptor on ganador (3 specs)
  STEP 5:  Main table — Extensive margin (9 cols, 3 specs)
  STEP 5b: Table — emp_share_<k>plus (3 specs, IV only)
  STEP 5c: Gender heterogeneity — interaction IV with sorteo × mujer FE
  STEP 6:  Heterogeneity by credit type — appendix (3 outcomes × 3 types × 2 specs)
  STEP 7:  Heterogeneity by cohort year — appendix (3 outcomes × 4 cohorts × 2 specs)
  STEP 8:  Heterogeneity by type × cohort — appendix (3 types × 2 outcomes × 4 cohorts × 2 specs)

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

* --- ANALYSIS PARAMETERS ------------------------------------------------------
* Window offset (in months) for emp_share long-run outcome.
* Outcome = share of months employed in [fecha_sorteo + k_months, Dec 2025].
* Changing this value re-generates emp_share_<k>plus, table_emp_share_<k>plus.tex,
* etc., automatically via macro interpolation. Reasonable values: 12, 18, 24, 36.
local k_months = 18
local k_label "`k_months'plus"

* --- REQUIRED PACKAGES --------------------------------------------------------
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

use "$data/Data_sorteos.dta", clear

di as text "Raw sorteos: N = " _N

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

* --- edad: de Data_sorteos.edad_sorteo (sin imputacion, sin mezclas) ---------
*     Data_sorteos ahora trae edad_sorteo ya calculada (edad exacta al dia
*     del sorteo). Reemplazamos la columna edad con esa, y dejamos de lado
*     fnacimiento y los fallbacks por CUIL-prefix.
drop edad
rename edad_sorteo edad
label variable edad "Edad (anos) al dia del sorteo (de Data_sorteos)"
cap drop fnacimiento

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


use "$data/Data_SIPA.dta", clear

* Drop pre-window months: not used anywhere downstream (earliest sorteo is Jul 2020,
* so pre-treatment merges and the post-`k_months' window only need >= Jul 2020).
drop if mes < 202007

* Filter to persons in our sample
preserve
use "$temp/sorteo_sample_v2.dta", clear
keep id_anon
duplicates drop
save "$temp/_person_list.dta", replace
restore

merge m:1 id_anon using "$temp/_person_list.dta", keep(match) nogenerate

* Create monthly date
gen int _y = floor(mes / 100)
gen int _m = mod(mes, 100)
gen periodo_month = ym(_y, _m)
format periodo_month %tm
drop _y _m

* Deseasonalize (exact): restar el SAC columnar.
* Supersedes the prior jun/dec ÷ 1.5 heuristic. `sac` da el SAC exacto
* que se pago ese mes, cual sea. Si sac es missing se mantiene remuneracion.
gen double wage_desest = remuneracion
replace wage_desest = remuneracion - sac if !missing(sac)
replace wage_desest = 0 if wage_desest < 0 & !missing(wage_desest)

* Deflate to constant prices
merge m:1 periodo_month using "$temp/deflator.dta", keep(master match) nogenerate
gen double real_wage = wage_desest / deflator
replace real_wage = 0 if wage_desest == .

* Collapse to person × month (mujer viene de Data_sorteos, no de SIPA)
di as text _n "Collapsing to person-month..."
collapse (sum) total_wage=real_wage, by(id_anon periodo_month)

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
replace employed = (periodo_month == ym(2025, 12))
replace employed = 0 if total_wage == 0
replace total_wage = 0 if employed == 0


* Create additional outcomes
gen double log_wage = ln(total_wage) if employed == 1 & total_wage > 0
gen byte any_work = (employed == 1 | is_monotributo == 1)

keep id_anon employed total_wage log_wage any_work periodo_month

save "$temp/_person_outcomes.dta", replace

* --- 4b. Merge person outcomes onto sorteo-level sample -----------------------
use "$temp/sorteo_sample_v2.dta", clear
keep id_anon ganador receptor sorteo_fe tipo tipo_grupo sorteo_month ///
     cohort_year fecha_sorteo is_monotributo edad mujer

merge m:1 id_anon using "$temp/_person_outcomes.dta", keep(master match) nogenerate

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
  STEP 4d: NEW OUTCOME — Share of months employed in [sorteo+k_months, Dec 2025]

  For each (id_anon, sorteo_fe), compute the share of months in the window
  [sorteo_month + `k_months', Dec 2025] where the person had positive-wage
  SIPA employment. Outcome takes values in [0, 1].

  k_months is set at the top of the script. Window length varies by cohort:
  earlier sorteos have longer follow-up windows. Window_len is preserved as a
  diagnostic. Sorteos for which window_len <= 0 get emp_share = missing.
==============================================================================*/

di as text _n "=== STEP 4d: Computing emp_share_`k_label' (k_months=`k_months') ===" _n

* --- Min plausible window_start: earliest sorteo (Ene 2020) + k_months ---
local _min_win = ym(2020, 1) + `k_months'

* --- Filter SIPA panel to relevant window range (employed + positive wage) ---
use "$temp/sipa_panel.dta", clear
keep if periodo_month >= `_min_win' & periodo_month <= ym(2025, 12)
keep if employed == 1 & total_wage > 0
keep id_anon periodo_month
save "$temp/_sipa_`k_label'.dta", replace

* --- Build unique (id_anon, sorteo_fe, sorteo_month) records ---
use "$temp/cross_section_v2.dta", clear
keep id_anon sorteo_fe sorteo_month
duplicates drop
save "$temp/_windows_`k_label'.dta", replace

* --- joinby + in-window filter + collapse to count ---
use "$temp/_windows_`k_label'.dta", clear
joinby id_anon using "$temp/_sipa_`k_label'.dta"
gen int window_start = sorteo_month + `k_months'
keep if periodo_month >= window_start & periodo_month <= ym(2025, 12)
gen byte _emp = 1
collapse (sum) emp_months_`k_label' = _emp, by(id_anon sorteo_fe)
save "$temp/_emp_count_`k_label'.dta", replace

* --- Merge back, compute share, save ---
use "$temp/cross_section_v2.dta", clear
merge m:1 id_anon sorteo_fe using "$temp/_emp_count_`k_label'.dta", ///
    keep(master match) nogenerate
replace emp_months_`k_label' = 0 if emp_months_`k_label' == .

gen int window_len = ym(2025, 12) - (sorteo_month + `k_months') + 1
gen double emp_share_`k_label' = emp_months_`k_label' / window_len if window_len > 0
label variable emp_share_`k_label' "Share of months employed in [sorteo+`k_months'm, Dec 2025]"
label variable emp_months_`k_label' "Count of employed months in [sorteo+`k_months'm, Dec 2025]"
label variable window_len "Post-`k_months'm window length (months)"

di as text _n "=== emp_share_`k_label': descriptive stats ==="
sum emp_share_`k_label' emp_months_`k_label' window_len

save "$temp/cross_section_v2.dta", replace
cap erase "$temp/_emp_count_`k_label'.dta"
cap erase "$temp/_sipa_`k_label'.dta"
cap erase "$temp/_windows_`k_label'.dta"


/*==============================================================================
  STEP 4e: FIRST STAGE — receptor on ganador

  Pre-analysis diagnostic. Regress credit take-up (receptor) on lottery
  outcome (ganador) with sorteo FE and clustered SEs. 3 specs (no controls,
  age only, full controls). F-stat is the standard weak-instrument F.

  Output: table_first_stage.tex
==============================================================================*/

di as text _n "=== STEP 4e: First stage (receptor on ganador) ===" _n

use "$temp/cross_section_v2.dta", clear

eststo clear

foreach spec in "noctl" "agectl" "ctl" {
    if "`spec'" == "noctl" {
        local controls ""
        local mark_age ""
        local mark_full ""
    }
    if "`spec'" == "agectl" {
        local controls "edad"
        local mark_age "\checkmark"
        local mark_full ""
    }
    if "`spec'" == "ctl" {
        local controls "edad pre_employed pre_wage mujer"
        local mark_age "\checkmark"
        local mark_full "\checkmark"
    }

    eststo fs_`spec': reghdfe receptor ganador `controls', ///
        absorb(sorteo_fe) cluster(id_anon)
    quietly sum receptor if ganador == 0
    estadd scalar cmean = r(mean)
    test ganador
    estadd scalar fs_F = r(F)
    estadd local ctl_age "`mark_age'"
    estadd local ctl_full "`mark_full'"
}

esttab fs_noctl fs_agectl fs_ctl ///
       using "$tables/table_first_stage.tex", replace ///
    keep(ganador) se(%9.4f) b(%9.4f) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    nonumbers nomtitles ///
    coeflabels(ganador "Winner") ///
    prehead(`"\begin{table}[H]\centering"' ///
            `"\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}"' ///
            `"\caption{First Stage: Credit Take-up on Lottery Winning}"' ///
            `"\label{tab:first_stage}"' ///
            `"\scriptsize"' ///
            `"\setlength{\tabcolsep}{0pt}"' ///
            `"\begin{tabular}{@{}l*{3}{>{\centering\arraybackslash}p{0.17\textwidth}}@{}}"' ///
            `"\hline\hline"' ///
            `" & (1) & (2) & (3) \\"' ///
            `"\hline"') ///
    prefoot(`"\hline"') ///
    stats(cmean fs_F N ctl_age ctl_full, ///
          labels("Control mean (losers)" "F-statistic" "Observations" ///
                 "Age only" "All controls") ///
          fmt(%9.4f %9.1f %9.0fc %s %s)) ///
    postfoot(`"\hline\hline"' ///
             `"\end{tabular}"' ///
             `"\par\smallskip"' ///
             `"\begin{minipage}{0.85\textwidth}"' ///
             `"\scriptsize"' ///
             `"OLS. Outcome: \emph{recipient} (=1 if applicant received PROCREAR credit). Coefficient on \emph{winner} is the take-up rate among winners minus among losers (compliance share). (1): no controls. (2): adds \emph{age}. (3): adds \emph{age, pre\_employed, pre\_wage, female}. SE clustered at person level (in parentheses). Lottery FE absorbed. F-statistic tests H\(_0\): coefficient on \emph{winner} = 0.\\"' ///
             `"\sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)"' ///
             `"\end{minipage}"' ///
             `"\end{table}"') ///
    substitute(\_ _) fragment

di as text "  table_first_stage.tex saved"


/*==============================================================================
  STEP 5: MAIN TABLE — EXTENSIVE MARGIN

  Paper Section 5.1: table_extensive.tex  (6 cols: 2 outcomes × 3 specs)
  Intensive margin (wages) lives in heterogeneity steps (6, 7, 8) only.
==============================================================================*/

di as text _n "=== STEP 5: Main table (Extensive Margin) ===" _n

use "$temp/cross_section_v2.dta", clear

* ======================================================================
* TABLE: EXTENSIVE MARGIN — paper Section 5.1
* 6 columns: Formal Emp (3 specs) | Monotributo (3 specs)
* Panel A: ITT, Panel B: IV/2SLS
* ======================================================================

* --- Panel A: ITT ---
eststo clear

foreach spec in "noctl" "agectl" "ctl" {
    if "`spec'" == "noctl" {
        local controls ""
        local mark_age ""
        local mark_full ""
    }
    if "`spec'" == "agectl" {
        local controls "edad"
        local mark_age "\checkmark"
        local mark_full ""
    }
    if "`spec'" == "ctl" {
        local controls "edad pre_employed pre_wage mujer"
        local mark_age "\checkmark"
        local mark_full "\checkmark"
    }

    eststo itt_emp_`spec': reghdfe employed ganador `controls', ///
        absorb(sorteo_fe) cluster(id_anon)
    quietly sum employed if ganador == 0
    estadd scalar cmean = r(mean)
    estadd local ctl_age "`mark_age'"
    estadd local ctl_full "`mark_full'"

    eststo itt_mono_`spec': reghdfe is_monotributo ganador `controls', ///
        absorb(sorteo_fe) cluster(id_anon)
    quietly sum is_monotributo if ganador == 0
    estadd scalar cmean = r(mean)
    estadd local ctl_age "`mark_age'"
    estadd local ctl_full "`mark_full'"
}

esttab itt_emp_noctl itt_emp_agectl itt_emp_ctl ///
       itt_mono_noctl itt_mono_agectl itt_mono_ctl ///
       using "$tables/table_extensive.tex", replace ///
    keep(ganador) se(%9.4f) b(%9.4f) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    nonumbers nomtitles noobs nor2 ///
    coeflabels(ganador "Ganador") ///
    prehead(`"\begin{table}[H]\centering"' ///
            `"\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}"' ///
            `"\caption{Extensive Margin: Employment Effects of PROCREAR Credit}"' ///
            `"\label{tab:extensive}"' ///
            `"\scriptsize"' ///
            `"\setlength{\tabcolsep}{4pt}"' ///
            `"\begin{tabular}{@{}l*{6}{c}@{}}"' ///
            `"\hline\hline"' ///
            `" & \multicolumn{3}{c}{Formal Emp} & \multicolumn{3}{c}{Monotributo} \\"' ///
            `"\cline{2-4}\cline{5-7}"' ///
            `" & (1) & (2) & (3) & (4) & (5) & (6) \\"' ///
            `"\hline"' ///
            `"\multicolumn{7}{l}{\textit{Panel A: ITT}} \\"') ///
    postfoot(`"[1em]"') ///
    substitute(\_ _) fragment

* --- Panel B: IV ---
eststo clear

foreach spec in "noctl" "agectl" "ctl" {
    if "`spec'" == "noctl" {
        local controls ""
        local mark_age ""
        local mark_full ""
    }
    if "`spec'" == "agectl" {
        local controls "edad"
        local mark_age "\checkmark"
        local mark_full ""
    }
    if "`spec'" == "ctl" {
        local controls "edad pre_employed pre_wage mujer"
        local mark_age "\checkmark"
        local mark_full "\checkmark"
    }

    eststo iv_emp_`spec': ivreghdfe employed `controls' ///
        (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
    quietly sum employed if ganador == 0
    estadd scalar cmean = r(mean)
    estadd scalar fs_F = e(widstat)
    estadd local ctl_age "`mark_age'"
    estadd local ctl_full "`mark_full'"

    eststo iv_mono_`spec': ivreghdfe is_monotributo `controls' ///
        (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
    quietly sum is_monotributo if ganador == 0
    estadd scalar cmean = r(mean)
    estadd scalar fs_F = e(widstat)
    estadd local ctl_age "`mark_age'"
    estadd local ctl_full "`mark_full'"
}

esttab iv_emp_noctl iv_emp_agectl iv_emp_ctl ///
       iv_mono_noctl iv_mono_agectl iv_mono_ctl ///
       using "$tables/table_extensive.tex", append ///
    keep(receptor) se(%9.4f) b(%9.4f) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    nonumbers nomtitles ///
    coeflabels(receptor "Receptor") ///
    prehead(`"\multicolumn{7}{l}{\textit{Panel B: IV / 2SLS}} \\"') ///
    prefoot(`"\hline"') ///
    stats(cmean fs_F N ctl_age ctl_full, ///
          labels("Control mean" "First-stage F" "Observations" ///
                 "Age only" "All controls") ///
          fmt(%9.3f %9.1f %9.0fc %s %s)) ///
    postfoot(`"\hline\hline"' ///
             `"\multicolumn{7}{p{0.95\textwidth}}{\scriptsize 2SLS. Instrument: ganador. Cols (1),(4): no controls. (2),(5): age only. (3),(6): all controls (add pre-employed, pre-wage, mujer). SE clustered at person level. Sorteo FE absorbed.}\\"' ///
             `"\multicolumn{7}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}"' ///
             `"\end{tabular}"' ///
             `"\end{table}"') ///
    substitute(\_ _) fragment

di as text "  table_extensive.tex saved (paper Section 5.1)"


/*==============================================================================
  STEP 5b: NEW TABLE — Share of months employed in post-`k_months' window

  table_emp_share_`k_label'.tex
  3 cols (noctl, agectl, ctl) — IV only
==============================================================================*/

di as text _n "=== STEP 5b: Table for emp_share_`k_label' (IV) ===" _n

use "$temp/cross_section_v2.dta", clear

eststo clear

foreach spec in "noctl" "agectl" "ctl" {
    if "`spec'" == "noctl" {
        local controls ""
        local mark_age ""
        local mark_full ""
    }
    if "`spec'" == "agectl" {
        local controls "edad"
        local mark_age "\checkmark"
        local mark_full ""
    }
    if "`spec'" == "ctl" {
        local controls "edad pre_employed pre_wage mujer"
        local mark_age "\checkmark"
        local mark_full "\checkmark"
    }

    eststo iv_emp`k_months'_`spec': ivreghdfe emp_share_`k_label' `controls' ///
        (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
    quietly sum emp_share_`k_label' if ganador == 0
    estadd scalar cmean = r(mean)
    estadd scalar fs_F = e(widstat)
    estadd local ctl_age "`mark_age'"
    estadd local ctl_full "`mark_full'"
}

esttab iv_emp`k_months'_noctl iv_emp`k_months'_agectl iv_emp`k_months'_ctl ///
       using "$tables/table_emp_share_`k_label'.tex", replace ///
    keep(receptor) se(%9.4f) b(%9.4f) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    nonumbers nomtitles ///
    coeflabels(receptor "Receptor") ///
    prehead(`"\begin{table}[H]\centering"' ///
            `"\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}"' ///
            `"\caption{Share of Months Employed in Post-`k_months' Window}"' ///
            `"\label{tab:emp_share_`k_label'}"' ///
            `"\scriptsize"' ///
            `"\begin{tabular}{l*{3}{c}}"' ///
            `"\hline\hline"' ///
            `" & (1) & (2) & (3) \\"' ///
            `"\hline"') ///
    prefoot(`"\hline"') ///
    stats(cmean fs_F N ctl_age ctl_full, ///
          labels("Control mean" "First-stage F" "Observations" ///
                 "Age only" "All controls") ///
          fmt(%9.4f %9.1f %9.0fc %s %s)) ///
    postfoot(`"\hline\hline"' ///
             `"\multicolumn{4}{p{0.85\textwidth}}{\scriptsize 2SLS. Instrument: ganador. Outcome: share of months employed in window [fecha\_sorteo + `k_months', Dec 2025]. (1): no controls. (2): age only. (3): all controls (add pre-employed, pre-wage, mujer). SE clustered at person level. Sorteo FE absorbed.}\\"' ///
             `"\multicolumn{4}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}"' ///
             `"\end{tabular}"' ///
             `"\end{table}"') ///
    substitute(\_ _) fragment

di as text "  table_emp_share_`k_label'.tex saved"


/*==============================================================================
  STEP 5c: GENDER HETEROGENEITY — Interaction IV with sorteo × mujer FE

  For each outcome y, estimate one IV regression with mujer interacted with
  the (instrumented) treatment AND with edad. FE absorbs sorteo × mujer
  (gender-specific sorteo intercepts), which makes this specification
  numerically equivalent to subgroup IV (sample split by mujer).

    ivreghdfe y edad muj_x_edad ///
        (receptor muj_x_rec = ganador muj_x_gan) [if samp], ///
        absorb(sorteo_fe_g) cluster(id_anon)

  Extract:
    β_M = coef on receptor          (LATE for men, mujer = 0)
    δ   = coef on muj_x_rec         (differential effect, W − M)
    β_W = β_M + δ via lincom        (LATE for women)
    p-val(δ = 0) tests H0: β_M = β_W (asymptotic normal)

  Sample restriction: ALL outcomes conditioned on pre_employed == 1
  (retention margin among the formally pre-employed).

  Note: with shared sorteo_fe instead of sorteo × mujer, this model imposes
  equal sorteo levels for both genders — a restriction the data violates
  strongly. See session log 2026-05-14 for the diagnostic.

  Output: table_het_gender.tex
==============================================================================*/

di as text _n "=== STEP 5c: Gender heterogeneity (interaction IV, sorteo × mujer FE, 3 specs) ===" _n

use "$temp/cross_section_v2.dta", clear

* --- Interaction variables (mujer × everything) ---
gen muj_x_rec          = mujer * receptor
gen muj_x_gan          = mujer * ganador
gen muj_x_edad         = mujer * edad
gen muj_x_pre_employed = mujer * pre_employed
gen muj_x_pre_wage     = mujer * pre_wage

* --- Combined sorteo × género FE ---
egen sorteo_fe_g = group(sorteo_fe mujer)

local outcomes "employed is_monotributo emp_share_`k_label'"
local n_out = wordcount("`outcomes'")

* --- Open LaTeX table ---
capture file close fh
file open fh using "$tables/table_het_gender.tex", write replace

file write fh "\begin{table}[H]\centering" _n
file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
file write fh "\caption{Heterogeneity by Gender: IV Estimates from Fully Interacted Model}" _n
file write fh "\label{tab:het_gender}" _n
file write fh "\scriptsize" _n
file write fh "\setlength{\tabcolsep}{4pt}" _n
file write fh "\begin{tabular}{@{}lccc@{}}" _n
file write fh "\hline\hline" _n
file write fh " & Formal Emp & Self-employed & Emp Share (`k_months'm+) \\" _n
file write fh " & (1) & (2) & (3) \\" _n

* --- Outer loop: 3 specs as panels ---
*     All outcomes conditioned on pre_employed == 1. Spec C drops
*     pre_employed and muj_x_pre_employed (constant within sample).
foreach spec in "noctl" "agectl" "ctl" {
    if "`spec'" == "noctl" {
        local ctl_use ""
        local panel_label "Panel A: No Controls"
    }
    else if "`spec'" == "agectl" {
        local ctl_use "edad muj_x_edad"
        local panel_label "Panel B: Age Only"
    }
    else if "`spec'" == "ctl" {
        local ctl_use "edad pre_wage muj_x_edad muj_x_pre_wage"
        local panel_label "Panel C: Full Controls"
    }

    di as text _n(2) "===== SPEC: `spec' =====" _n

    * --- Inner loop: run 3 regressions for this spec ---
    *     All restricted to pre_employed == 1 (retention margin).
    forvalues j = 1/`n_out' {
        local outc : word `j' of `outcomes'

        local samp_cond "pre_employed == 1"
        local reg_if   "if `samp_cond'"
        local cm_M_if  "if ganador == 0 & mujer == 0 & `samp_cond'"
        local cm_W_if  "if ganador == 0 & mujer == 1 & `samp_cond'"

        di as text _n "--- Outcome (`j'/`n_out'): `outc' `reg_if' ---"

        ivreghdfe `outc' `ctl_use' ///
            (receptor muj_x_rec = ganador muj_x_gan) `reg_if', ///
            absorb(sorteo_fe_g) cluster(id_anon)

        local b_M_`j'     = _b[receptor]
        local se_M_`j'    = _se[receptor]
        local b_diff_`j'  = _b[muj_x_rec]
        local se_diff_`j' = _se[muj_x_rec]
        local n_`j'       = e(N)
        local fs_F_`j'    = e(widstat)

        lincom receptor + muj_x_rec
        local b_W_`j'  = r(estimate)
        local se_W_`j' = r(se)

        local t_diff = abs(`b_diff_`j''/`se_diff_`j'')
        local p_diff_`j' = 2 * (1 - normal(`t_diff'))

        quietly sum `outc' `cm_M_if'
        local cm_M_`j' = r(mean)
        quietly sum `outc' `cm_W_if'
        local cm_W_`j' = r(mean)
    }

    * --- Write panel header + data rows ---
    file write fh "\hline" _n
    file write fh "\multicolumn{4}{l}{\textit{`panel_label'}} \\" _n
    file write fh "\hline" _n

    * β_M row
    file write fh "\(\beta_M\) (Men)"
    forvalues j = 1/`n_out' {
        local b : display %9.4f `b_M_`j''
        local t = abs(`b_M_`j''/`se_M_`j'')
        if `t' > 2.576      local s "\sym{***}"
        else if `t' > 1.960 local s "\sym{**}"
        else if `t' > 1.645 local s "\sym{*}"
        else                local s ""
        file write fh " & `b'`s'"
    }
    file write fh " \\" _n

    file write fh "    "
    forvalues j = 1/`n_out' {
        local se : display %9.4f `se_M_`j''
        file write fh " & (`se')"
    }
    file write fh " \\[0.2em]" _n

    * β_W row
    file write fh "\(\beta_W\) (Women)"
    forvalues j = 1/`n_out' {
        local b : display %9.4f `b_W_`j''
        local t = abs(`b_W_`j''/`se_W_`j'')
        if `t' > 2.576      local s "\sym{***}"
        else if `t' > 1.960 local s "\sym{**}"
        else if `t' > 1.645 local s "\sym{*}"
        else                local s ""
        file write fh " & `b'`s'"
    }
    file write fh " \\" _n

    file write fh "    "
    forvalues j = 1/`n_out' {
        local se : display %9.4f `se_W_`j''
        file write fh " & (`se')"
    }
    file write fh " \\[0.2em]" _n

    * δ row
    file write fh "\(\delta = \beta_W - \beta_M\)"
    forvalues j = 1/`n_out' {
        local b : display %9.4f `b_diff_`j''
        local t = abs(`b_diff_`j''/`se_diff_`j'')
        if `t' > 2.576      local s "\sym{***}"
        else if `t' > 1.960 local s "\sym{**}"
        else if `t' > 1.645 local s "\sym{*}"
        else                local s ""
        file write fh " & `b'`s'"
    }
    file write fh " \\" _n

    file write fh "    "
    forvalues j = 1/`n_out' {
        local se : display %9.4f `se_diff_`j''
        file write fh " & (`se')"
    }
    file write fh " \\" _n

    * p-val row
    file write fh "p-val (H\(_0\): \(\delta = 0\))"
    forvalues j = 1/`n_out' {
        local p : display %5.3f `p_diff_`j''
        file write fh " & `p'"
    }
    file write fh " \\" _n

    * F-stat row
    file write fh "First-stage F (joint)"
    forvalues j = 1/`n_out' {
        local f : display %9.1f `fs_F_`j''
        file write fh " & `f'"
    }
    file write fh " \\" _n

    * N row
    file write fh "Observations"
    forvalues j = 1/`n_out' {
        local n : display %12.0fc `n_`j''
        file write fh " & `=strtrim("`n'")'"
    }
    file write fh " \\" _n
}

* --- Control means (spec-independent) at bottom ---
file write fh "\hline" _n

file write fh "Control mean (Men)"
forvalues j = 1/`n_out' {
    local cm : display %5.3f `cm_M_`j''
    file write fh " & `cm'"
}
file write fh " \\" _n

file write fh "Control mean (Women)"
forvalues j = 1/`n_out' {
    local cm : display %5.3f `cm_W_`j''
    file write fh " & `cm'"
}
file write fh " \\" _n

* --- Footer ---
file write fh "\hline\hline" _n
file write fh "\multicolumn{4}{p{0.95\textwidth}}{\scriptsize IV/2SLS, fully-interacted regression per outcome with sorteo \(\times\) female fixed effects absorbed (gender-specific sorteo intercepts; equivalent to subgroup IV sample-split by female). Endogenous: \emph{recipient}, \emph{female}\(\times\)\emph{recipient}. Instruments: \emph{winner}, \emph{female}\(\times\)\emph{winner}. \textbf{All regressions restricted to \emph{pre\_employed = 1}} (retention margin among the formally pre-employed). Controls in Panel B add \emph{age} and \emph{female}\(\times\)\emph{age}; in Panel C add \emph{pre\_wage} and \emph{female}\(\times\)\emph{pre\_wage} (\emph{pre\_employed} omitted as it is constant within sample). \(\beta_M\) is the coefficient on \emph{recipient}; \(\delta\) is the coefficient on \emph{female}\(\times\)\emph{recipient}; \(\beta_W = \beta_M + \delta\) (via \emph{lincom}). p-value tests H\(_0\): \(\delta = 0\) (asymptotic normal, two-sided). Column (3) outcome: share of months employed in [lottery date + `k_months', Dec 2025]. First-stage F is the joint Kleibergen-Paap rk Wald statistic. SE clustered at person level (in parentheses).}" _n
file write fh "\multicolumn{4}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}" _n
file write fh "\end{tabular}" _n
file write fh "\end{table}" _n

file close fh

di as text "  table_het_gender.tex saved"


/*==============================================================================
  STEP 5d: COMBINED MAIN TABLE — Pooled IV + Gender heterogeneity

  Two output tables (3 outcomes, order: Formal Emp / Emp Share / Mono):

    table_main.tex       — 2 specs as columns (no ctl, age)        (paper body)
    table_main_full.tex  — 1 column per outcome (full controls)    (appendix)

  Rows: Receptor (pooled), β_M (Men), β_W (Women), p-val (H₀: δ=0).
  Diagnostics: Control mean (pooled), N (pooled), N (pre-emp), F-stat,
  Controls for age (✓ in the agectl column for the main table).

  Pooled and gender use DIFFERENT samples (pooled = full; gender = pre-emp).
  No δ row reported (per Franco's instruction).
==============================================================================*/

di as text _n "=== STEP 5d: Combined main table (pooled + gender) ===" _n

use "$temp/cross_section_v2.dta", clear

* --- Re-generate interaction vars + sorteo_fe_g (lost on `use ... clear`) ---
cap drop muj_x_rec muj_x_gan muj_x_edad muj_x_pre_wage sorteo_fe_g
gen muj_x_rec      = mujer * receptor
gen muj_x_gan      = mujer * ganador
gen muj_x_edad     = mujer * edad
gen muj_x_pre_wage = mujer * pre_wage
egen sorteo_fe_g = group(sorteo_fe mujer)

* --- Outcome list ---
local outcomes "employed emp_share_`k_label' is_monotributo"

foreach table_kind in "main" "full" {
    if "`table_kind'" == "main" {
        local specs_to_run "noctl agectl"
        local n_specs = 2
        local out_file "$tables/table_main.tex"
        local table_caption "Main Effects and Gender Heterogeneity"
        local table_label "tab:main"
    }
    else {
        local specs_to_run "ctl"
        local n_specs = 1
        local out_file "$tables/table_main_full.tex"
        local table_caption "Main Effects and Gender Heterogeneity (Full Controls)"
        local table_label "tab:main_full"
    }

    * --- Run all regressions, store in locals (b_pool_<j>_<k>, etc.) ---
    forvalues j = 1/3 {
        local outc : word `j' of `outcomes'

        local k = 0
        foreach spec in `specs_to_run' {
            local ++k

            if "`spec'" == "noctl" {
                local ctl_pool   ""
                local ctl_gender ""
            }
            else if "`spec'" == "agectl" {
                local ctl_pool   "edad"
                local ctl_gender "edad muj_x_edad"
            }
            else if "`spec'" == "ctl" {
                local ctl_pool   "edad pre_employed pre_wage mujer"
                local ctl_gender "edad pre_wage muj_x_edad muj_x_pre_wage"
            }

            di as text _n(2) "===== Outcome=`outc'  Spec=`spec' =====" _n

            * Pooled IV: full sample
            ivreghdfe `outc' `ctl_pool' (receptor = ganador), ///
                absorb(sorteo_fe) cluster(id_anon)
            local b_pool_`j'_`k'  = _b[receptor]
            local se_pool_`j'_`k' = _se[receptor]
            local n_pool_`j'_`k'  = e(N)
            local F_pool_`j'_`k'  = e(widstat)
            quietly sum `outc' if ganador == 0
            local cm_pool_`j'_`k' = r(mean)

            * Gender IV: restricted to pre_employed == 1
            ivreghdfe `outc' `ctl_gender' ///
                (receptor muj_x_rec = ganador muj_x_gan) if pre_employed == 1, ///
                absorb(sorteo_fe_g) cluster(id_anon)
            local b_M_`j'_`k'  = _b[receptor]
            local se_M_`j'_`k' = _se[receptor]
            local b_d_`j'_`k'  = _b[muj_x_rec]
            local se_d_`j'_`k' = _se[muj_x_rec]
            local n_gen_`j'_`k' = e(N)

            lincom receptor + muj_x_rec
            local b_W_`j'_`k'  = r(estimate)
            local se_W_`j'_`k' = r(se)

            local t_d = abs(`b_d_`j'_`k''/`se_d_`j'_`k'')
            local p_d_`j'_`k' = 2 * (1 - normal(`t_d'))
        }
    }

    * --- Open file and write header ---
    capture file close fh
    file open fh using "`out_file'", write replace

    file write fh "\begin{table}[H]\centering" _n
    file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
    file write fh "\caption{`table_caption'}" _n
    file write fh "\label{`table_label'}" _n
    file write fh "\scriptsize" _n
    file write fh "\setlength{\tabcolsep}{0pt}" _n

    if "`table_kind'" == "main" {
        file write fh "\begin{tabular}{@{}l*{6}{>{\centering\arraybackslash}p{0.115\textwidth}}@{}}" _n
        file write fh "\hline\hline" _n
        file write fh " & \multicolumn{2}{c}{Formal Emp} & \multicolumn{2}{c}{Emp Share (`k_months'm+)} & \multicolumn{2}{c}{Self-employed} \\" _n
        file write fh "\cline{2-3}\cline{4-5}\cline{6-7}" _n
        file write fh " & (1) & (2) & (3) & (4) & (5) & (6) \\" _n
    }
    else {
        file write fh "\begin{tabular}{@{}l*{3}{>{\centering\arraybackslash}p{0.18\textwidth}}@{}}" _n
        file write fh "\hline\hline" _n
        file write fh " & Formal Emp & Emp Share (`k_months'm+) & Self-employed \\" _n
        file write fh " & (1) & (2) & (3) \\" _n
    }
    file write fh "\hline" _n

    * --- Row: Receptor (pooled) ---
    file write fh "Recipient (pooled)"
    forvalues j = 1/3 {
        forvalues k = 1/`n_specs' {
            local b : display %9.4f `b_pool_`j'_`k''
            local t = abs(`b_pool_`j'_`k''/`se_pool_`j'_`k'')
            if `t' > 2.576      local s "\sym{***}"
            else if `t' > 1.960 local s "\sym{**}"
            else if `t' > 1.645 local s "\sym{*}"
            else                local s ""
            file write fh " & `b'`s'"
        }
    }
    file write fh " \\" _n
    file write fh "    "
    forvalues j = 1/3 {
        forvalues k = 1/`n_specs' {
            local se : display %9.4f `se_pool_`j'_`k''
            file write fh " & (`se')"
        }
    }
    file write fh " \\[0.3em]" _n

    * --- Row: β_M ---
    file write fh "\(\beta_M\) (Men)"
    forvalues j = 1/3 {
        forvalues k = 1/`n_specs' {
            local b : display %9.4f `b_M_`j'_`k''
            local t = abs(`b_M_`j'_`k''/`se_M_`j'_`k'')
            if `t' > 2.576      local s "\sym{***}"
            else if `t' > 1.960 local s "\sym{**}"
            else if `t' > 1.645 local s "\sym{*}"
            else                local s ""
            file write fh " & `b'`s'"
        }
    }
    file write fh " \\" _n
    file write fh "    "
    forvalues j = 1/3 {
        forvalues k = 1/`n_specs' {
            local se : display %9.4f `se_M_`j'_`k''
            file write fh " & (`se')"
        }
    }
    file write fh " \\[0.2em]" _n

    * --- Row: β_W ---
    file write fh "\(\beta_W\) (Women)"
    forvalues j = 1/3 {
        forvalues k = 1/`n_specs' {
            local b : display %9.4f `b_W_`j'_`k''
            local t = abs(`b_W_`j'_`k''/`se_W_`j'_`k'')
            if `t' > 2.576      local s "\sym{***}"
            else if `t' > 1.960 local s "\sym{**}"
            else if `t' > 1.645 local s "\sym{*}"
            else                local s ""
            file write fh " & `b'`s'"
        }
    }
    file write fh " \\" _n
    file write fh "    "
    forvalues j = 1/3 {
        forvalues k = 1/`n_specs' {
            local se : display %9.4f `se_W_`j'_`k''
            file write fh " & (`se')"
        }
    }
    file write fh " \\[0.2em]" _n

    * --- Row: p-val ---
    file write fh "p-val (H\(_0\): \(\delta = 0\))"
    forvalues j = 1/3 {
        forvalues k = 1/`n_specs' {
            local p : display %5.3f `p_d_`j'_`k''
            file write fh " & `p'"
        }
    }
    file write fh " \\" _n

    file write fh "\hline" _n

    * --- Diagnostics ---
    file write fh "Control mean (pooled)"
    forvalues j = 1/3 {
        forvalues k = 1/`n_specs' {
            local cm : display %5.3f `cm_pool_`j'_`k''
            file write fh " & `cm'"
        }
    }
    file write fh " \\" _n

    file write fh "N (pooled)"
    forvalues j = 1/3 {
        forvalues k = 1/`n_specs' {
            local n : display %12.0fc `n_pool_`j'_`k''
            file write fh " & `=strtrim("`n'")'"
        }
    }
    file write fh " \\" _n

    file write fh "N (pre-emp, gender)"
    forvalues j = 1/3 {
        forvalues k = 1/`n_specs' {
            local n : display %12.0fc `n_gen_`j'_`k''
            file write fh " & `=strtrim("`n'")'"
        }
    }
    file write fh " \\" _n

    file write fh "First-stage F (pooled)"
    forvalues j = 1/3 {
        forvalues k = 1/`n_specs' {
            local f : display %9.1f `F_pool_`j'_`k''
            file write fh " & `f'"
        }
    }
    file write fh " \\" _n

    if "`table_kind'" == "main" {
        * --- Row: Controls for age (only in the agectl columns) ---
        file write fh "Controls for age"
        forvalues j = 1/3 {
            forvalues k = 1/`n_specs' {
                local spec_name : word `k' of `specs_to_run'
                if "`spec_name'" == "agectl" {
                    file write fh " & \checkmark"
                }
                else {
                    file write fh " &"
                }
            }
        }
        file write fh " \\" _n
    }

    * --- Footer ---
    file write fh "\hline\hline" _n
    file write fh "\end{tabular}" _n
    file write fh "\par\smallskip" _n
    file write fh "\begin{minipage}{0.95\textwidth}" _n
    file write fh "\scriptsize" _n
    if "`table_kind'" == "main" {
        file write fh "IV/2SLS. Instrument: \emph{winner}. SE clustered at person level (in parentheses). \textbf{Recipient (pooled)} estimated on the FULL sample with lottery FE; \(\beta_M\), \(\beta_W\) estimated on the \emph{pre\_employed == 1} sub-sample with lottery \(\times\) female FE (interaction IV), \(\beta_W = \beta_M + \delta\) via \emph{lincom}. p-value tests H\(_0\): \(\delta = 0\) (asymptotic normal, two-sided). Cols (2)/(4)/(6) add \emph{age} as control (and \emph{female}\(\times\)\emph{age} for gender rows). Columns (3)/(4) outcome: share of months employed in [lottery date + `k_months', Dec 2025].\\" _n
    }
    else {
        file write fh "IV/2SLS, full controls. Instrument: \emph{winner}. SE clustered at person level (in parentheses). \textbf{Recipient (pooled)} on the FULL sample with lottery FE and controls \emph{age, pre\_employed, pre\_wage, female}; \(\beta_M\), \(\beta_W\) on the \emph{pre\_employed == 1} sub-sample with lottery \(\times\) female FE and controls \emph{age, pre\_wage} and their \emph{female}\(\times\) interactions; \(\beta_W = \beta_M + \delta\) via \emph{lincom}. p-value tests H\(_0\): \(\delta = 0\). Column (2) outcome: share of months employed in [lottery date + `k_months', Dec 2025].\\" _n
    }
    file write fh "\sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)" _n
    file write fh "\end{minipage}" _n
    file write fh "\end{table}" _n

    file close fh

    di as text "  `out_file' saved"
}


/*==============================================================================
  STEP 6: HETEROGENEITY BY CREDIT TYPE — IV only (3 specs as panels)

  Single table: outcomes in columns, credit types in rows.
  Outcomes: Formal Emp, Monotributo, Emp Share (k+).
  IV/2SLS, 3 specs (no controls / age only / full). table_het_type.tex
==============================================================================*/

di as text _n "=== STEP 6: Heterogeneity by Credit Type (3 specs) ===" _n

use "$temp/cross_section_v2.dta", clear

capture file close fh
file open fh using "$tables/table_het_type.tex", write replace

file write fh "\begin{table}[H]\centering" _n
file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
file write fh "\caption{Heterogeneity by Credit Type: IV Estimates}" _n
file write fh "\label{tab:het_type}" _n
file write fh "\scriptsize" _n
file write fh "\setlength{\tabcolsep}{0pt}" _n
file write fh "\begin{tabular}{@{}l*{3}{>{\centering\arraybackslash}p{0.19\textwidth}}@{}}" _n
file write fh "\hline\hline" _n
file write fh " & Formal Emp & Self-employed & Emp Share (`k_months'm+) \\" _n
file write fh " & (1) & (2) & (3) \\" _n

foreach spec in "agectl" "ctl" {
    if "`spec'" == "agectl" {
        local ctl_use "edad"
        local panel_label "Panel A: Age Only"
    }
    else if "`spec'" == "ctl" {
        local ctl_use "edad pre_employed pre_wage mujer"
        local panel_label "Panel B: Full Controls"
    }

    di as text _n(2) "===== SPEC: `spec' =====" _n

    file write fh "\hline" _n
    file write fh "\multicolumn{4}{l}{\textit{`panel_label'}} \\" _n
    file write fh "\hline" _n

    local grp_num = 0
    foreach grp_name in "DU" "Construcci\'{o}n" "Lotes" {
        local ++grp_num

        ivreghdfe employed `ctl_use' (receptor = ganador) ///
            if tipo_grupo == `grp_num', absorb(sorteo_fe) cluster(id_anon)
        local b1 = _b[receptor]
        local se1 = _se[receptor]
        local n1 = e(N)
        quietly sum employed if ganador == 0 & tipo_grupo == `grp_num'
        local cm1 = r(mean)

        ivreghdfe is_monotributo `ctl_use' (receptor = ganador) ///
            if tipo_grupo == `grp_num', absorb(sorteo_fe) cluster(id_anon)
        local b2 = _b[receptor]
        local se2 = _se[receptor]
        quietly sum is_monotributo if ganador == 0 & tipo_grupo == `grp_num'
        local cm2 = r(mean)

        ivreghdfe emp_share_`k_label' `ctl_use' (receptor = ganador) ///
            if tipo_grupo == `grp_num', absorb(sorteo_fe) cluster(id_anon)
        local b3 = _b[receptor]
        local se3 = _se[receptor]
        quietly sum emp_share_`k_label' if ganador == 0 & tipo_grupo == `grp_num'
        local cm3 = r(mean)

        forvalues j = 1/3 {
            local t = abs(`b`j''/`se`j'')
            if `t' > 2.576      local star`j' "\sym{***}"
            else if `t' > 1.960 local star`j' "\sym{**}"
            else if `t' > 1.645 local star`j' "\sym{*}"
            else                local star`j' ""
            local b`j's: display %9.4f `b`j''
            local se`j's: display %9.4f `se`j''
            local cm`j's: display %5.3f `cm`j''
        }
        local n1s: display %12.0fc `n1'

        file write fh "`grp_name' & `b1s'`star1' & `b2s'`star2' & `b3s'`star3'\\" _n
        file write fh "       & (`se1s') & (`se2s') & (`se3s')\\" _n
        file write fh "       & [`cm1s'; N=`=strtrim("`n1s'")'] & [`cm2s'] & [`cm3s']\\" _n

        if `grp_num' < 3 file write fh "[0.3em]" _n
    }
}

file write fh "\hline\hline" _n
file write fh "\end{tabular}" _n
file write fh "\par\smallskip" _n
file write fh "\begin{minipage}{0.92\textwidth}" _n
file write fh "\scriptsize" _n
file write fh "IV/2SLS. Instrument: \emph{winner}. SE clustered at person level (in parentheses). Control means and N in brackets. Panel A adds \emph{age}; Panel B adds \emph{age, pre\_employed, pre\_wage, female}. Column (3) outcome: share of months employed in [lottery date + `k_months', Dec 2025]. Lottery FE absorbed.\\" _n
file write fh "\sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)" _n
file write fh "\end{minipage}" _n
file write fh "\end{table}" _n

file close fh

di as text "  table_het_type.tex saved"


/*==============================================================================
  STEP 7: HETEROGENEITY BY COHORT YEAR — IV only (3 specs as panels)

  Single table: outcomes in columns, cohort years in rows.
  Outcomes: Formal Emp, Monotributo, Emp Share (k+).
  IV/2SLS, 3 specs (no controls / age only / full). table_het_cohort.tex
==============================================================================*/

di as text _n "=== STEP 7: Heterogeneity by Cohort Year (3 specs) ===" _n

use "$temp/cross_section_v2.dta", clear

capture file close fh
file open fh using "$tables/table_het_cohort.tex", write replace

file write fh "\begin{table}[H]\centering" _n
file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
file write fh "\caption{Heterogeneity by Cohort Year: IV Estimates}" _n
file write fh "\label{tab:het_cohort}" _n
file write fh "\scriptsize" _n
file write fh "\setlength{\tabcolsep}{0pt}" _n
file write fh "\begin{tabular}{@{}l*{3}{>{\centering\arraybackslash}p{0.19\textwidth}}@{}}" _n
file write fh "\hline\hline" _n
file write fh " & Formal Emp & Self-employed & Emp Share (`k_months'm+) \\" _n
file write fh " & (1) & (2) & (3) \\" _n

foreach spec in "agectl" "ctl" {
    if "`spec'" == "agectl" {
        local ctl_use "edad"
        local panel_label "Panel A: Age Only"
    }
    else if "`spec'" == "ctl" {
        local ctl_use "edad pre_employed pre_wage mujer"
        local panel_label "Panel B: Full Controls"
    }

    di as text _n(2) "===== SPEC: `spec' =====" _n

    file write fh "\hline" _n
    file write fh "\multicolumn{4}{l}{\textit{`panel_label'}} \\" _n
    file write fh "\hline" _n

    forvalues y = 2020/2023 {

        ivreghdfe employed `ctl_use' (receptor = ganador) ///
            if cohort_year == `y', absorb(sorteo_fe) cluster(id_anon)
        local b1 = _b[receptor]
        local se1 = _se[receptor]
        local n1 = e(N)
        quietly sum employed if ganador == 0 & cohort_year == `y'
        local cm1 = r(mean)

        ivreghdfe is_monotributo `ctl_use' (receptor = ganador) ///
            if cohort_year == `y', absorb(sorteo_fe) cluster(id_anon)
        local b2 = _b[receptor]
        local se2 = _se[receptor]
        quietly sum is_monotributo if ganador == 0 & cohort_year == `y'
        local cm2 = r(mean)

        ivreghdfe emp_share_`k_label' `ctl_use' (receptor = ganador) ///
            if cohort_year == `y', absorb(sorteo_fe) cluster(id_anon)
        local b3 = _b[receptor]
        local se3 = _se[receptor]
        quietly sum emp_share_`k_label' if ganador == 0 & cohort_year == `y'
        local cm3 = r(mean)

        forvalues j = 1/3 {
            local t = abs(`b`j''/`se`j'')
            if `t' > 2.576      local star`j' "\sym{***}"
            else if `t' > 1.960 local star`j' "\sym{**}"
            else if `t' > 1.645 local star`j' "\sym{*}"
            else                local star`j' ""
            local b`j's: display %9.4f `b`j''
            local se`j's: display %9.4f `se`j''
            local cm`j's: display %5.3f `cm`j''
        }
        local n1s: display %12.0fc `n1'

        file write fh "`y'    & `b1s'`star1' & `b2s'`star2' & `b3s'`star3'\\" _n
        file write fh "       & (`se1s') & (`se2s') & (`se3s')\\" _n

        if `y' < 2023 file write fh "[0.3em]" _n
    }
}

file write fh "\hline\hline" _n
file write fh "\end{tabular}" _n
file write fh "\par\smallskip" _n
file write fh "\begin{minipage}{0.92\textwidth}" _n
file write fh "\scriptsize" _n
file write fh "IV/2SLS. Instrument: \emph{winner}. SE clustered at person level (in parentheses). Panel A adds \emph{age}; Panel B adds \emph{age, pre\_employed, pre\_wage, female}. Column (3) outcome: share of months employed in [lottery date + `k_months', Dec 2025]. Lottery FE absorbed.\\" _n
file write fh "\sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)" _n
file write fh "\end{minipage}" _n
file write fh "\end{table}" _n

file close fh

di as text "  table_het_cohort.tex saved"


/*==============================================================================
  STEP 8: HETEROGENEITY BY TYPE × COHORT YEAR — IV only (3 specs as panels)

  Rows: cohort years (2020–2023).
  Cols: 3 types × 2 outcomes (Formal Emp + Emp Share `k`+) = 6 columns.
  IV/2SLS, 3 specs (no controls / age only / full). table_het_type_cohort.tex
==============================================================================*/

di as text _n "=== STEP 8: Heterogeneity by Type × Cohort Year (3 specs) ===" _n

use "$temp/cross_section_v2.dta", clear

capture file close fh
file open fh using "$tables/table_het_type_cohort.tex", write replace

file write fh "\begin{table}[H]\centering" _n
file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
file write fh "\caption{Heterogeneity by Credit Type and Cohort Year: IV Estimates}" _n
file write fh "\label{tab:het_type_cohort}" _n
file write fh "\scriptsize" _n
file write fh "\setlength{\tabcolsep}{0pt}" _n
file write fh "\begin{tabular*}{0.95\textwidth}{@{\extracolsep{\fill}}lcccccc@{}}" _n
file write fh "\hline\hline" _n
file write fh " & \multicolumn{2}{c}{DU} & \multicolumn{2}{c}{Construction} & \multicolumn{2}{c}{Land} \\" _n
file write fh "\cline{2-3}\cline{4-5}\cline{6-7}" _n
file write fh " & Formal Emp & Emp Share & Formal Emp & Emp Share & Formal Emp & Emp Share \\" _n
file write fh " & (1) & (2) & (3) & (4) & (5) & (6) \\" _n

foreach spec in "agectl" "ctl" {
    if "`spec'" == "agectl" {
        local ctl_use "edad"
        local panel_label "Panel A: Age Only"
    }
    else if "`spec'" == "ctl" {
        local ctl_use "edad pre_employed pre_wage mujer"
        local panel_label "Panel B: Full Controls"
    }

    di as text _n(2) "===== SPEC: `spec' =====" _n

    file write fh "\hline" _n
    file write fh "\multicolumn{7}{l}{\textit{`panel_label'}} \\" _n
    file write fh "\hline" _n

    forvalues y = 2020/2023 {

        local grp_num = 0
        foreach grp in "du" "con" "lot" {
            local ++grp_num

            capture ivreghdfe employed `ctl_use' (receptor = ganador) ///
                if tipo_grupo == `grp_num' & cohort_year == `y', ///
                absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                local b_`grp'_e: display %9.4f _b[receptor]
                local se_`grp'_e: display %9.4f _se[receptor]
                local t = abs(_b[receptor]/_se[receptor])
                if `t' > 2.576      local star_`grp'_e "\sym{***}"
                else if `t' > 1.960 local star_`grp'_e "\sym{**}"
                else if `t' > 1.645 local star_`grp'_e "\sym{*}"
                else                local star_`grp'_e ""
                local ok_`grp'_e = 1
            }
            else local ok_`grp'_e = 0

            capture ivreghdfe emp_share_`k_label' `ctl_use' (receptor = ganador) ///
                if tipo_grupo == `grp_num' & cohort_year == `y', ///
                absorb(sorteo_fe) cluster(id_anon)
            if _rc == 0 {
                local b_`grp'_s: display %9.4f _b[receptor]
                local se_`grp'_s: display %9.4f _se[receptor]
                local t = abs(_b[receptor]/_se[receptor])
                if `t' > 2.576      local star_`grp'_s "\sym{***}"
                else if `t' > 1.960 local star_`grp'_s "\sym{**}"
                else if `t' > 1.645 local star_`grp'_s "\sym{*}"
                else                local star_`grp'_s ""
                local ok_`grp'_s = 1
            }
            else local ok_`grp'_s = 0
        }

        file write fh "`y'"
        foreach grp in "du" "con" "lot" {
            foreach oc in "e" "s" {
                if `ok_`grp'_`oc'' == 1 {
                    file write fh " & `b_`grp'_`oc''`star_`grp'_`oc''"
                }
                else {
                    file write fh " &"
                }
            }
        }
        file write fh "\\" _n

        file write fh "    "
        foreach grp in "du" "con" "lot" {
            foreach oc in "e" "s" {
                if `ok_`grp'_`oc'' == 1 {
                    file write fh " & (`se_`grp'_`oc'')"
                }
                else {
                    file write fh " &"
                }
            }
        }
        file write fh "\\" _n

        if `y' < 2023 file write fh "[0.2em]" _n
    }
}

file write fh "\hline\hline" _n
file write fh "\end{tabular*}" _n
file write fh "\par\smallskip" _n
file write fh "\begin{minipage}{0.90\textwidth}" _n
file write fh "\scriptsize" _n
file write fh "IV/2SLS. Instrument: \emph{winner}. SE clustered at person level (in parentheses). Panel A adds \emph{age}; Panel B adds \emph{age, pre\_employed, pre\_wage, female}. Emp Share is the share of months employed in [lottery date + `k_months', Dec 2025]. Lottery FE absorbed. Empty cells indicate the regression did not converge or had no observations.\\" _n
file write fh "\sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)" _n
file write fh "\end{minipage}" _n
file write fh "\end{table}" _n

file close fh

di as text "  table_het_type_cohort.tex saved"


/*==============================================================================
  SUMMARY
==============================================================================*/

di as text _n(3) "========================================"
di as text       "  paper_labor_outcomes.do — Complete"
di as text       "========================================"
di as text _n "Specification: person × sorteo, reghdfe, cluster(id_anon)"
di as text "sorteo_fe = group(fecha_sorteo, tipo, desarrollo, tipologia, cupo)"
di as text "3 control specs: (1) none, (2) age only, (3) all controls (edad+pre-emp+pre-wage+mujer)"
di as text _n "Tables saved to: $tables/"
di as text _n "  PAPER TABLES (directly \\input'd):"
di as text "    table_extensive.tex            — Section 5.1 (9 cols)"
di as text "    table_emp_share_`k_label'.tex     — Section 5.2 (post-`k_months'm emp share)"
di as text "    table_het_gender.tex           — gender heterogeneity (interaction IV)"
di as text "    table_het_type.tex             — heterogeneity by credit type (IV)"
di as text "    table_het_cohort.tex           — heterogeneity by cohort year (IV)"
di as text "    table_het_type_cohort.tex      — heterogeneity by type × cohort (IV)"
