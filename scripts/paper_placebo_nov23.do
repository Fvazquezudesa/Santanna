/*==============================================================================
  PROCREAR — PLACEBO + COMPARISON SORTEOS

  Self-contained: builds all datasets from raw DATA/ files.

  Runs the same ITT analysis (matching paper_labor_outcomes.do spec) on
  THREE sorteos:

    1. nov23     — Nov 23, 2023 (any tipo). Credits NEVER disbursed
                   (Banco Hipotecario was frozen). receptor = 0 for ALL.
                   Pure placebo: first stage should be ≈ 0.
                   ITT should be ≈ 0 if exclusion restriction holds.

    2. sep26_du  — Sep 26, 2023 (tipo == 5, i.e. DU). Credits disbursed.
                   First stage > 0. ITT should match main paper magnitude.

    3. dec4_du   — Dec 4, 2023 (tipo == 5, i.e. DU). Credits disbursed.
                   First stage > 0. ITT should match main paper magnitude.

  The two DU sorteos in 2023 are temporally close to the Nov 23 placebo
  and serve as a positive control: same window, same era, same DU type,
  but disbursement actually happened. Comparing ITT across these three
  validates that the placebo's null is due to non-disbursement, not the
  era or sample composition.

  Each placebo run produces THREE tables, sharing the same structure as
  paper_labor_outcomes.do:
    placebo_first_stage<sfx>.tex   — receptor on ganador (3 specs)
    placebo_main<sfx>.tex          — ITT pooled + gender (body, 2 specs)
    placebo_main_full<sfx>.tex     — same with full controls (appendix)

  Sufixes:
    nov23     → no suffix (`placebo_first_stage.tex`)
    sep26_du  → `_sep26_du`
    dec4_du   → `_dec4_du`

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
  PLACEBO LOOP — for each of nov23 / sep26_du / dec4_du, run steps 2-5
==============================================================================*/

foreach placebo_id in "nov23" "sep26_du" "dec4_du" {

    * --- Per-placebo configuration ---
    if "`placebo_id'" == "nov23" {
        local filter "_month == 11 & _day == 23"
        local out_sfx ""
        local caption_id "Nov 23 2023 Sorteo, No Credit Disbursed"
        local fs_note "credits never disbursed, so \emph{receptor} = 0 for everyone"
        local fs_expected "The coefficient should be \(\approx\) 0 by construction"
    }
    else if "`placebo_id'" == "sep26_du" {
        local filter "_month == 9 & _day == 26 & tipo == 5"
        local out_sfx "_sep26_du"
        local caption_id "Sep 26 2023 Sorteo (DU only, Comparison)"
        local fs_note "credits disbursed (DU sorteo from Sep 26 2023)"
        local fs_expected "The coefficient should match the main sample's \(\approx\) 0.34"
    }
    else if "`placebo_id'" == "dec4_du" {
        local filter "_month == 12 & _day == 4 & tipo == 5"
        local out_sfx "_dec4_du"
        local caption_id "Dec 4 2023 Sorteo (DU only, Comparison)"
        local fs_note "credits disbursed (DU sorteo from Dec 4 2023)"
        local fs_expected "The coefficient should match the main sample's \(\approx\) 0.34"
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

    replace monotributo = . if monotributo == 24
    replace monotributo = . if monotributo == 1
    gen byte is_monotributo = (monotributo > 0 & monotributo != .)

    * --- Filter ---
    gen _day = day(fecha_sorteo)
    gen _month = month(fecha_sorteo)

    keep if `filter'
    drop _day _month

    if _N == 0 {
        di as error "ERROR: No sorteos for placebo `placebo_id' (filter: `filter')."
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
    keep id_anon ganador receptor sorteo_fe tipo tipo_grupo sorteo_month ///
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
file write fh "\caption{First Stage Comparison Across Three Lotteries}" _n
file write fh "\label{tab:placebo_fs_combined}" _n
file write fh "\scriptsize" _n
file write fh "\setlength{\tabcolsep}{0pt}" _n
file write fh "\begin{tabular}{@{}l*{3}{>{\centering\arraybackslash}p{0.20\textwidth}}@{}}" _n
file write fh "\hline\hline" _n
file write fh " & Nov 23 (placebo) & Sep 26 & Dec 4 \\" _n
file write fh " & (1) & (2) & (3) \\" _n
file write fh "\hline" _n

* coefficient row + stars
local fs_row "Ganador"
local fs_serow ""
foreach pid in "nov23" "sep26_du" "dec4_du" {
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
foreach pid in "nov23" "sep26_du" "dec4_du" {
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
file write fh "OLS first stage. Outcome: \emph{recipient} (= 1 if applicant received PROCREAR credit). Three contemporaneous 2023 lotteries: Nov 23 (any type, credits never disbursed); Sep 26 (DU only); Dec 4 (DU only). The Nov 23 lottery coefficient is mechanically 0 because no credits were disbursed. The other two should match the main-sample first stage of \(\approx\) 0.34. No additional controls; lottery FE absorbed; SE clustered at person level.\\" _n
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
file write fh "\caption{ITT Comparison Across Three Lotteries (Pooled)}" _n
file write fh "\label{tab:placebo_itt_combined}" _n
file write fh "\scriptsize" _n
file write fh "\setlength{\tabcolsep}{0pt}" _n
file write fh "\begin{tabular*}{0.95\textwidth}{@{\extracolsep{\fill}}l*{6}{c}@{}}" _n
file write fh "\hline\hline" _n
file write fh " & \multicolumn{2}{c}{Nov 23 (placebo)} & \multicolumn{2}{c}{Sep 26} & \multicolumn{2}{c}{Dec 4} \\" _n
file write fh "\cmidrule(lr){2-3}\cmidrule(lr){4-5}\cmidrule(lr){6-7}" _n
file write fh " & (1) & (2) & (3) & (4) & (5) & (6) \\" _n
file write fh "\hline" _n

local plist "nov23 sep26_du dec4_du"

* Helper: writes a single Ganador row (6 cols: alternating no ctl / age ctl
* per sorteo). Outcome prefix is `oprefix' (= "emp" or "shr").
* coefs come from `b_`oprefix'_n_`p'' and `b_`oprefix'_a_`p''.

* --- Panel A: Formal Emp ---
file write fh "\multicolumn{7}{l}{\textit{Panel A: Formal Emp}} \\" _n
file write fh "\hline" _n

* coefficient row: 6 values
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
file write fh "\multicolumn{7}{l}{\textit{Panel B: Emp Share (`k_months'm+)}} \\" _n
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

* --- Diagnostics: control means + N use multicolumn{2} per sorteo -------- *
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

* Controls-as-column-row (checkmark under even-indexed col per sorteo)
file write fh "Controls for age & & \checkmark & & \checkmark & & \checkmark \\" _n

file write fh "\hline\hline" _n
file write fh "\end{tabular*}" _n
file write fh "\par\smallskip" _n
file write fh "\begin{minipage}{0.95\textwidth}" _n
file write fh "\scriptsize" _n
file write fh "OLS (ITT, reduced form). Three contemporaneous 2023 lotteries: Nov 23 (any type, credits never disbursed); Sep 26 (DU only, credits disbursed); Dec 4 (DU only, credits disbursed). Lottery FE absorbed; SE clustered at person level (in parentheses). Panel B outcome: share of months employed in [lottery date + `k_months', Dec 2025].\\" _n
file write fh "\sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)" _n
file write fh "\end{minipage}" _n
file write fh "\end{table}" _n

file close fh

di as text "  placebo_itt_combined.tex saved"


/*==============================================================================
  CLEANUP
==============================================================================*/

cap erase "$temp/_plac_deflator.dta"

di as text _n(3) "============================================================"
di as text       "  PLACEBO + COMPARISON RUN — COMPLETE"
di as text       "============================================================"
di as text _n "Tables produced (in $tables/):"
di as text _n "  Nov 23 (placebo, no credits disbursed):"
di as text "    placebo_first_stage.tex"
di as text "    placebo_main.tex"
di as text "    placebo_main_full.tex"
di as text _n "  Sep 26 (DU, comparison):"
di as text "    placebo_first_stage_sep26_du.tex"
di as text "    placebo_main_sep26_du.tex"
di as text "    placebo_main_full_sep26_du.tex"
di as text _n "  Dec 4 (DU, comparison):"
di as text "    placebo_first_stage_dec4_du.tex"
di as text "    placebo_main_dec4_du.tex"
di as text "    placebo_main_full_dec4_du.tex"
di as text _n "  Combined (robustness section):"
di as text "    placebo_fs_combined.tex     — 3 first stages side by side"
di as text "    placebo_itt_combined.tex    — 3 ITTs × 2 outcomes × 2 specs"
di as text _n "Interpretation:"
di as text "  Nov 23: all coefficients ≈ 0 (exclusion restriction supported)."
di as text "  Sep 26 / Dec 4: ITT should match main paper magnitudes,"
di as text "  validating that the Nov 23 null is due to non-disbursement."
di as text "============================================================"
