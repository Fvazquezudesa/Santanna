/*==============================================================================
  PROCREAR — Paper Tables: Fertility / Children Outcomes

  THIS SCRIPT GENERATES THE OFFICIAL PAPER TABLES FOR FERTILITY OUTCOMES.

  Specification:
    - Unit of observation: person x sorteo inscription
    - Sorteo FE: group(fecha_sorteo, tipo, desarrollourbanistico, tipologia, cupo)
    - Treatment: ganador (ITT) / receptor instrumented by ganador (IV)
    - SE clustered at the person level (id_anon)
    - Control specifications (fertility-tailored, dropping pre_employed/
      pre_wage/mujer used in labor/bcra in favor of pre-treatment fertility
      controls):
        Main table       — 4 specs: noctl / edad / edad+had_kid_pre / edad+n_kids_pre
        All other tables — 3 specs: noctl / edad / edad+n_kids_pre

  SELF-CONTAINED: builds its own upstream artifacts (deflator, sorteo
  cross-section, SIPA person-month panel, cumulative-children panel) from
  raw data in $data/. Does NOT depend on any other paper script.

  Caveat: STEP 0 overwrites the standard $temp files (deflator.dta,
  sorteo_sample_hijos.dta, sipa_panel.dta, proc_kids_panel.dta).

  Cleanup: STEP 7 erases all $temp intermediates EXCEPT
  cross_section_hijos_full.dta (the analysis dataset).

  ===========================================================================
  OUTPUT -> PAPER MAPPING
  ===========================================================================

  Table file                          Paper location
  -------------------------------------  ------------------------------------
  table_hijos_balance.tex             Balance test (pre-sorteo children)
  table_hijos.tex                     Main: 4 specs x 2 outcomes (8 cols)
  table_hijos_het_year.tex            Cohort het: 3 specs x 4 years (12 cols)
  type_du_hijos.tex                   By type — DU (6 cols)
  type_construccion_hijos.tex         By type — Construccion (6 cols)
  type_lotes_hijos.tex                By type — Lotes (6 cols)
  table_hijos_type_year.tex           Compact type x year (3 x 4)

  ===========================================================================
  OUTLINE
  ===========================================================================

  STEP 0: Self-contained upstream build (deflator + sorteo + SIPA + kids panel)
  STEP 1: Build cross-section (merge children panel + SIPA pretreatment)
  STEP 2: Balance test                 -> table_hijos_balance.tex
  STEP 3: Main (4 specs x 2 outcomes)  -> table_hijos.tex (8 cols)
  STEP 4: Heterogeneity by cohort year -> table_hijos_het_year.tex (12 cols)
  STEP 5: By credit type               -> type_{du,construccion,lotes}_hijos.tex
  STEP 6: Compact type x year          -> table_hijos_type_year.tex (3 x 4)
  STEP 7: Cleanup intermediates

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
* ssc install ivreghdfe, replace


/*==============================================================================
  STEP 0: SELF-CONTAINED UPSTREAM BUILD
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

replace desarrollourbanistico = 0 if desarrollourbanistico == .
replace tipologia              = 0 if tipologia == .
replace cupo                   = 0 if cupo == .

egen sorteo_fe = group(fecha_sorteo tipo desarrollourbanistico tipologia cupo)

gen tipo_grupo = .
replace tipo_grupo = 1 if tipo == 5                              // DU
replace tipo_grupo = 2 if inlist(tipo, 2, 3, 4)                  // Construccion
replace tipo_grupo = 3 if inlist(tipo, 6)                        // Lotes
replace tipo_grupo = 4 if inlist(tipo, 1, 8, 9, 10, 11, 12, 13)  // Refaccion
label define tipo_grupo_lbl 1 "DU" 2 "Construccion" 3 "Lotes" 4 "Refaccion", replace
label values tipo_grupo tipo_grupo_lbl
drop if tipo_grupo == 4

bys sorteo_fe: egen _winrate = mean(ganador)
drop if _winrate == 0 | _winrate == 1
drop _winrate

gen sorteo_month = mofd(fecha_sorteo)
format sorteo_month %tm
gen cohort_year = year(fecha_sorteo)

drop edad
rename edad_sorteo edad
label variable edad "Edad (anos) al dia del sorteo (de Data_sorteos)"
cap drop fnacimiento

destring cuil, gen(cuil_num) force
label variable cuil_num "CUIL (numeric, for kids panel merge)"

di as text "    Sorteo sample saved: N = " _N
save "$temp/sorteo_sample_hijos.dta", replace


/*--- 0.3 SIPA PERSON-MONTH PANEL --------------------------------------------*/
di as text _n "--- 0.3 SIPA person-month panel ---"

preserve
use "$temp/sorteo_sample_hijos.dta", clear
keep id_anon
duplicates drop
save "$temp/_person_list.dta", replace
restore

use "$data/Data_SIPA.dta", clear
merge m:1 id_anon using "$temp/_person_list.dta", keep(match) nogenerate

gen int _y = floor(mes / 100)
gen int _m = mod(mes, 100)
gen periodo_month = ym(_y, _m)
format periodo_month %tm
drop _y _m

gen double wage_desest = remuneracion
replace wage_desest = remuneracion - sac if !missing(sac)
replace wage_desest = 0 if wage_desest < 0 & !missing(wage_desest)

merge m:1 periodo_month using "$temp/deflator.dta", keep(master match) nogenerate
gen double real_wage = wage_desest / deflator
replace real_wage = 0 if wage_desest == .

collapse (sum) total_wage = real_wage, by(id_anon periodo_month)
gen byte employed = 1

di as text "    SIPA panel saved: N = " _N
save "$temp/sipa_panel.dta", replace
erase "$temp/_person_list.dta"


/*--- 0.4 CUMULATIVE-CHILDREN PANEL ------------------------------------------*/
di as text _n "--- 0.4 Cumulative-children panel ---"

local year_start = 2000
local year_end   = 2025

use "$data/proc_as_parents.dta", clear
sort cuil year_birth
by cuil: gen byte k = _n
keep cuil k year_birth
reshape wide year_birth, i(cuil) j(k)
di as text "    Parents (unique cuils): " _N
save "$temp/_proc_kids_wide.dta", replace

use "$temp/sorteo_sample_hijos.dta", clear
keep cuil_num
duplicates drop cuil_num, force
rename cuil_num cuil
di as text "    Unique aplicant cuils: " _N

merge 1:1 cuil using "$temp/_proc_kids_wide.dta"
drop _merge
erase "$temp/_proc_kids_wide.dta"

local n_years = `year_end' - `year_start' + 1
expand `n_years'
bysort cuil: gen int year = `year_start' + _n - 1
di as text "    Panel size: " _N

gen byte n_kids = 0
forvalues j = 1/6 {
    capture confirm variable year_birth`j'
    if !_rc {
        replace n_kids = n_kids + 1 if !missing(year_birth`j') & year_birth`j' <= year
    }
}
label variable n_kids "Cumulative # children born to cuil by end of year"
label variable year   "Calendar year"

keep cuil year n_kids
order cuil year n_kids
sort cuil year
di as text "    proc_kids_panel saved: " _N " rows (range 0-6)"
save "$temp/proc_kids_panel.dta", replace


/*==============================================================================
  STEP 1: BUILD CROSS-SECTION
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 1: Build cross-section"
di as text       "==================================================================="

use "$temp/sorteo_sample_hijos.dta", clear

* --- 1a. Merge n_kids at year = cohort_year - 1 -------------------------------
preserve
use "$temp/proc_kids_panel.dta", clear
rename cuil cuil_num
rename year cohort_year_minus_1
rename n_kids n_kids_pre
save "$temp/_panel_pre.dta", replace
restore

gen cohort_year_minus_1 = cohort_year - 1
merge m:1 cuil_num cohort_year_minus_1 using "$temp/_panel_pre.dta", ///
    keep(master match) nogenerate
replace n_kids_pre = 0 if n_kids_pre == .
drop cohort_year_minus_1
erase "$temp/_panel_pre.dta"

* --- 1b. Merge n_kids at year = cohort_year ----------------------------------
preserve
use "$temp/proc_kids_panel.dta", clear
rename cuil cuil_num
rename year cohort_year
rename n_kids n_kids_at_sorteo
save "$temp/_panel_at.dta", replace
restore

merge m:1 cuil_num cohort_year using "$temp/_panel_at.dta", ///
    keep(master match) nogenerate
replace n_kids_at_sorteo = 0 if n_kids_at_sorteo == .
erase "$temp/_panel_at.dta"

* --- 1c. Merge n_kids at year = 2024 -----------------------------------------
preserve
use "$temp/proc_kids_panel.dta", clear
keep if year == 2024
rename cuil cuil_num
rename n_kids n_kids_2024
keep cuil_num n_kids_2024
save "$temp/_panel_2024.dta", replace
restore

merge m:1 cuil_num using "$temp/_panel_2024.dta", ///
    keep(master match) nogenerate
replace n_kids_2024 = 0 if n_kids_2024 == .
erase "$temp/_panel_2024.dta"

* --- 1d. Construct outcomes + pre-treatment indicators -----------------------
gen byte had_kid_pre  = (n_kids_pre > 0)
gen int  n_kids_post  = n_kids_2024 - n_kids_at_sorteo
gen byte had_kid_post = (n_kids_post > 0)

label variable n_kids_pre       "# children by end of (sorteo year - 1)"
label variable had_kid_pre      "Had at least one child by end of (sorteo year - 1)"
label variable n_kids_at_sorteo "# children by end of sorteo year"
label variable n_kids_2024      "# children by end of 2024"
label variable n_kids_post      "# children born strictly after sorteo year"
label variable had_kid_post     "Had at least one child strictly after sorteo year"

di as text _n "Outcome summary (full sample):"
foreach v in n_kids_pre had_kid_pre n_kids_post had_kid_post {
    quietly sum `v'
    di as text "  `v': mean = " %7.4f r(mean)
}

* --- 1e. Merge SIPA pre-treatment controls at sorteo month -------------------
*    NOTE: pre_employed/pre_wage are NO LONGER used as controls in this paper
*    (we use only edad and pre-treatment fertility indicators), but we keep
*    them in the cross-section in case downstream scripts want them.
preserve
use "$temp/sipa_panel.dta", clear
rename total_wage pre_wage
rename employed   pre_employed
replace pre_employed = 0 if pre_wage == 0
save "$temp/_pretreat_sipa.dta", replace
restore

gen periodo_month = sorteo_month
format periodo_month %tm
merge m:1 id_anon periodo_month using "$temp/_pretreat_sipa.dta", ///
    keep(master match) nogenerate
replace pre_wage     = 0 if pre_wage == .
replace pre_employed = 0 if pre_employed == .
drop periodo_month
erase "$temp/_pretreat_sipa.dta"

di as text _n "Final cross-section: N = " _N
save "$temp/cross_section_hijos_full.dta", replace


/*==============================================================================
  STEP 2: BALANCE TEST — Pre-Sorteo Children by Ganador
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 2: Balance test"
di as text       "==================================================================="

use "$temp/cross_section_hijos_full.dta", clear

eststo clear
eststo bal_count: reghdfe n_kids_pre ganador, absorb(sorteo_fe) cluster(id_anon)
quietly sum n_kids_pre if ganador == 0
estadd scalar cmean = r(mean)

eststo bal_bin: reghdfe had_kid_pre ganador, absorb(sorteo_fe) cluster(id_anon)
quietly sum had_kid_pre if ganador == 0
estadd scalar cmean = r(mean)

esttab bal_count bal_bin ///
    using "$tables/table_hijos_balance.tex", replace ///
    keep(ganador) se(%9.4f) b(%9.4f) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    nonumbers nomtitles ///
    coeflabels(ganador "Ganador") ///
    prehead(`"\begin{table}[H]\centering"' ///
            `"\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}"' ///
            `"\caption{Balance Test: Pre-Sorteo Children by Ganador}"' ///
            `"\label{tab:hijos_balance}"' ///
            `"\scriptsize"' ///
            `"\begin{tabular}{lcc}"' ///
            `"\hline\hline"' ///
            `" & \# Children (count) & Had a Child (binary) \\"' ///
            `" & (1) & (2) \\"' ///
            `"\hline"') ///
    prefoot(`"\hline"') ///
    stats(cmean N, ///
          labels("Control mean" "Observations") ///
          fmt(%9.4f %9.0fc)) ///
    postfoot(`"\hline\hline"' ///
             `"\multicolumn{3}{p{0.80\textwidth}}{\scriptsize OLS regressions of pre-sorteo child outcomes on the lottery winner dummy. Counts come from the civil registry of births (\texttt{proc\_as\_parents.dta}), aggregated to a CUIL x calendar-year panel of cumulative children. \emph{\# Children}: number of children born by the end of the calendar year before the sorteo. \emph{Had a Child}: indicator equal to one if \# Children \(\geq 1\). Sample is the full sorteo-level cross-section. Sorteo FE absorbed. SE clustered at the person level.}\\"' ///
             `"\multicolumn{3}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}"' ///
             `"\end{tabular}"' ///
             `"\end{table}"') ///
    substitute(\_ _)

di as text "  table_hijos_balance.tex saved"


/*==============================================================================
  STEP 3: MAIN TABLE — table_hijos.tex
    8 cols: Had Kid After (4 specs) | # Kids After (4 specs)
    Specs:
      (1) noctl
      (2) edad
      (3) edad + had_kid_pre
      (4) edad + n_kids_pre
    Panel A: ITT, Panel B: IV/2SLS.
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 3: Main table (4 specs)"
di as text       "==================================================================="

* --- Panel A: ITT ---
eststo clear
foreach spec in "s1" "s2" "s3" "s4" {
    if "`spec'" == "s1" {
        local controls ""
        local mE ""
        local mH ""
        local mN ""
    }
    if "`spec'" == "s2" {
        local controls "edad"
        local mE "\checkmark"
        local mH ""
        local mN ""
    }
    if "`spec'" == "s3" {
        local controls "edad had_kid_pre"
        local mE "\checkmark"
        local mH "\checkmark"
        local mN ""
    }
    if "`spec'" == "s4" {
        local controls "edad n_kids_pre"
        local mE "\checkmark"
        local mH ""
        local mN "\checkmark"
    }

    eststo itt_had_`spec': reghdfe had_kid_post ganador `controls', ///
        absorb(sorteo_fe) cluster(id_anon)
    quietly sum had_kid_post if ganador == 0
    estadd scalar cmean = r(mean)
    estadd local mE "`mE'"
    estadd local mH "`mH'"
    estadd local mN "`mN'"

    eststo itt_n_`spec': reghdfe n_kids_post ganador `controls', ///
        absorb(sorteo_fe) cluster(id_anon)
    quietly sum n_kids_post if ganador == 0
    estadd scalar cmean = r(mean)
    estadd local mE "`mE'"
    estadd local mH "`mH'"
    estadd local mN "`mN'"
}

esttab itt_had_s1 itt_had_s2 itt_had_s3 itt_had_s4 ///
       itt_n_s1   itt_n_s2   itt_n_s3   itt_n_s4   ///
       using "$tables/table_hijos.tex", replace ///
    keep(ganador) se(%9.4f) b(%9.4f) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    nonumbers nomtitles noobs nor2 ///
    coeflabels(ganador "Ganador") ///
    prehead(`"\begin{table}[H]\centering"' ///
            `"\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}"' ///
            `"\caption{Fertility Effects of PROCREAR Credit}"' ///
            `"\label{tab:hijos}"' ///
            `"\scriptsize"' ///
            `"\setlength{\tabcolsep}{3pt}"' ///
            `"\begin{tabular}{l*{8}{c}}"' ///
            `"\hline\hline"' ///
            `" & \multicolumn{4}{c}{Had Kid After (binary)} & \multicolumn{4}{c}{\# Kids After (count)} \\"' ///
            `"\cline{2-5}\cline{6-9}"' ///
            `" & (1) & (2) & (3) & (4) & (5) & (6) & (7) & (8) \\"' ///
            `"\hline"' ///
            `"\multicolumn{9}{l}{\textit{Panel A: ITT}} \\"') ///
    postfoot(`"[1em]"') ///
    substitute(\_ _) fragment

* --- Panel B: IV ---
eststo clear
foreach spec in "s1" "s2" "s3" "s4" {
    if "`spec'" == "s1" {
        local controls ""
        local mE ""
        local mH ""
        local mN ""
    }
    if "`spec'" == "s2" {
        local controls "edad"
        local mE "\checkmark"
        local mH ""
        local mN ""
    }
    if "`spec'" == "s3" {
        local controls "edad had_kid_pre"
        local mE "\checkmark"
        local mH "\checkmark"
        local mN ""
    }
    if "`spec'" == "s4" {
        local controls "edad n_kids_pre"
        local mE "\checkmark"
        local mH ""
        local mN "\checkmark"
    }

    eststo iv_had_`spec': ivreghdfe had_kid_post `controls' ///
        (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
    quietly sum had_kid_post if ganador == 0
    estadd scalar cmean = r(mean)
    estadd scalar fs_F = e(widstat)
    estadd local mE "`mE'"
    estadd local mH "`mH'"
    estadd local mN "`mN'"

    eststo iv_n_`spec': ivreghdfe n_kids_post `controls' ///
        (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
    quietly sum n_kids_post if ganador == 0
    estadd scalar cmean = r(mean)
    estadd scalar fs_F = e(widstat)
    estadd local mE "`mE'"
    estadd local mH "`mH'"
    estadd local mN "`mN'"
}

esttab iv_had_s1 iv_had_s2 iv_had_s3 iv_had_s4 ///
       iv_n_s1   iv_n_s2   iv_n_s3   iv_n_s4   ///
       using "$tables/table_hijos.tex", append ///
    keep(receptor) se(%9.4f) b(%9.4f) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    nonumbers nomtitles ///
    coeflabels(receptor "Receptor") ///
    prehead(`"\multicolumn{9}{l}{\textit{Panel B: IV / 2SLS}} \\"') ///
    prefoot(`"\hline"') ///
    stats(cmean fs_F N mE mH mN, ///
          labels("Control mean" "First-stage F" "Observations" ///
                 "edad" "had\_kid\_pre" "n\_kids\_pre") ///
          fmt(%9.4f %9.1f %9.0fc %s %s %s)) ///
    postfoot(`"\hline\hline"' ///
             `"\multicolumn{9}{p{0.95\textwidth}}{\scriptsize 2SLS. Instrument: ganador. \emph{Had Kid After}: indicator for at least one child born strictly after the sorteo year. \emph{\# Kids After}: count of children born strictly after the sorteo year. Cols (1),(5): no controls. (2),(6): edad only. (3),(7): edad + had\_kid\_pre. (4),(8): edad + n\_kids\_pre. SE clustered at person level. Sorteo FE absorbed.}\\"' ///
             `"\multicolumn{9}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}"' ///
             `"\end{tabular}"' ///
             `"\end{table}"') ///
    substitute(\_ _) fragment

di as text "  table_hijos.tex saved"


/*==============================================================================
  STEP 3b: FERTILITY MECHANISM TABLE — POOLED / MEN / WOMEN

  Output: table_n_kids_after.tex

  Three IV regressions of n_kids_post on receptor (Pooled / Men / Women),
  with controls (edad + n_kids_pre) and sorteo FE. Bottom row indicates
  the controls explicitly. Presented as a mechanism table after the main
  labor table in Section 5.1.
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 3b: Fertility effect (n_kids_post): Pooled / Men / Women"
di as text       "==================================================================="

use "$temp/cross_section_hijos_full.dta", clear

local controls "edad n_kids_pre"

* --- (1) Pooled -----------------------------------------------------------
ivreghdfe n_kids_post `controls' (receptor = ganador), ///
    absorb(sorteo_fe) cluster(id_anon)
local b1  = _b[receptor]
local se1 = _se[receptor]
local n1  = e(N)
local f1  = e(widstat)
quietly sum n_kids_post if ganador == 0
local cm1 = r(mean)

* --- (2) Men --------------------------------------------------------------
ivreghdfe n_kids_post `controls' (receptor = ganador) if mujer == 0, ///
    absorb(sorteo_fe) cluster(id_anon)
local b2  = _b[receptor]
local se2 = _se[receptor]
local n2  = e(N)
local f2  = e(widstat)
quietly sum n_kids_post if ganador == 0 & mujer == 0
local cm2 = r(mean)

* --- (3) Women ------------------------------------------------------------
ivreghdfe n_kids_post `controls' (receptor = ganador) if mujer == 1, ///
    absorb(sorteo_fe) cluster(id_anon)
local b3  = _b[receptor]
local se3 = _se[receptor]
local n3  = e(N)
local f3  = e(widstat)
quietly sum n_kids_post if ganador == 0 & mujer == 1
local cm3 = r(mean)

* --- Stars + format -------------------------------------------------------
forvalues j = 1/3 {
    local t = abs(`b`j''/`se`j'')
    if      `t' > 2.576 local star`j' "\sym{***}"
    else if `t' > 1.960 local star`j' "\sym{**}"
    else if `t' > 1.645 local star`j' "\sym{*}"
    else                local star`j' ""

    local b`j's  : display %9.4f `b`j''
    local se`j's : display %9.4f `se`j''
    local cm`j's : display %9.4f `cm`j''
    local f`j's  : display %9.0fc `f`j''
    local n`j's  : display %12.0fc `n`j''
}

* --- Write table ----------------------------------------------------------
capture file close fh
file open fh using "$tables/table_n_kids_after.tex", write replace

file write fh "\begin{table}[H]\centering" _n
file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
file write fh "\caption{Effect of PROCREAR Credit on Number of Children Born After the Lottery}" _n
file write fh "\label{tab:n_kids_after}" _n
file write fh "\scriptsize" _n
file write fh "\setlength{\tabcolsep}{0pt}" _n
file write fh "\begin{tabular}{@{}l*{3}{>{\centering\arraybackslash}p{0.17\textwidth}}@{}}" _n
file write fh "\hline\hline" _n
file write fh " & Pooled & Men & Women \\" _n
file write fh " & (1) & (2) & (3) \\" _n
file write fh "\hline" _n
file write fh "Recipient & `b1s'`star1' & `b2s'`star2' & `b3s'`star3' \\" _n
file write fh "          & (`se1s') & (`se2s') & (`se3s') \\" _n
file write fh "\hline" _n
file write fh "Control mean & `cm1s' & `cm2s' & `cm3s' \\" _n
file write fh "First-stage F & `f1s' & `f2s' & `f3s' \\" _n
file write fh "Observations & `n1s' & `n2s' & `n3s' \\" _n
file write fh "Controls & \multicolumn{3}{c}{Age, pre-lottery \# children} \\" _n
file write fh "\hline\hline" _n
file write fh "\end{tabular}" _n
file write fh "\par\smallskip" _n
file write fh "\begin{minipage}{0.85\textwidth}" _n
file write fh "\scriptsize" _n
file write fh "2SLS. Instrument: lottery winner. Outcome: number of children born strictly after the lottery year. (1) Full sample. (2) Men only. (3) Women only. Lottery-round FE absorbed. SE clustered at the person level (in parentheses).\\" _n
file write fh "\sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)" _n
file write fh "\end{minipage}" _n
file write fh "\end{table}" _n
file close fh

di as text "  table_n_kids_after.tex saved (3-col: Pooled / Men / Women)"


/*==============================================================================
  STEP 4: HETEROGENEITY BY COHORT YEAR — table_hijos_het_year.tex
    12 cols: 4 cohorts x 3 specs. Outcome: had_kid_post.
    Specs: noctl / edad / edad + n_kids_pre
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 4: Heterogeneity by cohort year"
di as text       "==================================================================="

* --- Panel A: ITT ---
eststo clear
foreach spec in "s1" "s2" "s4" {
    if "`spec'" == "s1" {
        local controls ""
        local mE ""
        local mN ""
    }
    if "`spec'" == "s2" {
        local controls "edad"
        local mE "\checkmark"
        local mN ""
    }
    if "`spec'" == "s4" {
        local controls "edad n_kids_pre"
        local mE "\checkmark"
        local mN "\checkmark"
    }
    forvalues y = 2020/2023 {
        eststo itt_`y'_`spec': reghdfe had_kid_post ganador `controls' ///
            if cohort_year == `y', absorb(sorteo_fe) cluster(id_anon)
        quietly sum had_kid_post if ganador == 0 & cohort_year == `y'
        estadd scalar cmean = r(mean)
        estadd local mE "`mE'"
        estadd local mN "`mN'"
    }
}

esttab itt_2020_s1 itt_2020_s2 itt_2020_s4 ///
       itt_2021_s1 itt_2021_s2 itt_2021_s4 ///
       itt_2022_s1 itt_2022_s2 itt_2022_s4 ///
       itt_2023_s1 itt_2023_s2 itt_2023_s4 ///
       using "$tables/table_hijos_het_year.tex", replace ///
    keep(ganador) se(%9.4f) b(%9.4f) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    nonumbers nomtitles noobs nor2 ///
    coeflabels(ganador "Ganador") ///
    prehead(`"\begin{table}[H]\centering"' ///
            `"\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}"' ///
            `"\caption{Heterogeneity by Cohort: Had a Child After Sorteo}"' ///
            `"\label{tab:hijos_het_year}"' ///
            `"\tiny"' ///
            `"\begin{tabular}{l*{12}{c}}"' ///
            `"\hline\hline"' ///
            `" & \multicolumn{3}{c}{2020} & \multicolumn{3}{c}{2021} & \multicolumn{3}{c}{2022} & \multicolumn{3}{c}{2023} \\"' ///
            `"\cline{2-4}\cline{5-7}\cline{8-10}\cline{11-13}"' ///
            `" & (1) & (2) & (3) & (4) & (5) & (6) & (7) & (8) & (9) & (10) & (11) & (12) \\"' ///
            `"\hline"' ///
            `"\multicolumn{13}{l}{\textit{Panel A: ITT}} \\"') ///
    postfoot(`"[1em]"') substitute(\_ _) fragment

* --- Panel B: IV ---
eststo clear
foreach spec in "s1" "s2" "s4" {
    if "`spec'" == "s1" {
        local controls ""
        local mE ""
        local mN ""
    }
    if "`spec'" == "s2" {
        local controls "edad"
        local mE "\checkmark"
        local mN ""
    }
    if "`spec'" == "s4" {
        local controls "edad n_kids_pre"
        local mE "\checkmark"
        local mN "\checkmark"
    }
    forvalues y = 2020/2023 {
        eststo iv_`y'_`spec': ivreghdfe had_kid_post `controls' ///
            (receptor = ganador) if cohort_year == `y', ///
            absorb(sorteo_fe) cluster(id_anon)
        quietly sum had_kid_post if ganador == 0 & cohort_year == `y'
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)
        estadd local mE "`mE'"
        estadd local mN "`mN'"
    }
}

esttab iv_2020_s1 iv_2020_s2 iv_2020_s4 ///
       iv_2021_s1 iv_2021_s2 iv_2021_s4 ///
       iv_2022_s1 iv_2022_s2 iv_2022_s4 ///
       iv_2023_s1 iv_2023_s2 iv_2023_s4 ///
       using "$tables/table_hijos_het_year.tex", append ///
    keep(receptor) se(%9.4f) b(%9.4f) ///
    star(* 0.10 ** 0.05 *** 0.01) ///
    nonumbers nomtitles ///
    coeflabels(receptor "Receptor") ///
    prehead(`"\multicolumn{13}{l}{\textit{Panel B: IV / 2SLS}} \\"') ///
    prefoot(`"\hline"') ///
    stats(cmean fs_F N mE mN, ///
          labels("Control mean" "First-stage F" "Observations" ///
                 "edad" "n\_kids\_pre") ///
          fmt(%9.4f %9.1f %9.0fc %s %s)) ///
    postfoot(`"\hline\hline"' ///
             `"\multicolumn{13}{p{0.95\textwidth}}{\tiny 2SLS. Outcome: indicator for first child born strictly after the sorteo year. Cols (1),(4),(7),(10): no controls. (2),(5),(8),(11): edad only. (3),(6),(9),(12): edad + n\_kids\_pre. SE clustered at person level. Sorteo FE absorbed.}\\"' ///
             `"\multicolumn{13}{l}{\tiny \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}"' ///
             `"\end{tabular}\end{table}"') ///
    substitute(\_ _) fragment

di as text "  table_hijos_het_year.tex saved"


/*==============================================================================
  STEP 5: BY CREDIT TYPE — type_{grp}_hijos.tex
    3 specs (noctl / edad / edad+n_kids_pre) x 2 outcomes = 6 cols per type.
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 5: By credit type"
di as text       "==================================================================="

local grp_names `" "DU" "Construccion" "Lotes" "'

forvalues g = 1/3 {
    local grp : word `g' of `grp_names'
    local grp_lower = lower("`grp'")
    di as text _n "  --- `grp' (tipo_grupo == `g') ---"

    * --- Panel A: ITT ---
    eststo clear
    foreach spec in "s1" "s2" "s4" {
        if "`spec'" == "s1" {
            local controls ""
            local mE ""
        local mN ""
        }
        if "`spec'" == "s2" {
            local controls "edad"
            local mE "\checkmark"
        local mN ""
        }
        if "`spec'" == "s4" {
            local controls "edad n_kids_pre"
            local mE "\checkmark"
        local mN "\checkmark"
        }
        eststo itt_had_`spec': reghdfe had_kid_post ganador `controls' ///
            if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
        quietly sum had_kid_post if ganador == 0 & tipo_grupo == `g'
        estadd scalar cmean = r(mean)
        estadd local mE "`mE'"
        estadd local mN "`mN'"

        eststo itt_n_`spec': reghdfe n_kids_post ganador `controls' ///
            if tipo_grupo == `g', absorb(sorteo_fe) cluster(id_anon)
        quietly sum n_kids_post if ganador == 0 & tipo_grupo == `g'
        estadd scalar cmean = r(mean)
        estadd local mE "`mE'"
        estadd local mN "`mN'"
    }

    esttab itt_had_s1 itt_had_s2 itt_had_s4 ///
           itt_n_s1   itt_n_s2   itt_n_s4   ///
           using "$tables/type_`grp_lower'_hijos.tex", replace ///
        keep(ganador) se(%9.4f) b(%9.4f) ///
        star(* 0.10 ** 0.05 *** 0.01) ///
        nonumbers nomtitles noobs nor2 ///
        coeflabels(ganador "Ganador") ///
        prehead(`"\begin{table}[H]\centering"' ///
                `"\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}"' ///
                `"\caption{Fertility Effects of PROCREAR Credit (`grp')}"' ///
                `"\label{tab:hijos_`grp_lower'}"' ///
                `"\scriptsize"' ///
                `"\begin{tabular}{l*{6}{c}}"' ///
                `"\hline\hline"' ///
                `" & \multicolumn{3}{c}{Had Kid After (binary)} & \multicolumn{3}{c}{\# Kids After (count)} \\"' ///
                `"\cline{2-4}\cline{5-7}"' ///
                `" & (1) & (2) & (3) & (4) & (5) & (6) \\"' ///
                `"\hline"' ///
                `"\multicolumn{7}{l}{\textit{Panel A: ITT}} \\"') ///
        postfoot(`"[1em]"') substitute(\_ _) fragment

    * --- Panel B: IV ---
    eststo clear
    foreach spec in "s1" "s2" "s4" {
        if "`spec'" == "s1" {
            local controls ""
            local mE ""
        local mN ""
        }
        if "`spec'" == "s2" {
            local controls "edad"
            local mE "\checkmark"
        local mN ""
        }
        if "`spec'" == "s4" {
            local controls "edad n_kids_pre"
            local mE "\checkmark"
        local mN "\checkmark"
        }
        eststo iv_had_`spec': ivreghdfe had_kid_post `controls' ///
            (receptor = ganador) if tipo_grupo == `g', ///
            absorb(sorteo_fe) cluster(id_anon)
        quietly sum had_kid_post if ganador == 0 & tipo_grupo == `g'
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)
        estadd local mE "`mE'"
        estadd local mN "`mN'"

        eststo iv_n_`spec': ivreghdfe n_kids_post `controls' ///
            (receptor = ganador) if tipo_grupo == `g', ///
            absorb(sorteo_fe) cluster(id_anon)
        quietly sum n_kids_post if ganador == 0 & tipo_grupo == `g'
        estadd scalar cmean = r(mean)
        estadd scalar fs_F = e(widstat)
        estadd local mE "`mE'"
        estadd local mN "`mN'"
    }

    esttab iv_had_s1 iv_had_s2 iv_had_s4 ///
           iv_n_s1   iv_n_s2   iv_n_s4   ///
           using "$tables/type_`grp_lower'_hijos.tex", append ///
        keep(receptor) se(%9.4f) b(%9.4f) ///
        star(* 0.10 ** 0.05 *** 0.01) ///
        nonumbers nomtitles ///
        coeflabels(receptor "Receptor") ///
        prehead(`"\multicolumn{7}{l}{\textit{Panel B: IV / 2SLS}} \\"') ///
        prefoot(`"\hline"') ///
        stats(cmean fs_F N mE mN, ///
              labels("Control mean" "First-stage F" "Observations" ///
                     "edad" "n\_kids\_pre") ///
              fmt(%9.4f %9.1f %9.0fc %s %s)) ///
        postfoot(`"\hline\hline"' ///
                 `"\multicolumn{7}{p{0.95\textwidth}}{\scriptsize 2SLS. Sample restricted to `grp' applicants. Cols (1),(4): no controls. (2),(5): edad only. (3),(6): edad + n\_kids\_pre. SE clustered at person level. Sorteo FE absorbed.}\\"' ///
                 `"\multicolumn{7}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}"' ///
                 `"\end{tabular}\end{table}"') ///
        substitute(\_ _) fragment

    di as text "    type_`grp_lower'_hijos.tex saved"
}


/*==============================================================================
  STEP 6: COMPACT TYPE x YEAR — table_hijos_type_year.tex
    Single spec: edad + n_kids_pre.
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 6: Compact type x year"
di as text       "==================================================================="

local controls "edad n_kids_pre"

capture file close fh
file open fh using "$tables/table_hijos_type_year.tex", write replace
file write fh "\begin{table}[H]\centering" _n
file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
file write fh "\caption{Children Born After Lottery by Credit Type and Cohort: IV with age + n\_kids\_pre}" _n
file write fh "\label{tab:hijos_type_year}" _n
file write fh "\scriptsize" _n
file write fh "\begin{tabular}{@{}lcccc@{}}" _n
file write fh "\hline\hline" _n
file write fh " & 2020 & 2021 & 2022 & 2023 \\" _n
file write fh " & (1) & (2) & (3) & (4) \\" _n
file write fh "\hline" _n

local grp_num = 0
foreach grp_name in "Apartment Purchases (DU)" "House Construction" "Land Purchases" {
    local ++grp_num
    forvalues j = 1/4 {
        local y = 2019 + `j'
        capture qui ivreghdfe had_kid_post `controls' (receptor = ganador) ///
            if tipo_grupo == `grp_num' & cohort_year == `y', ///
            absorb(sorteo_fe) cluster(id_anon)
        if _rc == 0 {
            local b`j'  = _b[receptor]
            local se`j' = _se[receptor]
            local n`j'  = e(N)
            quietly sum had_kid_post if ganador == 0 & tipo_grupo == `grp_num' & cohort_year == `y'
            local cm`j' = r(mean)
        }
        else {
            local b`j'  = .
            local se`j' = .
            local n`j'  = 0
            local cm`j' = .
        }
    }
    forvalues j = 1/4 {
        if missing(`b`j'') | `se`j'' == 0 {
            local star`j' ""
        }
        else {
            local tt = abs(`b`j''/`se`j'')
            if `tt' > 2.576      local star`j' "\sym{***}"
            else if `tt' > 1.960 local star`j' "\sym{**}"
            else if `tt' > 1.645 local star`j' "\sym{*}"
            else                 local star`j' ""
        }
    }
    forvalues j = 1/4 {
        if missing(`b`j'') {
            local b`j's  "---"
            local se`j's "---"
            local cm`j's "---"
            local n`j's  "0"
        }
        else {
            local b`j's:  display %9.4f `b`j''
            local se`j's: display %9.4f `se`j''
            local cm`j's: display %5.3f `cm`j''
            local n`j's:  display %9.0fc `n`j''
        }
    }
    file write fh "`grp_name' & `b1s'`star1' & `b2s'`star2' & `b3s'`star3' & `b4s'`star4' \\" _n
    file write fh "   & (`se1s') & (`se2s') & (`se3s') & (`se4s') \\" _n
    file write fh "   & [`cm1s'; N=`=strtrim("`n1s'")'] & [`cm2s'; N=`=strtrim("`n2s'")'] & [`cm3s'; N=`=strtrim("`n3s'")'] & [`cm4s'; N=`=strtrim("`n4s'")'] \\" _n
    if `grp_num' < 3 file write fh "[0.5em]" _n
}
file write fh "\hline\hline" _n
file write fh "\multicolumn{5}{p{0.85\textwidth}}{\scriptsize IV/2SLS with controls age + n\_kids\_pre. Instrument: lottery winner. Outcome: \emph{Had Kid After} (indicator for first child born strictly after the sorteo year). SE clustered at person level (in parentheses). Control means and \(N\) in brackets. Lottery FE absorbed.} \\" _n
file write fh "\multicolumn{5}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}" _n
file write fh "\end{tabular}\end{table}" _n
file close fh
di as text "  table_hijos_type_year.tex saved"


/*==============================================================================
  STEP 7: CLEANUP intermediates EXCEPT cross_section_hijos_full.dta.
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 7: Cleanup intermediates"
di as text       "==================================================================="

foreach f in deflator.dta sorteo_sample_hijos.dta sipa_panel.dta ///
             proc_kids_panel.dta {
    capture erase "$temp/`f'"
    if _rc == 0 di as text "    erased $temp/`f'"
}

di as text _n "DONE. cross_section_hijos_full.dta retained in $temp."
