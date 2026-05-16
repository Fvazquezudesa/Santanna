/*==============================================================================
  paper_distancia_outcomes.do
  ----------------------------
  Heterogeneidad espacial del efecto del sorteo PROCREAR.

  Tres familias:
    B: filter d_res_CABA<50,    Δ = distancia a CABA (Obelisco)
    C: filter d_res_CABA<50,    Δ = rowmin(21 ciudades curadas con Paraná)
    D: filter d_res_pre_21<50,  Δ = rowmin(21 ciudades curadas con Paraná)

  Bins (τ=5):
    Acerca: Δ < -5 km
    Igual:  |Δ| ≤ 5 km (referencia)
    Aleja:  Δ > +5 km

  Configuración espacial fija: filter=50, trim=50 (sym).
  Sample: pre_employed == 1 siempre.

  CUATRO bloques de regresiones:

    1. Slope:    c.Δ##i.ganador
                 OLS para log_wage, employed, any_work, is_monotributo
                 Poisson QMLE (ppmlhdfe) para total_wage

    2. Bin:      ib2.bin##i.ganador  (Acerca y Aleja vs Igual reference)
                 Mismos outcomes que Slope

    3. Bin_CC:   ib2.bin##i.ganador SPLIT por changed_cuit ∈ {0, 1}
                 Mismos outcomes
                 changed_cuit construido en _cuit_change_indicator.dta
                 (cuit principal en year_sorteo vs último año)

    4. ChenRoth: Recomendaciones del paper Chen-Roth (QJE 2024)
                 para tratar log_wage con mass-at-zero / selección:
        4a. Poisson QMLE en total_wage (already covered in blocks 1-3)
        4b. Lee bounds (full sample) sobre log_wage condicional en employed
        4c. Lee bounds por bin (Acerca/Igual/Aleja)

  Controles:
    none, age (edad), full (edad mujer pre_wage)

  Outputs:
    TEMP/_paper_distancia_bins.{dta,csv}
==============================================================================*/

clear all
set more off
set matsize 10000

global root "/Users/francomartinvazquez/Dropbox (Personal)/Procrear Santanna"
global temp "$root/TEMP"
global data "$root/DATA"

capture program drop hav_const
program define hav_const
    syntax, lat1(varname) lon1(varname) lat2(real) lon2(real) gen(name)
    tempvar phi1 phi2 lam1 lam2 a
    gen double `phi1' = `lat1' * _pi/180
    gen double `phi2' = `lat2' * _pi/180
    gen double `lam1' = `lon1' * _pi/180
    gen double `lam2' = `lon2' * _pi/180
    gen double `a' = sin((`phi2'-`phi1')/2)^2 + cos(`phi1') * cos(`phi2') * sin((`lam2'-`lam1')/2)^2
    gen double `gen' = 2 * 6371 * asin(min(1, sqrt(`a')))
    replace `gen' = . if `lat1' == . | `lon1' == .
end

*=============================================================================
* PARTE 0 — Construir indicador changed_cuit (si no existe)
*=============================================================================
capture confirm file "$temp/_cuit_change_indicator.dta"
if _rc != 0 {
    di as text _n "=== Construyendo _cuit_change_indicator.dta ==="
    use "$temp/_sipa_rema_anual.dta", clear
    keep if rema_anual > 0 & !mi(rema_anual)
    gsort id_anon ano -rema_anual
    by id_anon ano: keep if _n == 1
    keep id_anon ano cuit
    rename cuit cuit_main_yr
    tempfile cuit_yearly
    save `cuit_yearly'

    bysort id_anon: egen ano_last = max(ano)
    keep if ano == ano_last
    keep id_anon cuit_main_yr ano_last
    rename cuit_main_yr cuit_at_last
    rename ano_last year_last
    duplicates drop id_anon, force
    tempfile last_cuit
    save `last_cuit'

    use `cuit_yearly', clear
    rename cuit_main_yr cuit_at_sorteo
    rename ano year_sorteo
    tempfile cuit_sorteo
    save `cuit_sorteo'

    use "$temp/_paper_het_du_sample.dta", clear
    keep if tipo_grupo == 1
    merge m:1 id_anon year_sorteo using `cuit_sorteo', keep(master match) keepusing(cuit_at_sorteo) nogen
    merge m:1 id_anon using `last_cuit', keep(master match) keepusing(cuit_at_last year_last) nogen

    gen byte changed_cuit = .
    replace changed_cuit = 0 if !mi(cuit_at_sorteo) & !mi(cuit_at_last) & cuit_at_sorteo == cuit_at_last
    replace changed_cuit = 1 if !mi(cuit_at_sorteo) & !mi(cuit_at_last) & cuit_at_sorteo != cuit_at_last

    keep id_anon sorteo_fe changed_cuit cuit_at_sorteo cuit_at_last year_last year_sorteo
    save "$temp/_cuit_change_indicator.dta", replace
}
else di as text "  _cuit_change_indicator.dta existe — salteando"

*=============================================================================
* PARTE 1 — Cargar sample, computar distancias y bins
*=============================================================================
di as text _n "=== Cargando sample y construyendo distancias ==="

use "$temp/_paper_het_du_sample.dta", clear
keep if tipo_grupo == 1

* Family B: Δ a CABA
hav_const, lat1(lat_res_pre) lon1(lon_res_pre) lat2(-34.604) lon2(-58.382) gen(d_res_CABA)
hav_const, lat1(lat_dest)    lon1(lon_dest)    lat2(-34.604) lon2(-58.382) gen(d_dev_CABA)
gen double d_delta_CABA = d_dev_CABA - d_res_CABA

* Family C and D share the same 21-city list (Family D NEW with Paraná).
* Family C: filter por residencia cerca de CABA, RHS = Δ_21.
* Family D: filter por residencia cerca de cualquiera de las 21 urbes, RHS = Δ_21.
local lats_21 "-34.604 -34.921 -38.717 -32.946 -31.633 -31.420 -33.123 -36.620 -32.890 -34.617 -31.732 -26.834 -24.789 -24.185 -27.795 -27.451 -27.367 -41.135 -42.769 -51.624 -53.787"
local lons_21 "-58.382 -57.954 -62.272 -60.640 -60.700 -64.188 -64.349 -64.290 -68.844 -68.331 -60.532 -65.224 -65.410 -65.298 -64.262 -58.987 -55.897 -71.310 -65.038 -69.215 -67.711"
local n_21 : word count `lats_21'
local res21 ""
local dev21 ""
forvalues k = 1/`n_21' {
    local la : word `k' of `lats_21'
    local lo : word `k' of `lons_21'
    hav_const, lat1(lat_res_pre) lon1(lon_res_pre) lat2(`la') lon2(`lo') gen(_dr21_`k')
    hav_const, lat1(lat_dest)    lon1(lon_dest)    lat2(`la') lon2(`lo') gen(_dd21_`k')
    local res21 "`res21' _dr21_`k'"
    local dev21 "`dev21' _dd21_`k'"
}
egen double d_res_pre_21 = rowmin(`res21')
egen double d_dev_21     = rowmin(`dev21')
gen  double d_delta_21   = d_dev_21 - d_res_pre_21
drop `res21' `dev21'

* Bins τ=5
local tau = 5
foreach fam in B C D {
    if "`fam'" == "B" local dev "d_delta_CABA"
    if "`fam'" == "C" local dev "d_delta_21"
    if "`fam'" == "D" local dev "d_delta_21"
    gen byte bin_`fam' = .
    replace bin_`fam' = 1 if `dev' < -`tau' & !mi(`dev')
    replace bin_`fam' = 2 if abs(`dev') <= `tau' & !mi(`dev')
    replace bin_`fam' = 3 if `dev' > `tau' & !mi(`dev')
}
label define binlab 1 "Closer" 2 "Same" 3 "Away"
label values bin_B bin_C bin_D binlab

* Merge changed_cuit
merge m:1 id_anon sorteo_fe using "$temp/_cuit_change_indicator.dta", ///
    keep(master match) keepusing(changed_cuit) nogen

di as text _n "  Distribución changed_cuit (pre_emp==1):"
tab changed_cuit if pre_employed == 1, missing

*=============================================================================
* PARTE 2 — Postfile y loop principal (Blocks 1, 2, 3)
*=============================================================================
tempname pf
postfile `pf' str10 block str3 family str4 ctl str14 outcome ///
    int cc str10 coef double b se p p_lo p_hi long N ///
    using "$temp/_paper_distancia_bins.dta", replace

local outcomes "log_wage total_wage employed any_work is_monotributo"
local ctls     "none age full"

di as text _n "=== Running Blocks 1-3 (Slope, Bin, Bin_CC) ==="
local i = 0

foreach fam in B C D {
    if "`fam'" == "B" {
        local resvar "d_res_CABA"
        local devvar "d_delta_CABA"
        local binvar "bin_B"
    }
    if "`fam'" == "C" {
        local resvar "d_res_CABA"
        local devvar "d_delta_21"
        local binvar "bin_C"
    }
    if "`fam'" == "D" {
        local resvar "d_res_pre_21"
        local devvar "d_delta_21"
        local binvar "bin_D"
    }

    foreach ctl in `ctls' {
        local ctlvars ""
        if "`ctl'" == "age"  local ctlvars "edad"
        if "`ctl'" == "full" local ctlvars "edad mujer pre_wage"

        foreach y of local outcomes {
            local base_cond "`resvar' < 50 & !mi(`resvar') & abs(`devvar') <= 50 & pre_employed == 1"

            ********** Block 1: Slope **********
            local ++i
            if mod(`i', 10) == 0 di as text "  [`i'] fam=`fam' ctl=`ctl' y=`y'"
            if "`y'" == "total_wage" {
                capture quietly ppmlhdfe `y' c.`devvar'##i.ganador `ctlvars' if `base_cond', absorb(sorteo_fe) cluster(id_anon)
                local pfn 1
            }
            else {
                capture quietly reghdfe `y' c.`devvar'##i.ganador `ctlvars' if `base_cond', absorb(sorteo_fe) cluster(id_anon)
                local pfn 0
            }
            if _rc == 0 {
                local b  = _b[c.`devvar'#1.ganador]
                local se = _se[c.`devvar'#1.ganador]
                if `pfn' local p = 2*normal(-abs(`b'/`se'))
                else     local p = 2*ttail(e(df_r), abs(`b'/`se'))
                post `pf' ("Slope") ("`fam'") ("`ctl'") ("`y'") (-1) ("Slope") (`b') (`se') (`p') (.) (.) (e(N))
            }

            ********** Block 2: Bin (full sample) **********
            if "`y'" == "total_wage" {
                capture quietly ppmlhdfe `y' ib2.`binvar'##i.ganador `ctlvars' if `base_cond', absorb(sorteo_fe) cluster(id_anon)
                local pfn 1
            }
            else {
                capture quietly reghdfe `y' ib2.`binvar'##i.ganador `ctlvars' if `base_cond', absorb(sorteo_fe) cluster(id_anon)
                local pfn 0
            }
            if _rc == 0 {
                local b_a  = _b[1.`binvar'#1.ganador]
                local se_a = _se[1.`binvar'#1.ganador]
                local b_z  = _b[3.`binvar'#1.ganador]
                local se_z = _se[3.`binvar'#1.ganador]
                if `pfn' {
                    local p_a = 2*normal(-abs(`b_a'/`se_a'))
                    local p_z = 2*normal(-abs(`b_z'/`se_z'))
                }
                else {
                    local p_a = 2*ttail(e(df_r), abs(`b_a'/`se_a'))
                    local p_z = 2*ttail(e(df_r), abs(`b_z'/`se_z'))
                }
                post `pf' ("Bin") ("`fam'") ("`ctl'") ("`y'") (-1) ("Closer") (`b_a') (`se_a') (`p_a') (.) (.) (e(N))
                post `pf' ("Bin") ("`fam'") ("`ctl'") ("`y'") (-1) ("Away")  (`b_z') (`se_z') (`p_z') (.) (.) (e(N))
            }

            ********** Block 3: Bin × cuit-change split **********
            forvalues cc = 0/1 {
                local samp_cond "`base_cond' & changed_cuit == `cc'"
                if "`y'" == "total_wage" {
                    capture quietly ppmlhdfe `y' ib2.`binvar'##i.ganador `ctlvars' if `samp_cond', absorb(sorteo_fe) cluster(id_anon)
                    local pfn 1
                }
                else {
                    capture quietly reghdfe `y' ib2.`binvar'##i.ganador `ctlvars' if `samp_cond', absorb(sorteo_fe) cluster(id_anon)
                    local pfn 0
                }
                if _rc == 0 {
                    local b_a  = _b[1.`binvar'#1.ganador]
                    local se_a = _se[1.`binvar'#1.ganador]
                    local b_z  = _b[3.`binvar'#1.ganador]
                    local se_z = _se[3.`binvar'#1.ganador]
                    if `pfn' {
                        local p_a = 2*normal(-abs(`b_a'/`se_a'))
                        local p_z = 2*normal(-abs(`b_z'/`se_z'))
                    }
                    else {
                        local p_a = 2*ttail(e(df_r), abs(`b_a'/`se_a'))
                        local p_z = 2*ttail(e(df_r), abs(`b_z'/`se_z'))
                    }
                    post `pf' ("Bin_CC") ("`fam'") ("`ctl'") ("`y'") (`cc') ("Closer") (`b_a') (`se_a') (`p_a') (.) (.) (e(N))
                    post `pf' ("Bin_CC") ("`fam'") ("`ctl'") ("`y'") (`cc') ("Away")  (`b_z') (`se_z') (`p_z') (.) (.) (e(N))
                }
            }
        }
    }
}

*=============================================================================
* PARTE 3 — Block 4: Chen-Roth recommendations for log_wage
*   4a. Poisson QMLE on total_wage (already covered as outcome in Block 1-3)
*   4b. Lee bounds (full sample) on log_wage with select(employed)
*   4c. Lee bounds by bin
*
* Notas:
*   - leebounds no admite FE absorbidos. Reportamos bounds sin sorteo_fe.
*   - leebounds usa varianza no-clusterizada por default.
*   - Reportamos: β_ext (extensive margin on employed), β_naive (OLS log_wage
*     condicional on employed), y bounds [Lo, Hi].
*=============================================================================
di as text _n "=== Block 4: Chen-Roth (Lee bounds) ==="

foreach fam in B C D {
    if "`fam'" == "B" {
        local resvar "d_res_CABA"
        local devvar "d_delta_CABA"
        local binvar "bin_B"
    }
    if "`fam'" == "C" {
        local resvar "d_res_CABA"
        local devvar "d_delta_21"
        local binvar "bin_C"
    }
    if "`fam'" == "D" {
        local resvar "d_res_pre_21"
        local devvar "d_delta_21"
        local binvar "bin_D"
    }
    local base_cond "`resvar' < 50 & !mi(`resvar') & abs(`devvar') <= 50 & pre_employed == 1"

    ****** 4b: Lee bounds full sample on log_wage ******
    quietly count if `base_cond' & !mi(employed)
    local N_full = r(N)

    * extensive margin coefficient (use reghdfe with FE for accuracy)
    quietly areg employed ganador if `base_cond', absorb(sorteo_fe) vce(cluster id_anon)
    local b_ext = _b[ganador]
    local se_ext = _se[ganador]
    local p_ext = 2*ttail(e(df_r), abs(`b_ext'/`se_ext'))

    * naive intensive margin (log_wage | employed)
    quietly areg log_wage ganador if `base_cond' & employed == 1, absorb(sorteo_fe) vce(cluster id_anon)
    local b_naive = _b[ganador]
    local se_naive = _se[ganador]
    local p_naive = 2*ttail(e(df_r), abs(`b_naive'/`se_naive'))

    * Lee bounds (no FE)
    capture quietly leebounds log_wage ganador if `base_cond', select(employed)
    local Lo = .
    local Hi = .
    if _rc == 0 {
        matrix B = e(b)
        local Lo = B[1,1]
        local Hi = B[1,2]
    }
    di as text "  `fam' full: ext=" %7.4f `b_ext' " naive=" %7.4f `b_naive' " Lee=[" %7.4f `Lo' ", " %7.4f `Hi' "]"

    post `pf' ("ChenRoth") ("`fam'") ("none") ("ext_margin") (-1) ("ExtMargin") (`b_ext') (`se_ext') (`p_ext') (.) (.) (`N_full')
    post `pf' ("ChenRoth") ("`fam'") ("none") ("log_wage_naive") (-1) ("NaiveLog") (`b_naive') (`se_naive') (`p_naive') (.) (.) (`N_full')
    post `pf' ("ChenRoth") ("`fam'") ("none") ("log_wage_Lee") (-1) ("LeeBounds") (.) (.) (.) (`Lo') (`Hi') (`N_full')

    ****** 4c: Lee bounds by bin (Acerca/Igual/Aleja) ******
    forvalues b = 1/3 {
        local bin_lbl = cond(`b'==1, "Closer", cond(`b'==2, "Same", "Away"))
        local cond_b "`base_cond' & `binvar' == `b'"
        quietly count if `cond_b'
        local N_b = r(N)
        if `N_b' < 200 {
            di as text "  `fam' bin=`bin_lbl' N=`N_b' — skip"
            continue
        }
        capture quietly leebounds log_wage ganador if `cond_b', select(employed)
        local Lo = .
        local Hi = .
        if _rc == 0 {
            matrix B = e(b)
            local Lo = B[1,1]
            local Hi = B[1,2]
            di as text "  `fam' bin=`bin_lbl': Lee=[" %7.4f `Lo' ", " %7.4f `Hi' "] N=" %8.0fc `N_b'
        }
        post `pf' ("ChenRoth") ("`fam'") ("none") ("log_wage_Lee_bin") (-1) ("`bin_lbl'") (.) (.) (.) (`Lo') (`Hi') (`N_b')
    }
}

postclose `pf'

*=============================================================================
* PARTE 4 — Export y reporte
*=============================================================================
use "$temp/_paper_distancia_bins.dta", clear
export delimited "$temp/_paper_distancia_bins.csv", replace

di as text _n "=== Headline: log_wage Family D ctl=none ==="
preserve
    keep if outcome == "log_wage" & family == "D" & ctl == "none"
    sort block cc coef
    list block ctl cc coef b p N, noobs sep(0) ab(12) clean
restore

di as text _n "=== Chen-Roth Lee bounds full sample ==="
preserve
    keep if outcome == "log_wage_Lee" | outcome == "ext_margin" | outcome == "log_wage_naive"
    sort family outcome
    list family outcome coef b se p_lo p_hi N, noobs sep(0) ab(14) clean
restore

di as text _n "=== Chen-Roth Lee bounds by bin ==="
preserve
    keep if outcome == "log_wage_Lee_bin"
    sort family coef
    list family coef p_lo p_hi N, noobs sep(0) ab(14) clean
restore

*=============================================================================
* PARTE 5 — Export tablas LaTeX
*=============================================================================
* Tablas:
*   tab_distancia_<outcome>.tex
*   - Filas: Slope, Acerca, Aleja, N, controles (checkmarks)
*   - Columnas: 6 = 2 samples × 3 controles (none / age / full)
*               Sample 1 = filter d_res_CABA<50 (was Family C)
*               Sample 2 = filter d_res_pre_21<50 (was Family D)
*   - Cells: β\sym{stars} y (SE)
*   - Estilo: scriptsize, \sym macro, \hline\hline (matches paper conventions)
*
* Outputs en Procrear/tables/
*=============================================================================
local tab_dir "$root/Procrear/tables"
capture mkdir "`tab_dir'"

use "$temp/_paper_distancia_bins.dta", clear

gen str4 stars = ""
replace stars = "*"    if p < 0.10 & !mi(p)
replace stars = "**"   if p < 0.05 & !mi(p)
replace stars = "***"  if p < 0.01 & !mi(p)

* Only log_wage (main) and total_wage (appendix). Drop employed and others.
local outcomes_export "log_wage total_wage"

* Mapping: "C" = Sample 1, "D" = Sample 2 (Family B dropped)
foreach y of local outcomes_export {

    di as text _n "  Writing tab_distancia_`y'.tex"

    file open texout using "`tab_dir'/tab_distancia_`y'.tex", write replace
    file write texout "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
    file write texout "\scriptsize" _n
    file write texout "\setlength{\tabcolsep}{0pt}" _n
    file write texout "\begin{tabular*}{0.95\textwidth}{@{\extracolsep{\fill}}l*{6}{c}@{}}" _n
    file write texout "\hline\hline" _n
    file write texout " & \multicolumn{3}{c}{Sample 1} & \multicolumn{3}{c}{Sample 2} \\" _n
    file write texout "\cline{2-4}\cline{5-7}" _n
    file write texout " & (1) & (2) & (3) & (4) & (5) & (6) \\" _n
    file write texout "\hline" _n

    * Helper macros for cell formatting
    foreach rowname in Slope Closer Away {
        if "`rowname'" == "Slope" {
            local blk "Slope"
            local coefname "Slope"
        }
        else {
            local blk "Bin"
            local coefname "`rowname'"
        }

        * Coef row
        file write texout "`rowname'"
        foreach fam in C D {
            foreach ctl in none age full {
                quietly levelsof b if family == "`fam'" & ctl == "`ctl'" & outcome == "`y'" & block == "`blk'" & coef == "`coefname'", local(bv)
                quietly levelsof stars if family == "`fam'" & ctl == "`ctl'" & outcome == "`y'" & block == "`blk'" & coef == "`coefname'", local(starv) clean
                if "`bv'" == "" {
                    file write texout " &      "
                }
                else {
                    local b_str : di %8.4f real("`bv'")
                    local star_str = subinstr("`starv'", `"""', "", .)
                    file write texout " & " "`b_str'" "\sym{" "`star_str'" "}"
                }
            }
        }
        file write texout " \\" _n

        * SE row
        file write texout " "
        foreach fam in C D {
            foreach ctl in none age full {
                quietly levelsof se if family == "`fam'" & ctl == "`ctl'" & outcome == "`y'" & block == "`blk'" & coef == "`coefname'", local(sev)
                if "`sev'" == "" {
                    file write texout " &      "
                }
                else {
                    local se_str : di %8.4f real("`sev'")
                    file write texout " & (" "`se_str'" ")"
                }
            }
        }
        file write texout " \\[0.3em]" _n
    }
    file write texout "\hline" _n

    * N row
    file write texout "N"
    foreach fam in C D {
        foreach ctl in none age full {
            quietly levelsof N if family == "`fam'" & ctl == "`ctl'" & outcome == "`y'" & block == "Bin" & coef == "Closer", local(Nv)
            if "`Nv'" == "" {
                file write texout " & "
            }
            else {
                local N_str : di %12.0fc real("`Nv'")
                file write texout " & " "`N_str'"
            }
        }
    }
    file write texout " \\" _n

    * Controls rows (checkmarks)
    file write texout "Controls for age            &              & \checkmark   & \checkmark   &              & \checkmark   & \checkmark   \\" _n
    file write texout "Full controls (female, pre\_wage) &         &              & \checkmark   &              &              & \checkmark   \\" _n

    file write texout "\hline\hline" _n
    file write texout "\end{tabular*}" _n
    file write texout "\par\smallskip" _n
    file write texout "\begin{minipage}{0.90\textwidth}" _n
    file write texout "\scriptsize" _n
    file write texout "Sample 1: pre-residents within 50~km of CABA. Sample 2: pre-residents within 50~km of any of 21 main urban centers. RHS distance change $\Delta$ is rowmin over 21 urban centers. Trim $|\Delta|\leq 50$~km. Bins (Same reference): Closer $\Delta<-5$, Away $\Delta>+5$. All include lottery FE; SE clustered at person level. Sample: \emph{pre\_employed} $=1$. Full controls: age, female, pre\_wage.\\" _n
    file write texout "\sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)" _n
    file write texout "\end{minipage}" _n
    file close texout
}

di as text _n(2) "Done. Outputs in:"
di as text "  $temp/_paper_distancia_bins.{dta,csv}"
di as text "  `tab_dir'/tab_distancia_<outcome>.tex"
