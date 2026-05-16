/*==============================================================================
  PROCREAR — PLACEBO + COMPARISON SORTEOS

  Self-contained: builds all datasets from raw DATA/ files.

  Runs the same ITT analysis (matching paper_labor_outcomes.do spec) on
  TWO placebos:

    1. sagol      — Nov 23, 2023 SAGOL II sorteo (any tipo). Credits
                    NEVER disbursed (Banco Hipotecario was frozen).
                    receptor = 0 for ALL. Sharp placebo identified off
                    a single, well-documented lottery round.

    2. zero_recep — ALL sorteo_fe groups where no winner ultimately
                    took up credit (sum(receptor) over the sorteo_fe
                    group equals zero). Includes SAGOL II plus every
                    other lottery group whose winners failed the
                    post-lottery eligibility check or otherwise did
                    not draw down the credit. ITT identified off
                    within-sorteo_fe variation in winning, just like
                    the main paper, but on lottery groups where the
                    first stage is mechanically zero.

  Both placebos test the exclusion restriction: if winning the lottery
  affects outcomes only through credit receipt, the reduced-form ITT
  should be statistically indistinguishable from zero on labor,
  financial and fertility outcomes.

  Each placebo run produces FIVE tables, sharing the same structure as
  paper_labor_outcomes.do, paper_bcra_combined_age.do and
  paper_hijos_outcomes.do:
    placebo_first_stage<sfx>.tex   — receptor on ganador (3 specs)
    placebo_main<sfx>.tex          — ITT pooled + gender (body, 2 specs)
    placebo_main_full<sfx>.tex     — same with full controls (appendix)
    placebo_bcra<sfx>.tex          — ITT on 7 BCRA outcomes (age control)
    placebo_hijos<sfx>.tex         — ITT on n_kids_post (3 specs)

  Plus four cross-placebo combined tables in the robustness section:
    placebo_fs_combined.tex        — 2 first stages side by side
    placebo_itt_combined.tex       — 2 labor ITTs side by side
    placebo_bcra_combined.tex      — 2 BCRA ITTs side by side
    placebo_hijos_combined.tex     — 2 fertility ITTs side by side

  Suffixes:
    sagol      → `_sagol`
    zero_recep → `_zero_recep`

  BCRA outcomes (matching paper_bcra_combined_age.do):
    Total Debt, Slow Payer, Banked  — all-entities sample
    Q1-Q4 Cost                       — excl.-Hipotecario sample

  Fertility outcome (matching paper_hijos_outcomes.do):
    n_kids_post = n_kids_2024 - n_kids_at_sorteo (kids born strictly
    after the lottery year, observed through end of 2024). All three
    placebos are 2023 sorteos, so the observation window is one year.

  Requires $temp/median_costo.dta from paper_bcra_outcomes.do for the
  Q-cost quartile cutoffs (same cutoffs used in the main analysis).
  Builds its own cumulative-children panel from $data/proc_as_parents.dta.

  Spec match with paper_labor_outcomes.do:
    - Edad: direct from Data_sorteos.edad_sorteo (no CUIL imputation)
    - Mujer: direct from Data_sorteos (no genero fallback)
    - Wage deseasonalization: remuneracion - sac (exact)
    - SIPA drop: mes < 202007
    - Outcomes: employed, is_monotributo, emp_share_<k>plus  (k=18)
    - Spec sets: noctl / agectl (edad) / ctl (full)
    - Gender heterogeneity: interaction with sorteo × mujer FE,
      restricted to pre_employed == 1
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

* --- ANALYSIS PARAMETERS ------------------------------------------------------
local k_months = 18
local k_label "`k_months'plus"


/*==============================================================================
  STEP 1: Build deflator (once, shared across placebos)
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

keep periodo_month deflator
save "$temp/_plac_deflator.dta", replace


/*==============================================================================
  STEP 1.5: Build Q-flag entity table for BCRA cost-quartile outcomes (once)

  Uses $temp/median_costo.dta from paper_bcra_outcomes.do so the placebo
  Q1-Q4 cutoffs match the main analysis exactly. Errors out if missing.
==============================================================================*/

di as text _n "=== STEP 1.5: Building Q-flag entity table for BCRA ===" _n

capture confirm file "$temp/median_costo.dta"
if _rc != 0 {
    di as error "$temp/median_costo.dta not found — run paper_bcra_outcomes.do first."
    error 601
}

use "$temp/median_costo.dta", clear
keep entidad_str median_costo
duplicates drop
quietly sum median_costo, detail
local q25 = r(p25)
local q50 = r(p50)
local q75 = r(p75)
di as text "  Q-cutoffs: p25=" %9.2f `q25' ", p50=" %9.2f `q50' ", p75=" %9.2f `q75'

gen byte is_q1 = (median_costo <  `q25')                         if median_costo != .
gen byte is_q2 = (median_costo >= `q25' & median_costo <  `q50') if median_costo != .
gen byte is_q3 = (median_costo >= `q50' & median_costo <  `q75') if median_costo != .
gen byte is_q4 = (median_costo >= `q75')                         if median_costo != .

keep entidad_str is_q1 is_q2 is_q3 is_q4
save "$temp/_plac_q_flags_entity.dta", replace


/*==============================================================================
  STEP 1.6: Build cumulative-children panel (once, shared across placebos)

  Mirrors STEP 0.4 of paper_hijos_outcomes.do. Reads proc_as_parents.dta
  (CUIL x year_birth pairs from civil registry of births), reshapes to
  wide format, expands to a (cuil x calendar year) panel of cumulative
  number of children. Year range: 2000-2025.
==============================================================================*/

di as text _n "=== STEP 1.6: Building cumulative-children panel ===" _n

local year_start = 2000
local year_end   = 2025

use "$data/proc_as_parents.dta", clear
sort cuil year_birth
by cuil: gen byte k = _n
keep cuil k year_birth
reshape wide year_birth, i(cuil) j(k)
di as text "    Parents (unique cuils): " _N

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

keep cuil year n_kids
rename cuil cuil_num
sort cuil_num year
save "$temp/_plac_proc_kids_panel.dta", replace
di as text "    _plac_proc_kids_panel saved: " _N " rows"


/*==============================================================================
  PLACEBO LOOP — for each of sagol / zero_recep, run steps 2-5
==============================================================================*/

foreach placebo_id in "sagol" "zero_recep" {

    * --- Per-placebo configuration ---
    if "`placebo_id'" == "sagol" {
        local filter_kind "date"
        local filter "_month == 11 & _day == 23"
        local out_sfx "_sagol"
        local caption_id "SAGOL II (Nov 23 2023), No Credit Disbursed"
        local fs_note "credits never disbursed, so \emph{receptor} = 0 for everyone"
        local fs_expected "The coefficient should be \(\approx\) 0 by construction"
    }
    else if "`placebo_id'" == "zero_recep" {
        local filter_kind "zero_recep"
        local filter ""
        local out_sfx "_zero_recep"
        local caption_id "All Lottery Groups with Zero Take-up"
        local fs_note "all sorteo\_fe groups where no winner took up credit, so \emph{receptor} = 0 for everyone"
        local fs_expected "The coefficient should be \(\approx\) 0 by construction"
    }

    di as text _n(3) "================================================================"
    di as text       "  PLACEBO RUN: `placebo_id'   filter: `filter'"
    di as text       "================================================================"

    /*--------------------------------------------------------------------------
      STEP 2: Sorteo sample (filtered)
    --------------------------------------------------------------------------*/
    di as text _n "=== STEP 2 [`placebo_id']: Building sorteo sample ===" _n

    use "$data/Data_sorteos.dta", clear

    di as text "Raw sorteos: N = " _N

    replace desarrollourbanistico = 0 if desarrollourbanistico == .
    replace tipologia = 0 if tipologia == .
    replace cupo = 0 if cupo == .

    egen sorteo_fe = group(fecha_sorteo tipo desarrollourbanistico tipologia cupo)

    gen tipo_grupo = .
    replace tipo_grupo = 1 if tipo == 5
    replace tipo_grupo = 2 if inlist(tipo, 2, 3, 4)
    replace tipo_grupo = 3 if inlist(tipo, 6)
    replace tipo_grupo = 4 if inlist(tipo, 1, 8, 9, 10, 11, 12, 13)
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
    label variable edad "Edad (anos) al dia del sorteo"
    cap drop fnacimiento

    destring cuil, gen(cuil_num) force
    label variable cuil_num "CUIL (numeric, for kids panel merge)"

    replace monotributo = . if monotributo == 24
    replace monotributo = . if monotributo == 1
    gen byte is_monotributo = (monotributo > 0 & monotributo != .)

    * --- Filter ---
    if "`filter_kind'" == "date" {
        gen _day = day(fecha_sorteo)
        gen _month = month(fecha_sorteo)
        keep if `filter'
        drop _day _month
    }
    else if "`filter_kind'" == "zero_recep" {
        bys sorteo_fe: egen _n_recep = total(receptor)
        keep if _n_recep == 0
        drop _n_recep
    }
    else {
        di as error "ERROR: unknown filter_kind '`filter_kind'' for `placebo_id'."
        error 2001
    }

    if _N == 0 {
        di as error "ERROR: No sorteos for placebo `placebo_id' (filter_kind: `filter_kind')."
        error 2000
    }

    di as text _n "Sample (post-filter): N = " _N
    tab ganador
    di as text "Receptores:"
    count if receptor == 1
    di as text "Sorteo FE groups:"
    distinct sorteo_fe

    save "$temp/_plac_`placebo_id'_sorteo.dta", replace

    /*--------------------------------------------------------------------------
      STEP 3: SIPA panel (filtered to placebo persons)
    --------------------------------------------------------------------------*/
    di as text _n "=== STEP 3 [`placebo_id']: Building SIPA panel ===" _n

    use "$data/Data_SIPA.dta", clear
    drop if mes < 202007

    preserve
    use "$temp/_plac_`placebo_id'_sorteo.dta", clear
    keep id_anon
    duplicates drop
    save "$temp/_plac_`placebo_id'_persons.dta", replace
    restore

    merge m:1 id_anon using "$temp/_plac_`placebo_id'_persons.dta", keep(match) nogenerate

    gen int _y = floor(mes / 100)
    gen int _m = mod(mes, 100)
    gen periodo_month = ym(_y, _m)
    format periodo_month %tm
    drop _y _m

    gen double wage_desest = remuneracion
    replace wage_desest = remuneracion - sac if !missing(sac)
    replace wage_desest = 0 if wage_desest < 0 & !missing(wage_desest)

    merge m:1 periodo_month using "$temp/_plac_deflator.dta", keep(master match) nogenerate
    gen double real_wage = wage_desest / deflator
    replace real_wage = 0 if wage_desest == .

    collapse (sum) total_wage=real_wage, by(id_anon periodo_month)
    gen byte employed = 1

    save "$temp/_plac_`placebo_id'_sipa.dta", replace
    erase "$temp/_plac_`placebo_id'_persons.dta"

    /*--------------------------------------------------------------------------
      STEP 4: Cross-section + pre-treatment
    --------------------------------------------------------------------------*/
    di as text _n "=== STEP 4 [`placebo_id']: Cross-section ===" _n

    use "$temp/_plac_`placebo_id'_sorteo.dta", clear
    keep id_anon is_monotributo
    duplicates drop

    merge 1:m id_anon using "$temp/_plac_`placebo_id'_sipa.dta"
    replace employed   = 0 if _merge == 1
    replace total_wage = 0 if _merge == 1
    drop if _merge == 2
    drop _merge

    bys id_anon (periodo_month): keep if _n == _N

    replace employed = (periodo_month == ym(2025, 12))
    replace employed = 0 if total_wage == 0
    replace total_wage = 0 if employed == 0

    gen double log_wage = ln(total_wage) if employed == 1 & total_wage > 0
    gen byte any_work = (employed == 1 | is_monotributo == 1)

    keep id_anon employed total_wage log_wage any_work periodo_month
    save "$temp/_plac_`placebo_id'_outcomes.dta", replace

    use "$temp/_plac_`placebo_id'_sorteo.dta", clear
    keep id_anon cuil_num ganador receptor sorteo_fe tipo tipo_grupo sorteo_month ///
         cohort_year fecha_sorteo is_monotributo edad mujer

    merge m:1 id_anon using "$temp/_plac_`placebo_id'_outcomes.dta", keep(master match) nogenerate

    save "$temp/_plac_`placebo_id'_xsec.dta", replace

    * --- Pre-treatment outcomes ---
    preserve
    use "$temp/_plac_`placebo_id'_sipa.dta", clear
    rename total_wage pre_wage
    rename employed pre_employed
    replace pre_employed = 0 if pre_wage == 0
    save "$temp/_plac_`placebo_id'_pretreat.dta", replace
    restore

    use "$temp/_plac_`placebo_id'_xsec.dta", clear
    drop periodo_month
    gen periodo_month = sorteo_month
    format periodo_month %tm
    merge m:1 id_anon periodo_month using "$temp/_plac_`placebo_id'_pretreat.dta", ///
        keep(master match) nogenerate
    replace pre_wage = 0 if pre_wage == .
    replace pre_employed = 0 if pre_employed == .
    drop periodo_month

    save "$temp/_plac_`placebo_id'_xsec.dta", replace
    erase "$temp/_plac_`placebo_id'_pretreat.dta"

    /*--------------------------------------------------------------------------
      STEP 4d: emp_share_<k>plus
    --------------------------------------------------------------------------*/
    di as text _n "=== STEP 4d [`placebo_id']: emp_share_`k_label' ===" _n

    local _min_win = ym(2020, 1) + `k_months'

    use "$temp/_plac_`placebo_id'_sipa.dta", clear
    keep if periodo_month >= `_min_win' & periodo_month <= ym(2025, 12)
    keep if employed == 1 & total_wage > 0
    keep id_anon periodo_month
    save "$temp/_plac_`placebo_id'_sipa_k.dta", replace

    use "$temp/_plac_`placebo_id'_xsec.dta", clear
    keep id_anon sorteo_fe sorteo_month
    duplicates drop
    save "$temp/_plac_`placebo_id'_windows_k.dta", replace

    use "$temp/_plac_`placebo_id'_windows_k.dta", clear
    joinby id_anon using "$temp/_plac_`placebo_id'_sipa_k.dta"
    gen int window_start = sorteo_month + `k_months'
    keep if periodo_month >= window_start & periodo_month <= ym(2025, 12)
    gen byte _emp = 1
    collapse (sum) emp_months_`k_label' = _emp, by(id_anon sorteo_fe)
    save "$temp/_plac_`placebo_id'_empcount.dta", replace

    use "$temp/_plac_`placebo_id'_xsec.dta", clear
    merge m:1 id_anon sorteo_fe using "$temp/_plac_`placebo_id'_empcount.dta", ///
        keep(master match) nogenerate
    replace emp_months_`k_label' = 0 if emp_months_`k_label' == .

    gen int window_len = ym(2025, 12) - (sorteo_month + `k_months') + 1
    gen double emp_share_`k_label' = emp_months_`k_label' / window_len if window_len > 0

    di as text "emp_share_`k_label' descriptives [`placebo_id']:"
    sum emp_share_`k_label' window_len

    save "$temp/_plac_`placebo_id'_xsec.dta", replace

    cap erase "$temp/_plac_`placebo_id'_sipa_k.dta"
    cap erase "$temp/_plac_`placebo_id'_windows_k.dta"
    cap erase "$temp/_plac_`placebo_id'_empcount.dta"

    /*--------------------------------------------------------------------------
      STEP 4e: First stage — receptor on ganador
    --------------------------------------------------------------------------*/
    di as text _n "=== STEP 4e [`placebo_id']: First stage ===" _n

    use "$temp/_plac_`placebo_id'_xsec.dta", clear

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
        cap test ganador
        if _rc == 0 {
            estadd scalar fs_F = r(F)
        }
        estadd local ctl_age "`mark_age'"
        estadd local ctl_full "`mark_full'"
    }

    esttab fs_noctl fs_agectl fs_ctl ///
           using "$tables/placebo_first_stage`out_sfx'.tex", replace ///
        keep(ganador) se(%9.4f) b(%9.4f) ///
        star(* 0.10 ** 0.05 *** 0.01) ///
        nonumbers nomtitles ///
        coeflabels(ganador "Ganador") ///
        prehead(`"\begin{table}[H]\centering"' ///
                `"\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}"' ///
                `"\caption{First Stage: Receptor on Ganador (`caption_id')}"' ///
                `"\label{tab:placebo_first_stage`out_sfx'}"' ///
                `"\scriptsize"' ///
                `"\begin{tabular}{l*{3}{c}}"' ///
                `"\hline\hline"' ///
                `" & (1) & (2) & (3) \\"' ///
                `"\hline"') ///
        prefoot(`"\hline"') ///
        stats(cmean fs_F N ctl_age ctl_full, ///
              labels("Control mean (losers)" "F-statistic" "Observations" ///
                     "Age only" "All controls") ///
              fmt(%9.4f %9.1f %9.0fc %s %s)) ///
        postfoot(`"\hline\hline"' ///
                 `"\multicolumn{4}{p{0.85\textwidth}}{\scriptsize OLS. Sample: `fs_note'. `fs_expected'. SE clustered at person level. Sorteo FE absorbed.}\\"' ///
                 `"\multicolumn{4}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}"' ///
                 `"\end{tabular}"' ///
                 `"\end{table}"') ///
        substitute(\_ _) fragment

    di as text "  placebo_first_stage`out_sfx'.tex saved"

    /*--------------------------------------------------------------------------
      STEP 5: Combined main table — Pooled ITT + Gender ITT
    --------------------------------------------------------------------------*/
    di as text _n "=== STEP 5 [`placebo_id']: Combined ITT table ===" _n

    use "$temp/_plac_`placebo_id'_xsec.dta", clear

    cap drop muj_x_gan muj_x_edad muj_x_pre_wage sorteo_fe_g
    gen muj_x_gan      = mujer * ganador
    gen muj_x_edad     = mujer * edad
    gen muj_x_pre_wage = mujer * pre_wage
    egen sorteo_fe_g = group(sorteo_fe mujer)

    local outcomes "employed emp_share_`k_label' is_monotributo"

    foreach table_kind in "main" "full" {
        if "`table_kind'" == "main" {
            local specs_to_run "noctl agectl"
            local n_specs = 2
            local out_file "$tables/placebo_main`out_sfx'.tex"
            local table_caption "ITT (Pooled + Gender) — `caption_id'"
            local table_label "tab:placebo_main`out_sfx'"
        }
        else {
            local specs_to_run "ctl"
            local n_specs = 1
            local out_file "$tables/placebo_main_full`out_sfx'.tex"
            local table_caption "ITT (Pooled + Gender, Full Controls) — `caption_id'"
            local table_label "tab:placebo_main_full`out_sfx'"
        }

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

                di as text _n "===== `placebo_id'  Outcome=`outc'  Spec=`spec' ====="

                * Pooled ITT
                reghdfe `outc' ganador `ctl_pool', ///
                    absorb(sorteo_fe) cluster(id_anon)
                local b_pool_`j'_`k'  = _b[ganador]
                local se_pool_`j'_`k' = _se[ganador]
                local n_pool_`j'_`k'  = e(N)
                quietly sum `outc' if ganador == 0
                local cm_pool_`j'_`k' = r(mean)

                * Gender ITT
                reghdfe `outc' ganador muj_x_gan `ctl_gender' if pre_employed == 1, ///
                    absorb(sorteo_fe_g) cluster(id_anon)
                local b_M_`j'_`k'  = _b[ganador]
                local se_M_`j'_`k' = _se[ganador]
                local b_d_`j'_`k'  = _b[muj_x_gan]
                local se_d_`j'_`k' = _se[muj_x_gan]
                local n_gen_`j'_`k' = e(N)

                lincom ganador + muj_x_gan
                local b_W_`j'_`k'  = r(estimate)
                local se_W_`j'_`k' = r(se)

                local t_d = abs(`b_d_`j'_`k''/`se_d_`j'_`k'')
                local p_d_`j'_`k' = 2 * (1 - normal(`t_d'))
            }
        }

        capture file close fh
        file open fh using "`out_file'", write replace

        file write fh "\begin{table}[H]\centering" _n
        file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
        file write fh "\caption{`table_caption'}" _n
        file write fh "\label{`table_label'}" _n
        file write fh "\scriptsize" _n
        file write fh "\setlength{\tabcolsep}{4pt}" _n

        if "`table_kind'" == "main" {
            file write fh "\begin{tabular}{@{}l*{6}{c}@{}}" _n
            file write fh "\hline\hline" _n
            file write fh " & \multicolumn{2}{c}{Formal Emp} & \multicolumn{2}{c}{Emp Share (`k_months'm+)} & \multicolumn{2}{c}{Self-employed} \\" _n
            file write fh "\cline{2-3}\cline{4-5}\cline{6-7}" _n
            file write fh " & (1) & (2) & (3) & (4) & (5) & (6) \\" _n
        }
        else {
            file write fh "\begin{tabular}{@{}l*{3}{c}@{}}" _n
            file write fh "\hline\hline" _n
            file write fh " & Formal Emp & Emp Share (`k_months'm+) & Self-employed \\" _n
            file write fh " & (1) & (2) & (3) \\" _n
        }
        file write fh "\hline" _n

        * Ganador (pooled, ITT)
        file write fh "Winner (pooled, ITT)"
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

        * β_M
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

        * β_W
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

        * p-val
        file write fh "p-val (H\(_0\): differential = 0)"
        forvalues j = 1/3 {
            forvalues k = 1/`n_specs' {
                local p : display %5.3f `p_d_`j'_`k''
                file write fh " & `p'"
            }
        }
        file write fh " \\" _n

        file write fh "\hline" _n

        * Diagnostics
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

        if "`table_kind'" == "main" {
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

        file write fh "\hline\hline" _n
        if "`table_kind'" == "main" {
            file write fh "\multicolumn{7}{p{0.95\textwidth}}{\scriptsize OLS (ITT, reduced form). Sample: `caption_id'. \textbf{Winner (pooled, ITT)} on FULL sample with sorteo FE; \(\beta_M\), \(\beta_W\) from interaction OLS on \emph{pre\_employed == 1} sub-sample with sorteo \(\times\) female FE and \emph{female}\(\times\)\emph{winner} interaction; \(\beta_W = \beta_M + \delta\) (coef on muj\_x\_gan), via \emph{lincom}. p-value tests H\(_0\): \(\delta = 0\). Cols (2)/(4)/(6) add \emph{age} as control. Columns (3)/(4) outcome: share of months employed in [lottery date + `k_months', Dec 2025].}" _n
            file write fh "\multicolumn{7}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}" _n
        }
        else {
            file write fh "\multicolumn{4}{p{0.95\textwidth}}{\scriptsize OLS (ITT, reduced form). Sample: `caption_id'. Full controls. \textbf{Winner (pooled, ITT)} on FULL sample; \(\beta_M\), \(\beta_W\) on \emph{pre\_employed == 1} sub-sample with sorteo \(\times\) female FE. Column (2) outcome: share of months employed in [lottery date + `k_months', Dec 2025].}" _n
            file write fh "\multicolumn{4}{l}{\scriptsize \sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)}" _n
        }
        file write fh "\end{tabular}" _n
        file write fh "\end{table}" _n

        file close fh

        di as text "  `out_file' saved"
    }   /* end table_kind loop */

    /*--------------------------------------------------------------------------
      STEP 5b: Save estimates for combined cross-placebo tables (robustness sec)
    --------------------------------------------------------------------------*/
    di as text _n "=== STEP 5b [`placebo_id']: Saving estimates for combined tables ==="

    * --- First stage (no controls) — save to locals for combined table ---
    reghdfe receptor ganador, absorb(sorteo_fe) cluster(id_anon)
    local fs_b_`placebo_id'  = _b[ganador]
    local fs_se_`placebo_id' = _se[ganador]
    local fs_N_`placebo_id'  = e(N)
    quietly sum receptor if ganador == 0
    local fs_cm_`placebo_id' = r(mean)
    cap test ganador
    if _rc == 0 {
        local fs_F_`placebo_id' = r(F)
    }
    else {
        local fs_F_`placebo_id' = .
    }

    * --- ITT (pooled) for combined table — 2 outcomes × 2 specs, save locals ---
    *     Formal Emp, no controls
    reghdfe employed ganador, absorb(sorteo_fe) cluster(id_anon)
    local b_emp_n_`placebo_id'  = _b[ganador]
    local se_emp_n_`placebo_id' = _se[ganador]
    local N_`placebo_id'        = e(N)
    quietly sum employed if ganador == 0
    local cm_emp_`placebo_id'   = r(mean)

    *     Formal Emp, age
    reghdfe employed ganador edad, absorb(sorteo_fe) cluster(id_anon)
    local b_emp_a_`placebo_id'  = _b[ganador]
    local se_emp_a_`placebo_id' = _se[ganador]

    *     Emp Share, no controls
    reghdfe emp_share_`k_label' ganador, absorb(sorteo_fe) cluster(id_anon)
    local b_shr_n_`placebo_id'  = _b[ganador]
    local se_shr_n_`placebo_id' = _se[ganador]
    quietly sum emp_share_`k_label' if ganador == 0
    local cm_shr_`placebo_id'   = r(mean)

    *     Emp Share, age
    reghdfe emp_share_`k_label' ganador edad, absorb(sorteo_fe) cluster(id_anon)
    local b_shr_a_`placebo_id'  = _b[ganador]
    local se_shr_a_`placebo_id' = _se[ganador]

    /*--------------------------------------------------------------------------
      STEP 5c: BCRA outcomes (per placebo)

      Mirrors the §5.2 main analysis (paper_bcra_combined_age.do): 7 ITT
      regressions with age control over the placebo sub-sample.

      All-entities sample: Total Debt, Slow Payer, Banked
      Excl.-Hipotecario sample: Q1-Q4 Cost
    --------------------------------------------------------------------------*/
    di as text _n "=== STEP 5c [`placebo_id']: BCRA outcomes ===" _n

    * --- Person list for this placebo ---
    preserve
        use "$temp/_plac_`placebo_id'_xsec.dta", clear
        keep id_anon
        duplicates drop
        save "$temp/_plac_`placebo_id'_pers_bcra.dta", replace
    restore

    * --- All-entities pass: total_deuda, moroso_ever, active_bcra ---
    use id_anon entidad periodo situacion monto_deuda using "$data/Data_BCRA.dta", clear
    merge m:1 id_anon using "$temp/_plac_`placebo_id'_pers_bcra.dta", keep(match) nogenerate

    * Person-level moroso_ever (max situacion>1 ever)
    preserve
        collapse (max) _max_situ = situacion, by(id_anon)
        gen byte moroso_ever = (_max_situ > 1) if !missing(_max_situ)
        keep id_anon moroso_ever
        save "$temp/_plac_`placebo_id'_moroso.dta", replace
    restore

    * Collapse to person-month: total_deuda
    collapse (sum) total_deuda = monto_deuda, by(id_anon periodo)

    gen int py = floor(periodo / 100)
    gen int pm = mod(periodo, 100)
    gen periodo_month = ym(py, pm)
    format periodo_month %tm
    drop py pm

    * Last period per person
    quietly sum periodo_month
    local max_month = r(max)
    bys id_anon (periodo_month): keep if _n == _N

    * active_bcra = within last 3 months of panel
    gen byte active_bcra = (periodo_month >= `max_month' - 2)

    * Total Debt: zero if last observed period < Nov 2025
    replace total_deuda = 0 if periodo_month < ym(2025, 11)

    * Merge moroso_ever
    merge 1:1 id_anon using "$temp/_plac_`placebo_id'_moroso.dta", keep(master match) nogenerate
    replace moroso_ever = 0 if missing(moroso_ever)

    keep id_anon total_deuda moroso_ever active_bcra
    save "$temp/_plac_`placebo_id'_bcra_all.dta", replace
    erase "$temp/_plac_`placebo_id'_moroso.dta"

    * --- Excl.-Hipotecario pass: Q1-Q4 Cost dummies (last-period semantics) ---
    use id_anon entidad periodo using "$data/Data_BCRA.dta", clear
    merge m:1 id_anon using "$temp/_plac_`placebo_id'_pers_bcra.dta", keep(match) nogenerate

    capture confirm string variable entidad
    if _rc == 0 {
        gen entidad_str = upper(strtrim(entidad))
    }
    else {
        decode entidad, gen(entidad_str)
        replace entidad_str = upper(strtrim(entidad_str))
    }
    replace entidad_str = "BANCO DE GALICIA Y BUENOS AIRES S.A." if entidad_str == "BANCO GGAL SA"

    drop if strpos(entidad_str, "BANCO HIPOTECARIO S.A.") > 0

    merge m:1 entidad_str using "$temp/_plac_q_flags_entity.dta", keep(master match) nogenerate
    foreach v in is_q1 is_q2 is_q3 is_q4 {
        replace `v' = 0 if missing(`v')
    }

    collapse (max) in_q1_costo=is_q1 in_q2_costo=is_q2 in_q3_costo=is_q3 in_q4_costo=is_q4, ///
        by(id_anon periodo)

    gen int py = floor(periodo / 100)
    gen int pm = mod(periodo, 100)
    gen periodo_month = ym(py, pm)
    format periodo_month %tm
    drop py pm
    bys id_anon (periodo_month): keep if _n == _N

    keep id_anon in_q1_costo in_q2_costo in_q3_costo in_q4_costo
    save "$temp/_plac_`placebo_id'_bcra_qcost.dta", replace
    erase "$temp/_plac_`placebo_id'_pers_bcra.dta"

    * --- Join BCRA outcomes to xsec, run ITT regressions ---
    use "$temp/_plac_`placebo_id'_xsec.dta", clear
    merge m:1 id_anon using "$temp/_plac_`placebo_id'_bcra_all.dta", keep(master match) nogenerate
    foreach v in total_deuda moroso_ever active_bcra {
        replace `v' = 0 if missing(`v')
    }
    merge m:1 id_anon using "$temp/_plac_`placebo_id'_bcra_qcost.dta", keep(master match) nogenerate
    foreach v in in_q1_costo in_q2_costo in_q3_costo in_q4_costo {
        replace `v' = 0 if missing(`v')
    }

    * 7 ITT regressions × 3 specs (no ctl, age, full). Age spec drives the
    * tables; the other two are saved as locals for the sensitivity display.
    local bcra_outcomes "total_deuda moroso_ever active_bcra in_q1_costo in_q2_costo in_q3_costo in_q4_costo"
    local j = 0
    foreach v of local bcra_outcomes {
        local ++j
        quietly sum `v' if ganador == 0
        local bcra_cm`j'_`placebo_id' = r(mean)

        * --- age only (PRIMARY, used in .tex tables) ---
        quietly reghdfe `v' ganador edad, absorb(sorteo_fe) cluster(id_anon)
        local bcra_b`j'_`placebo_id'  = _b[ganador]
        local bcra_se`j'_`placebo_id' = _se[ganador]
        local bcra_n`j'_`placebo_id'  = e(N)

        * --- no controls (sensitivity) ---
        quietly reghdfe `v' ganador, absorb(sorteo_fe) cluster(id_anon)
        local bcra_bn`j'_`placebo_id'  = _b[ganador]
        local bcra_sen`j'_`placebo_id' = _se[ganador]
        local bcra_nn`j'_`placebo_id'  = e(N)

        * --- full controls (sensitivity) ---
        quietly reghdfe `v' ganador edad pre_employed pre_wage mujer, absorb(sorteo_fe) cluster(id_anon)
        local bcra_bf`j'_`placebo_id'  = _b[ganador]
        local bcra_sef`j'_`placebo_id' = _se[ganador]
        local bcra_nf`j'_`placebo_id'  = e(N)
    }

    * --- Display 3-spec results to log ---
    di as text _n "  === 3-spec BCRA ITT for `placebo_id' ==="
    di as text "  PARSE: outcome | b_noctl se_noctl | b_age se_age | b_full se_full"
    forvalues j = 1/7 {
        local oname : word `j' of `bcra_outcomes'
        di as text "  PARSE: " "`oname' | " ///
            `bcra_bn`j'_`placebo_id'' " " `bcra_sen`j'_`placebo_id'' " | " ///
            `bcra_b`j'_`placebo_id''  " " `bcra_se`j'_`placebo_id''  " | " ///
            `bcra_bf`j'_`placebo_id'' " " `bcra_sef`j'_`placebo_id''
    }

    * --- Format helpers + significance stars ---
    forvalues j = 1/7 {
        local t = abs(`bcra_b`j'_`placebo_id''/`bcra_se`j'_`placebo_id'')
        if      `t' > 2.576 local bstar`j' "\sym{***}"
        else if `t' > 1.960 local bstar`j' "\sym{**}"
        else if `t' > 1.645 local bstar`j' "\sym{*}"
        else                local bstar`j' ""
    }
    * Total Debt: large nominal, %9.1fc. Others: proportions.
    local bf1  : display %9.1fc `bcra_b1_`placebo_id''
    local bsef1: display %9.1fc `bcra_se1_`placebo_id''
    local bcmf1: display %9.1fc `bcra_cm1_`placebo_id''
    forvalues j = 2/7 {
        local bf`j'  : display %9.4f `bcra_b`j'_`placebo_id''
        local bsef`j': display %9.4f `bcra_se`j'_`placebo_id''
        local bcmf`j': display %6.4f `bcra_cm`j'_`placebo_id''
    }
    local bnf : display %12.0fc `bcra_n1_`placebo_id''

    * --- Per-placebo BCRA table ---
    capture file close fh
    file open fh using "$tables/placebo_bcra`out_sfx'.tex", write replace

    file write fh "\begin{table}[H]\centering" _n
    file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
    file write fh "\caption{BCRA Outcomes (ITT) --- `caption_id'}" _n
    file write fh "\label{tab:placebo_bcra`out_sfx'}" _n
    file write fh "\scriptsize" _n
    file write fh "\setlength{\tabcolsep}{0pt}" _n
    file write fh "\begin{tabular}{@{}l*{7}{>{\centering\arraybackslash}p{0.108\textwidth}}@{}}" _n
    file write fh "\hline\hline" _n
    file write fh " & Total Debt & Slow Payer & Banked & Q1 Cost & Q2 Cost & Q3 Cost & Q4 Cost \\" _n
    file write fh " & (1) & (2) & (3) & (4) & (5) & (6) & (7) \\" _n
    file write fh "\hline" _n
    file write fh "Winner & `bf1'`bstar1' & `bf2'`bstar2' & `bf3'`bstar3' & `bf4'`bstar4' & `bf5'`bstar5' & `bf6'`bstar6' & `bf7'`bstar7' \\" _n
    file write fh "       & (`bsef1') & (`bsef2') & (`bsef3') & (`bsef4') & (`bsef5') & (`bsef6') & (`bsef7') \\" _n
    file write fh "\hline" _n
    file write fh "Control mean & `bcmf1' & `bcmf2' & `bcmf3' & `bcmf4' & `bcmf5' & `bcmf6' & `bcmf7' \\" _n
    file write fh "Observations & `bnf' & `bnf' & `bnf' & `bnf' & `bnf' & `bnf' & `bnf' \\" _n
    file write fh "\hline\hline" _n
    file write fh "\end{tabular}" _n
    file write fh "\par\smallskip" _n
    file write fh "\begin{minipage}{0.98\textwidth}" _n
    file write fh "\scriptsize" _n
    file write fh "OLS (ITT, reduced form). Sample: `caption_id'. All specifications include age at lottery date as the sole covariate plus lottery FE. \emph{Total Debt}: sum of debt outstanding in nominal ARS across BCRA-registered entities at the last period the applicant is observed; set to zero if the last observed period is before November 2025. \emph{Slow Payer}: indicator equal to one if the applicant had BCRA situation code \(> 1\) (code 2/3/4/5) at any point in the panel; applicants with no BCRA record are coded as 0. \emph{Banked}: indicator for an active credit record at the end of the panel. \emph{Q-X Cost}: indicator equal to one if the applicant holds any debt at an entity whose median CFT lies in the X-th quartile of the cost distribution at the last BCRA period the applicant is observed; cutoffs as in the main analysis. Cost-quartile columns use the excl.-Hipotecario sample. SE clustered at person level (parentheses).\\" _n
    file write fh "\sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)" _n
    file write fh "\end{minipage}" _n
    file write fh "\end{table}" _n
    file close fh

    di as text "  placebo_bcra`out_sfx'.tex saved"

    cap erase "$temp/_plac_`placebo_id'_bcra_all.dta"
    cap erase "$temp/_plac_`placebo_id'_bcra_qcost.dta"

    /*--------------------------------------------------------------------------
      STEP 5d: Fertility outcome (per placebo)

      Mirrors paper_hijos_outcomes.do main spec on n_kids_post:
        n_kids_post = n_kids_2024 - n_kids_at_sorteo
        ITT specs: noctl / age / age + n_kids_pre  (primary)
      Source: $temp/_plac_proc_kids_panel.dta (built once in STEP 1.6).

      Caveat: all three placebos are 2023 sorteos, so n_kids_post is
      observed over a single calendar year (2024 only).
    --------------------------------------------------------------------------*/
    di as text _n "=== STEP 5d [`placebo_id']: Fertility outcome ===" _n

    use "$temp/_plac_`placebo_id'_xsec.dta", clear

    * --- 1. n_kids_pre = n_kids at year = cohort_year - 1 ---
    preserve
        use "$temp/_plac_proc_kids_panel.dta", clear
        rename year cohort_year_minus_1
        rename n_kids n_kids_pre
        tempfile _kids_pre
        save `_kids_pre'
    restore

    gen int cohort_year_minus_1 = cohort_year - 1
    merge m:1 cuil_num cohort_year_minus_1 using `_kids_pre', ///
        keep(master match) nogenerate
    replace n_kids_pre = 0 if missing(n_kids_pre)
    drop cohort_year_minus_1

    * --- 2. n_kids_at_sorteo = n_kids at year = cohort_year ---
    preserve
        use "$temp/_plac_proc_kids_panel.dta", clear
        rename year cohort_year
        rename n_kids n_kids_at_sorteo
        tempfile _kids_at
        save `_kids_at'
    restore

    merge m:1 cuil_num cohort_year using `_kids_at', ///
        keep(master match) nogenerate
    replace n_kids_at_sorteo = 0 if missing(n_kids_at_sorteo)

    * --- 3. n_kids_2024 = n_kids at year = 2024 ---
    preserve
        use "$temp/_plac_proc_kids_panel.dta", clear
        keep if year == 2024
        keep cuil_num n_kids
        rename n_kids n_kids_2024
        tempfile _kids_24
        save `_kids_24'
    restore

    merge m:1 cuil_num using `_kids_24', ///
        keep(master match) nogenerate
    replace n_kids_2024 = 0 if missing(n_kids_2024)

    gen int n_kids_post = n_kids_2024 - n_kids_at_sorteo
    gen byte had_kid_post = (n_kids_post > 0)

    di as text "    Fertility descriptives [`placebo_id']:"
    sum n_kids_pre n_kids_at_sorteo n_kids_2024 n_kids_post had_kid_post

    * --- Run ITT for n_kids_post (3 specs) ---
    * (1) no controls
    reghdfe n_kids_post ganador, absorb(sorteo_fe) cluster(id_anon)
    local hijos_b_n_`placebo_id'  = _b[ganador]
    local hijos_se_n_`placebo_id' = _se[ganador]
    local hijos_n_n_`placebo_id'  = e(N)

    * (2) age
    reghdfe n_kids_post ganador edad, absorb(sorteo_fe) cluster(id_anon)
    local hijos_b_a_`placebo_id'  = _b[ganador]
    local hijos_se_a_`placebo_id' = _se[ganador]
    local hijos_n_a_`placebo_id'  = e(N)

    * (3) age + n_kids_pre (PRIMARY, matches table_n_kids_after.tex)
    reghdfe n_kids_post ganador edad n_kids_pre, absorb(sorteo_fe) cluster(id_anon)
    local hijos_b_p_`placebo_id'  = _b[ganador]
    local hijos_se_p_`placebo_id' = _se[ganador]
    local hijos_n_p_`placebo_id'  = e(N)

    * Control mean (ganador == 0)
    quietly sum n_kids_post if ganador == 0
    local hijos_cm_`placebo_id' = r(mean)

    di as text "    n_kids_post ITT for `placebo_id':"
    di as text "      noctl: b=" %9.4f `hijos_b_n_`placebo_id'' " se=" %9.4f `hijos_se_n_`placebo_id''
    di as text "      age:   b=" %9.4f `hijos_b_a_`placebo_id'' " se=" %9.4f `hijos_se_a_`placebo_id''
    di as text "      a+pre: b=" %9.4f `hijos_b_p_`placebo_id'' " se=" %9.4f `hijos_se_p_`placebo_id''
    di as text "      cm:    " %9.4f `hijos_cm_`placebo_id''

    * --- Per-placebo fertility table (1 outcome x 3 specs) ---
    forvalues k = 1/3 {
        if `k' == 1 {
            local b_disp = `hijos_b_n_`placebo_id''
            local se_disp = `hijos_se_n_`placebo_id''
            local n_disp = `hijos_n_n_`placebo_id''
        }
        else if `k' == 2 {
            local b_disp = `hijos_b_a_`placebo_id''
            local se_disp = `hijos_se_a_`placebo_id''
            local n_disp = `hijos_n_a_`placebo_id''
        }
        else {
            local b_disp = `hijos_b_p_`placebo_id''
            local se_disp = `hijos_se_p_`placebo_id''
            local n_disp = `hijos_n_p_`placebo_id''
        }
        local b_f`k'  : display %9.4f `b_disp'
        local se_f`k' : display %9.4f `se_disp'
        local n_f`k'  : display %12.0fc `n_disp'
        local t = abs(`b_disp'/`se_disp')
        if      `t' > 2.576 local stars_`k' "\sym{***}"
        else if `t' > 1.960 local stars_`k' "\sym{**}"
        else if `t' > 1.645 local stars_`k' "\sym{*}"
        else                local stars_`k' ""
    }
    local cm_f : display %6.4f `hijos_cm_`placebo_id''

    capture file close fh
    file open fh using "$tables/placebo_hijos`out_sfx'.tex", write replace

    file write fh "\begin{table}[H]\centering" _n
    file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
    file write fh "\caption{Fertility Outcome (ITT) --- `caption_id'}" _n
    file write fh "\label{tab:placebo_hijos`out_sfx'}" _n
    file write fh "\scriptsize" _n
    file write fh "\setlength{\tabcolsep}{0pt}" _n
    file write fh "\begin{tabular}{@{}l*{3}{>{\centering\arraybackslash}p{0.20\textwidth}}@{}}" _n
    file write fh "\hline\hline" _n
    file write fh " & \multicolumn{3}{c}{\# Kids After} \\" _n
    file write fh "\cline{2-4}" _n
    file write fh " & (1) & (2) & (3) \\" _n
    file write fh "\hline" _n
    file write fh "Winner & `b_f1'`stars_1' & `b_f2'`stars_2' & `b_f3'`stars_3' \\" _n
    file write fh "       & (`se_f1') & (`se_f2') & (`se_f3') \\" _n
    file write fh "\hline" _n
    file write fh "Control mean & \multicolumn{3}{c}{`cm_f'} \\" _n
    file write fh "Observations & `=strtrim("`n_f1'")' & `=strtrim("`n_f2'")' & `=strtrim("`n_f3'")' \\" _n
    file write fh "Controls for age &  & \checkmark & \checkmark \\" _n
    file write fh "Pre-lottery \# children &  &  & \checkmark \\" _n
    file write fh "\hline\hline" _n
    file write fh "\end{tabular}" _n
    file write fh "\par\smallskip" _n
    file write fh "\begin{minipage}{0.95\textwidth}" _n
    file write fh "\scriptsize" _n
    file write fh "OLS (ITT, reduced form). Sample: `caption_id'. Outcome: number of children born strictly after the lottery year (\(n\_kids\_post = n\_kids\_2024 - n\_kids\_at\_sorteo\)), computed from the civil-registry of births aggregated to a CUIL \(\times\) calendar-year cumulative-children panel. The outcome window varies by lottery year (one calendar year for 2023 sorteos; up to four for earlier sorteos). Lottery FE absorbed; SE clustered at person level (parentheses).\\" _n
    file write fh "\sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)" _n
    file write fh "\end{minipage}" _n
    file write fh "\end{table}" _n
    file close fh

    di as text "  placebo_hijos`out_sfx'.tex saved"

    /* Per-placebo cleanup */
    cap erase "$temp/_plac_`placebo_id'_sorteo.dta"
    cap erase "$temp/_plac_`placebo_id'_sipa.dta"
    cap erase "$temp/_plac_`placebo_id'_xsec.dta"
    cap erase "$temp/_plac_`placebo_id'_outcomes.dta"

}   /* end placebo loop */


/*==============================================================================
  STEP 6: COMBINED TABLES FOR ROBUSTNESS SECTION

  Two compact tables that lay the three sorteos side by side:

    placebo_fs_combined.tex   — 3 first stages (Nov 23 / Sep 26 DU / Dec 4 DU)
    placebo_itt_combined.tex  — ITT pooled, 2 outcomes (Formal Emp + Emp Share)
                                × 2 specs (no ctl, age ctl), 3 sorteos in cols
==============================================================================*/

di as text _n(2) "=== STEP 6: Building combined cross-placebo tables ===" _n

* --- Table 1: Combined first stage (3 cols) via file_write ---
capture file close fh
file open fh using "$tables/placebo_fs_combined.tex", write replace

file write fh "\begin{table}[H]\centering" _n
file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
file write fh "\caption{First Stage Comparison Across Two Placebos}" _n
file write fh "\label{tab:placebo_fs_combined}" _n
file write fh "\scriptsize" _n
file write fh "\setlength{\tabcolsep}{0pt}" _n
file write fh "\begin{tabular}{@{}l*{2}{>{\centering\arraybackslash}p{0.25\textwidth}}@{}}" _n
file write fh "\hline\hline" _n
file write fh " & SAGOL II & Zero Take-up \\" _n
file write fh " & (1) & (2) \\" _n
file write fh "\hline" _n

* coefficient row + stars
local fs_row "Winner"
local fs_serow ""
foreach pid in "sagol" "zero_recep" {
    local b  = `fs_b_`pid''
    local se = `fs_se_`pid''
    local stars ""
    if (`se' > 0 & !missing(`se')) {
        local t = abs(`b' / `se')
        if (`t' > 2.576)      local stars "\sym{***}"
        else if (`t' > 1.960) local stars "\sym{**}"
        else if (`t' > 1.645) local stars "\sym{*}"
    }
    local b_str  = string(`b', "%9.4f")
    local se_str = string(`se', "%9.4f")
    local fs_row   "`fs_row' & `b_str'`stars'"
    local fs_serow "`fs_serow' & (`se_str')"
}
file write fh "`fs_row' \\" _n
file write fh " `fs_serow' \\[0.3em]" _n
file write fh "\hline" _n

* control mean / F / N rows
local cm_row "Control mean (losers)"
local F_row  "F-statistic"
local N_row  "Observations"
foreach pid in "sagol" "zero_recep" {
    local cm_str = string(`fs_cm_`pid'', "%9.4f")
    local N_str  = string(`fs_N_`pid'',  "%9.0fc")
    local cm_row "`cm_row' & `cm_str'"
    local N_row  "`N_row' & `N_str'"
    if missing(`fs_F_`pid'') {
        local F_row "`F_row' & "
    }
    else {
        local F_str = string(`fs_F_`pid'', "%9.1f")
        local F_row "`F_row' & `F_str'"
    }
}
file write fh "`cm_row' \\" _n
file write fh "`F_row' \\" _n
file write fh "`N_row' \\" _n
file write fh "\hline\hline" _n
file write fh "\end{tabular}" _n
file write fh "\par\smallskip" _n
file write fh "\begin{minipage}{0.85\textwidth}" _n
file write fh "\scriptsize" _n
file write fh "OLS first stage. Outcome: \emph{recipient} (= 1 if applicant received PROCREAR credit). Two placebos: SAGOL II (Nov 23 2023 sorteo, any type, credits never disbursed) and Zero Take-up (all sorteo\_fe groups whose winners did not draw down credit). Both coefficients are mechanically 0 because no credit was disbursed within these sample restrictions. No additional controls; lottery FE absorbed; SE clustered at person level.\\" _n
file write fh "\sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)" _n
file write fh "\end{minipage}" _n
file write fh "\end{table}" _n
file close fh

di as text "  placebo_fs_combined.tex saved"


* --- Table 2: Combined ITT — 7 cols (paired by sorteo × {no ctl, age ctl}),
*     controls indicated by a row, not by separate rows -------------------- *
capture file close fh
file open fh using "$tables/placebo_itt_combined.tex", write replace

file write fh "\begin{table}[H]\centering" _n
file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
file write fh "\caption{Labor ITT Comparison Across Two Placebos (Pooled)}" _n
file write fh "\label{tab:placebo_itt_combined}" _n
file write fh "\scriptsize" _n
file write fh "\setlength{\tabcolsep}{0pt}" _n
file write fh "\begin{tabular*}{0.95\textwidth}{@{\extracolsep{\fill}}l*{4}{c}@{}}" _n
file write fh "\hline\hline" _n
file write fh " & \multicolumn{2}{c}{SAGOL II} & \multicolumn{2}{c}{Zero Take-up} \\" _n
file write fh "\cmidrule(lr){2-3}\cmidrule(lr){4-5}" _n
file write fh " & (1) & (2) & (3) & (4) \\" _n
file write fh "\hline" _n

local plist "sagol zero_recep"

* Helper: writes a single Winner row (4 cols: alternating no ctl / age ctl
* per placebo). Outcome prefix is `oprefix' (= "emp" or "shr").
* coefs come from `b_`oprefix'_n_`p'' and `b_`oprefix'_a_`p''.

* --- Panel A: Formal Emp ---
file write fh "\multicolumn{5}{l}{\textit{Panel A: Formal Emp}} \\" _n
file write fh "\hline" _n

* coefficient row: 4 values
file write fh "Winner"
foreach p of local plist {
    foreach c in "n" "a" {
        local b : display %9.4f `b_emp_`c'_`p''
        local t = abs(`b_emp_`c'_`p''/`se_emp_`c'_`p'')
        if `t' > 2.576      local s "\sym{***}"
        else if `t' > 1.960 local s "\sym{**}"
        else if `t' > 1.645 local s "\sym{*}"
        else                local s ""
        file write fh " & `b'`s'"
    }
}
file write fh " \\" _n
file write fh "    "
foreach p of local plist {
    foreach c in "n" "a" {
        local se : display %9.4f `se_emp_`c'_`p''
        file write fh " & (`se')"
    }
}
file write fh " \\" _n
file write fh "\hline" _n

* --- Panel B: Emp Share ---
file write fh "\multicolumn{5}{l}{\textit{Panel B: Emp Share (`k_months'm+)}} \\" _n
file write fh "\hline" _n

file write fh "Winner"
foreach p of local plist {
    foreach c in "n" "a" {
        local b : display %9.4f `b_shr_`c'_`p''
        local t = abs(`b_shr_`c'_`p''/`se_shr_`c'_`p'')
        if `t' > 2.576      local s "\sym{***}"
        else if `t' > 1.960 local s "\sym{**}"
        else if `t' > 1.645 local s "\sym{*}"
        else                local s ""
        file write fh " & `b'`s'"
    }
}
file write fh " \\" _n
file write fh "    "
foreach p of local plist {
    foreach c in "n" "a" {
        local se : display %9.4f `se_shr_`c'_`p''
        file write fh " & (`se')"
    }
}
file write fh " \\" _n
file write fh "\hline" _n

* --- Diagnostics: control means + N use multicolumn{2} per placebo --- *
file write fh "Control mean (Formal Emp)"
foreach p of local plist {
    local cm : display %5.3f `cm_emp_`p''
    file write fh " & \multicolumn{2}{c}{`cm'}"
}
file write fh " \\" _n

file write fh "Control mean (Emp Share)"
foreach p of local plist {
    local cm : display %5.3f `cm_shr_`p''
    file write fh " & \multicolumn{2}{c}{`cm'}"
}
file write fh " \\" _n

file write fh "Observations"
foreach p of local plist {
    local n : display %12.0fc `N_`p''
    file write fh " & \multicolumn{2}{c}{`=strtrim("`n'")'}"
}
file write fh " \\" _n

* Controls-as-column row (checkmark under even-indexed col per placebo)
file write fh "Controls for age & & \checkmark & & \checkmark \\" _n

file write fh "\hline\hline" _n
file write fh "\end{tabular*}" _n
file write fh "\par\smallskip" _n
file write fh "\begin{minipage}{0.95\textwidth}" _n
file write fh "\scriptsize" _n
file write fh "OLS (ITT, reduced form). Two placebos: SAGOL II (Nov 23 2023 sorteo, any type, credits never disbursed); Zero Take-up (all sorteo\_fe groups whose winners did not draw down credit). Lottery FE absorbed; SE clustered at person level (in parentheses). Panel B outcome: share of months employed in [lottery date + `k_months', Dec 2025].\\" _n
file write fh "\sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)" _n
file write fh "\end{minipage}" _n
file write fh "\end{table}" _n

file close fh

di as text "  placebo_itt_combined.tex saved"


/*==============================================================================
  STEP 7: COMBINED CROSS-PLACEBO BCRA TABLE
==============================================================================*/

di as text _n(2) "=== STEP 7: Combined BCRA cross-placebo table ===" _n

capture file close fh
file open fh using "$tables/placebo_bcra_combined.tex", write replace

file write fh "\begin{table}[H]\centering" _n
file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
file write fh "\caption{BCRA Outcomes (ITT): Comparison Across Two Placebos}" _n
file write fh "\label{tab:placebo_bcra_combined}" _n
file write fh "\scriptsize" _n
file write fh "\setlength{\tabcolsep}{0pt}" _n
file write fh "\begin{tabular*}{0.95\textwidth}{@{\extracolsep{\fill}}l*{4}{c}@{}}" _n
file write fh "\hline\hline" _n
file write fh " & \multicolumn{2}{c}{SAGOL II} & \multicolumn{2}{c}{Zero Take-up} \\" _n
file write fh "\cmidrule(lr){2-3}\cmidrule(lr){4-5}" _n
file write fh " & (1) & (2) & (3) & (4) \\" _n
file write fh "\hline" _n

local outc_label_1 "Total Debt"
local outc_label_2 "Slow Payer"
local outc_label_3 "Banked"

local plist "sagol zero_recep"

* --- Coefficient + SE rows (3 outcomes, each shown in 2 specs: noctl + age) ---
forvalues j = 1/3 {
    if `j' == 1 {
        local fmt_b  "%9.1fc"
        local fmt_se "%9.1fc"
    }
    else {
        local fmt_b  "%9.4f"
        local fmt_se "%9.4f"
    }

    * coefficient row
    file write fh "`outc_label_`j''"
    foreach p of local plist {
        * spec 1: no controls
        local bv  : display `fmt_b' `bcra_bn`j'_`p''
        local t   = abs(`bcra_bn`j'_`p''/`bcra_sen`j'_`p'')
        if      `t' > 2.576 local s "\sym{***}"
        else if `t' > 1.960 local s "\sym{**}"
        else if `t' > 1.645 local s "\sym{*}"
        else                local s ""
        file write fh " & `bv'`s'"

        * spec 2: age only
        local bv  : display `fmt_b' `bcra_b`j'_`p''
        local t   = abs(`bcra_b`j'_`p''/`bcra_se`j'_`p'')
        if      `t' > 2.576 local s "\sym{***}"
        else if `t' > 1.960 local s "\sym{**}"
        else if `t' > 1.645 local s "\sym{*}"
        else                local s ""
        file write fh " & `bv'`s'"
    }
    file write fh " \\" _n

    * SE row
    file write fh "    "
    foreach p of local plist {
        local sev : display `fmt_se' `bcra_sen`j'_`p''
        file write fh " & (`sev')"
        local sev : display `fmt_se' `bcra_se`j'_`p''
        file write fh " & (`sev')"
    }
    file write fh " \\" _n
    if `j' < 3 file write fh "[0.3em]" _n
}

file write fh "\hline" _n

* --- Control means (one row per outcome, value spans both specs) ---
forvalues j = 1/3 {
    if `j' == 1 local fmt_cm "%9.1fc"
    else        local fmt_cm "%6.4f"
    file write fh "Control mean (`outc_label_`j'')"
    foreach p of local plist {
        local cmv : display `fmt_cm' `bcra_cm`j'_`p''
        file write fh " & \multicolumn{2}{c}{`cmv'}"
    }
    file write fh " \\" _n
}

* --- Observations ---
file write fh "Observations"
foreach p of local plist {
    local nv : display %12.0fc `bcra_n1_`p''
    file write fh " & \multicolumn{2}{c}{`=strtrim("`nv'")'}"
}
file write fh " \\" _n

* --- Controls-as-column row ---
file write fh "Controls for age & & \checkmark & & \checkmark \\" _n

file write fh "\hline\hline" _n
file write fh "\end{tabular*}" _n
file write fh "\par\smallskip" _n
file write fh "\begin{minipage}{0.95\textwidth}" _n
file write fh "\scriptsize" _n
file write fh "OLS (ITT, reduced form). Two placebos: SAGOL II (Nov 23 2023 sorteo, any type, credits never disbursed); Zero Take-up (all sorteo\_fe groups whose winners did not draw down credit). Lottery FE absorbed; SE clustered at person level (parentheses). \emph{Total Debt}: sum of debt outstanding in nominal ARS across BCRA-registered entities at the last period the applicant is observed (zero if before November 2025). \emph{Slow Payer}: indicator equal to one if the applicant had BCRA situation code \(> 1\) (code 2/3/4/5) at any point in the panel; applicants with no BCRA record are coded as 0. \emph{Banked}: indicator for an active credit record at the end of the panel.\\" _n
file write fh "\sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)" _n
file write fh "\end{minipage}" _n
file write fh "\end{table}" _n
file close fh

di as text "  placebo_bcra_combined.tex saved"


/*==============================================================================
  STEP 8: COMBINED CROSS-PLACEBO FERTILITY TABLE
==============================================================================*/

di as text _n(2) "=== STEP 8: Combined fertility cross-placebo table ===" _n

local plist "sagol zero_recep"

capture file close fh
file open fh using "$tables/placebo_hijos_combined.tex", write replace

file write fh "\begin{table}[H]\centering" _n
file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
file write fh "\caption{Fertility ITT Comparison Across Two Placebos}" _n
file write fh "\label{tab:placebo_hijos_combined}" _n
file write fh "\scriptsize" _n
file write fh "\setlength{\tabcolsep}{0pt}" _n
file write fh "\begin{tabular*}{0.95\textwidth}{@{\extracolsep{\fill}}l*{4}{c}@{}}" _n
file write fh "\hline\hline" _n
file write fh " & \multicolumn{2}{c}{SAGOL II} & \multicolumn{2}{c}{Zero Take-up} \\" _n
file write fh "\cmidrule(lr){2-3}\cmidrule(lr){4-5}" _n
file write fh " & (1) & (2) & (3) & (4) \\" _n
file write fh "\hline" _n

* Winner row: 4 values (2 placebos x 2 specs: noctl + age)
file write fh "Winner"
foreach p of local plist {
    foreach c in "n" "a" {
        local b : display %9.4f `hijos_b_`c'_`p''
        local t = abs(`hijos_b_`c'_`p''/`hijos_se_`c'_`p'')
        if      `t' > 2.576 local s "\sym{***}"
        else if `t' > 1.960 local s "\sym{**}"
        else if `t' > 1.645 local s "\sym{*}"
        else                local s ""
        file write fh " & `b'`s'"
    }
}
file write fh " \\" _n
file write fh "    "
foreach p of local plist {
    foreach c in "n" "a" {
        local se : display %9.4f `hijos_se_`c'_`p''
        file write fh " & (`se')"
    }
}
file write fh " \\" _n

file write fh "\hline" _n

* Control mean (spans both specs per placebo)
file write fh "Control mean"
foreach p of local plist {
    local cm : display %6.4f `hijos_cm_`p''
    file write fh " & \multicolumn{2}{c}{`cm'}"
}
file write fh " \\" _n

* Observations (spans both specs per placebo)
file write fh "Observations"
foreach p of local plist {
    local n : display %12.0fc `hijos_n_a_`p''
    file write fh " & \multicolumn{2}{c}{`=strtrim("`n'")'}"
}
file write fh " \\" _n

* Controls for age row
file write fh "Controls for age & & \checkmark & & \checkmark \\" _n

file write fh "\hline\hline" _n
file write fh "\end{tabular*}" _n
file write fh "\par\smallskip" _n
file write fh "\begin{minipage}{0.95\textwidth}" _n
file write fh "\scriptsize" _n
file write fh "OLS (ITT, reduced form). Two placebos: SAGOL II (Nov 23 2023 sorteo, any type, credits never disbursed); Zero Take-up (all sorteo\_fe groups whose winners did not draw down credit). Outcome: number of children born strictly after the lottery year (\(n\_kids\_post = n\_kids\_2024 - n\_kids\_at\_sorteo\)), computed from the civil-registry of births. Lottery FE absorbed; SE clustered at person level (parentheses).\\" _n
file write fh "\sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)" _n
file write fh "\end{minipage}" _n
file write fh "\end{table}" _n
file close fh

di as text "  placebo_hijos_combined.tex saved"


/*==============================================================================
  CLEANUP
==============================================================================*/

cap erase "$temp/_plac_deflator.dta"
cap erase "$temp/_plac_q_flags_entity.dta"
cap erase "$temp/_plac_proc_kids_panel.dta"

di as text _n(3) "============================================================"
di as text       "  PLACEBO RUN — COMPLETE"
di as text       "============================================================"
di as text _n "Tables produced (in $tables/):"
di as text _n "  SAGOL II (Nov 23 2023, no credits disbursed):"
di as text "    placebo_first_stage_sagol.tex"
di as text "    placebo_main_sagol.tex"
di as text "    placebo_main_full_sagol.tex"
di as text "    placebo_bcra_sagol.tex"
di as text "    placebo_hijos_sagol.tex"
di as text _n "  Zero Take-up (all sorteo_fe with sum(receptor)=0):"
di as text "    placebo_first_stage_zero_recep.tex"
di as text "    placebo_main_zero_recep.tex"
di as text "    placebo_main_full_zero_recep.tex"
di as text "    placebo_bcra_zero_recep.tex"
di as text "    placebo_hijos_zero_recep.tex"
di as text _n "  Combined (robustness section):"
di as text "    placebo_fs_combined.tex     — 2 first stages side by side"
di as text "    placebo_itt_combined.tex    — 2 labor ITTs × 2 outcomes × 2 specs"
di as text "    placebo_bcra_combined.tex   — 2 BCRA ITTs × 3 outcomes × 2 specs"
di as text "    placebo_hijos_combined.tex  — 2 fertility ITTs × 2 specs"
di as text _n "Interpretation:"
di as text "  All coefficients should be ≈ 0 — both placebos have zero first stage."
di as text "  SAGOL II identifies off one sharp lottery, Zero Take-up off all"
di as text "  sorteo_fe groups with zero receptores (larger N, more power)."
di as text "============================================================"
