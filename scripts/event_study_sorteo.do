/*==============================================================================
  PROCREAR — Event-Study ITT around fecha_sorteo

  Objetivo:
    Estimar el efecto dinamico del credito PROCREAR sobre el empleo:
      employed (binario, 1 si tiene registro SIPA en periodo)

    Especificacion ITT (intent-to-treat) por loteria:
      - Tratamiento: ganador (asignacion aleatoria del sorteo)
      - NO instrumentamos receptor: el IV solo identifica el LATE de
        compliers, que es un subgrupo sesgado (full compliance no se da).
      - Person-sorteo FE absorbidos
      - Calendar-month FE absorbidos
      - SE clustered al nivel persona (id_anon)
      - Reference month: t = -1 (omitido)
      - Event window: t in [-24, +24] meses respecto a fecha_sorteo

  Output:
    Procrear/figures/event_study_employed.pdf
    Procrear/figures/event_study_employed.png
  Coeficientes:
    TEMP/_es_coefs_employed.dta

  ===========================================================================
  OUTLINE
  ===========================================================================
    STEP 0: Self-contained build (deflator + sorteo cross-section + SIPA panel)
    STEP 1: Expansion person-sorteo × event-time [-24, +24]
    STEP 2: Merge SIPA wages al periodo_month correspondiente
    STEP 3: Generar dummies event-time × ganador (ITT)
    STEP 4: Correr ITT event-study (reghdfe) x 3 outcomes
    STEP 5: Plot 3 figuras estilo Hausman & Zussman
==============================================================================*/

clear all
set more off
set matsize 10000

* --- PROJECT PATHS ------------------------------------------------------------
global root "/Users/francomartinvazquez/Dropbox (Personal)/Procrear Santanna"
global data "$root/DATA"
global temp "$root/TEMP"
global figs "$root/Procrear/figures"
global tabs "$root/Procrear/tables"

cap mkdir "$figs"
cap mkdir "$tabs"
cap mkdir "$temp"

* --- REQUIRED PACKAGES --------------------------------------------------------
* ssc install reghdfe, replace
* ssc install ftools, replace
* ssc install ivreghdfe, replace

* --- CONFIG -------------------------------------------------------------------
local TAU_MIN -6
local TAU_MAX  6
local TAU_REF  -1   // event-time omitido (referencia)


/*==============================================================================
  STEP 0: SELF-CONTAINED BUILD
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 0: Build deflator + sorteo cross-section + SIPA panel"
di as text       "==================================================================="


/*--- 0.1 Deflator -----------------------------------------------------------*/
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
save "$temp/_es_deflator.dta", replace
di as text "    deflator saved (" _N " months)"


/*--- 0.2 Sorteo cross-section (person-sorteo level) ------------------------*/
di as text _n "--- 0.2 Sorteo cross-section ---"

use "$data/Data_sorteos.dta", clear

* Same filters as paper_balance.do
replace desarrollourbanistico = 0 if desarrollourbanistico == .
replace tipologia             = 0 if tipologia == .
replace cupo                  = 0 if cupo == .
egen sorteo_fe = group(fecha_sorteo tipo desarrollourbanistico tipologia cupo)

gen tipo_grupo = .
replace tipo_grupo = 1 if tipo == 5
replace tipo_grupo = 2 if inlist(tipo, 2, 3, 4)
replace tipo_grupo = 3 if inlist(tipo, 6)
replace tipo_grupo = 4 if inlist(tipo, 1, 8, 9, 10, 11, 12, 13)
drop if tipo_grupo == 4   // drop Refacción

bys sorteo_fe: egen _winrate = mean(ganador)
drop if _winrate == 0 | _winrate == 1
drop _winrate

gen sorteo_month = mofd(fecha_sorteo)
format sorteo_month %tm

keep id_anon ganador receptor sorteo_fe fecha_sorteo sorteo_month
duplicates drop id_anon sorteo_fe, force

di as text "    sorteo units (person × sorteo): " _N
save "$temp/_es_units.dta", replace


/*--- 0.3 SIPA panel (lean: id_anon, periodo_month, wage, employed) ---------*/
di as text _n "--- 0.3 SIPA panel (lean) ---"

* Build id_anon list to filter SIPA
preserve
    use "$temp/_es_units.dta", clear
    keep id_anon
    duplicates drop
    save "$temp/_es_id_list.dta", replace
restore

use "$data/Data_SIPA.dta", clear
drop if mes<201801
merge m:1 id_anon using "$temp/_es_id_list.dta", keep(match) nogenerate
erase "$temp/_es_id_list.dta"

* Calendar month
gen int _y = floor(mes / 100)
gen int _m = mod(mes, 100)
gen periodo_month = ym(_y, _m)
format periodo_month %tm
drop _y _m

* Aguinaldo deseasonalization via SAC subtraction
gen double wage_desest = remuneracion
replace wage_desest = remuneracion - sac if !missing(sac)
replace wage_desest = 0 if wage_desest < 0 & !missing(wage_desest)

* Deflate
merge m:1 periodo_month using "$temp/_es_deflator.dta", keep(master match) nogenerate
gen double real_wage = wage_desest / deflator
replace real_wage = 0 if wage_desest == .

* Collapse to person-month (sum across employers)
collapse (sum) wage = real_wage, by(id_anon periodo_month)
gen byte sipa_match = 1   // marker: 1 if person had SIPA record this month

di as text "    SIPA panel rows: " _N
save "$temp/_es_sipa_panel.dta", replace
erase "$temp/_es_deflator.dta"


/*==============================================================================
  STEP 1: EXPAND TO PERSON-SORTEO × EVENT-TIME PANEL
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 1: Expand to event-time panel [`TAU_MIN', `TAU_MAX']"
di as text       "==================================================================="

use "$temp/_es_units.dta", clear

local n_tau = `TAU_MAX' - `TAU_MIN' + 1   // 49

di as text "    units: " _N
di as text "    expanding by " `n_tau' " event-times -> " _N * `n_tau' " rows"

expand `n_tau'
bysort id_anon sorteo_fe: gen int event_time = `TAU_MIN' + (_n - 1)
gen periodo_month = sorteo_month + event_time
format periodo_month %tm

di as text "    expanded panel rows: " _N

* Compress to save memory
compress


/*==============================================================================
  STEP 2: MERGE SIPA WAGES
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 2: Merge SIPA outcomes per (id_anon, periodo_month)"
di as text       "==================================================================="

merge m:1 id_anon periodo_month using "$temp/_es_sipa_panel.dta", keep(master match) nogenerate
erase "$temp/_es_sipa_panel.dta"

* employed = 1 if SIPA record exists, 0 otherwise
gen byte employed = (sipa_match == 1)
drop sipa_match wage   // wage and log_wage no longer needed (employed-only run)

di as text "    Cobertura outcome employed:"
count if employed == 1
di as text "      employed=1: " r(N) " (" %5.2f 100*r(N)/_N "%)"


/*==============================================================================
  STEP 3: GENERATE EVENT-TIME × GANADOR DUMMIES (ITT)
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 3: Event-time × ganador dummies"
di as text       "==================================================================="

* Naming: D<idx> = (event_time == tau) × ganador, idx = tau - TAU_MIN + 1 (1..49)
* Reference tau = -1 -> idx omitido (no se genera)
forvalues tau = `TAU_MIN'/`TAU_MAX' {
    if `tau' == `TAU_REF' continue
    local i = `tau' - `TAU_MIN' + 1
    qui gen byte D`i' = (event_time == `tau') * ganador
}

di as text "    Generated " (`TAU_MAX' - `TAU_MIN' + 1) - 1 " event-time × ganador dummies"

* Person-sorteo FE
egen long unit_id = group(id_anon sorteo_fe)


/*==============================================================================
  STEP 4: ITT EVENT-STUDY (one reghdfe per outcome)
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 4: ITT event-study regressions"
di as text       "==================================================================="

local outcomes "employed"

foreach y of local outcomes {
    di as text _n(2) "=== Outcome: `y' ==="

    qui count if !missing(`y')
    di as text "    Sample non-missing: " r(N)

    * Run ITT event-study (reghdfe with FEs, no IV)
    di as text "    Running reghdfe..."
    timer clear 1
    timer on 1
    reghdfe `y' D*, ///
        absorb(unit_id periodo_month) cluster(id_anon)
    timer off 1
    quietly timer list 1
    di as text "    Done in " r(t1)/60 " min"

    * Store estimates for later
    estimates save "$temp/_es_est_`y'.ster", replace

    * Build (event_time, beta, se) postfile
    capture postclose pf
    postfile pf int event_time double beta double se double ci_lo double ci_hi using "$temp/_es_coefs_`y'.dta", replace

    matrix B = e(b)
    matrix V = e(V)

    forvalues tau = `TAU_MIN'/`TAU_MAX' {
        if `tau' == `TAU_REF' {
            * Reference month: pinned to 0 by construction
            post pf (`tau') (0) (0) (0) (0)
        }
        else {
            local i = `tau' - `TAU_MIN' + 1
            local b  = B[1, "D`i'"]
            local se = sqrt(V["D`i'", "D`i'"])
            local lo = `b' - 1.96 * `se'
            local hi = `b' + 1.96 * `se'
            post pf (`tau') (`b') (`se') (`lo') (`hi')
        }
    }
    postclose pf
    di as text "    Coefs saved to $temp/_es_coefs_`y'.dta"
}


/*==============================================================================
  STEP 5: PLOT
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 5: Plot event studies"
di as text       "==================================================================="

local titles_employed "Effect on employment indicator"

local outcomes "employed"

foreach y of local outcomes {
    use "$temp/_es_coefs_`y'.dta", clear

    di as text _n "Event study `y':"
    list event_time beta se ci_lo ci_hi, sep(0)

    local ylab "`titles_`y''"

    twoway ///
        (rcap ci_lo ci_hi event_time, lcolor(navy) lwidth(medium)) ///
        (scatter beta event_time if event_time != `TAU_REF', ///
            mcolor(navy) msymbol(O) msize(small)) ///
        (scatter beta event_time if event_time == `TAU_REF', ///
            mcolor(white) mlcolor(navy) msymbol(Oh) msize(small)) ///
        (function y = 0, range(`TAU_MIN' `TAU_MAX') lcolor(black) lwidth(thin)), ///
        xline(-0.5, lpattern(dash) lcolor(gs6)) ///
        ytitle("`ylab'", size(medsmall)) ///
        xtitle("Months relative to sorteo", size(medsmall)) ///
        xlabel(`TAU_MIN'(6)`TAU_MAX', labsize(small)) ///
        ylabel(, labsize(small)) ///
        legend(off) ///
        graphregion(color(white)) plotregion(color(white)) ///
        title("", size(medsmall)) ///
        note("ITT estimates. Reference month: t = `TAU_REF'. CIs at 95%.", size(vsmall))

    graph export "$figs/event_study_`y'.pdf", replace
    graph export "$figs/event_study_`y'.png", replace width(2400)

    di as text "    Saved $figs/event_study_`y'.pdf"
}

* Cleanup intermediates
erase "$temp/_es_units.dta"

di as text _n(2) "========================================"
di as text       "  event_study_sorteo.do — Complete"
di as text       "========================================"
di as text _n "Outputs:"
di as text   "  $figs/event_study_employed.pdf"
di as text   "  $figs/event_study_employed.png"
di as text   "  $temp/_es_coefs_employed.dta (raw coefs)"
di as text   "  $temp/_es_est_employed.ster (full estimates)"
