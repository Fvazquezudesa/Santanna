/*==============================================================================
  PROCREAR — Event-Study ITT around fecha_sorteo (CHECKPOINTED)

  Objetivo:
    Estimar el efecto dinamico del credito PROCREAR sobre el empleo:
      employed (binario, 1 si tiene registro SIPA en periodo)

    Especificacion: ITT (intent-to-treat) por loteria, stacked DID.
      - Tratamiento: ganador (asignacion aleatoria del sorteo)
      - Person-sorteo FE absorbidos
      - Calendar-month FE absorbidos
      - SE clustered al nivel persona (id_anon)
      - Reference month: t = -1 (omitido)
      - Event window: t in [TAU_MIN, TAU_MAX] meses respecto a fecha_sorteo

  Stacked DID (por que no joint):
    El joint spec (una sola reghdfe con todas las dummies) tarda horas o no
    converge. En su lugar corremos una reg por horizonte τ sobre el subset
    event_time in {τ, -1}. Cada τ es independiente y se guarda como
    checkpoint. Si Stata se cae, restart procesa solo los τ faltantes.

  Output:
    Procrear/figures/event_study_employed.pdf
    Procrear/figures/event_study_employed.png
  Coeficientes:
    TEMP/_es_coefs_employed.dta (concatenado)
  Checkpoints:
    TEMP/_es_chk_<tau>.dta (uno por τ; persisten para resumir si script se cae)

  ===========================================================================
  OUTLINE
  ===========================================================================
    STEP 0: Self-contained build (deflator + sorteo + SIPA panel) — idempotente
    STEP 1: Build event-time panel + merge SIPA → _es_panel.dta — idempotente
    STEP 2: Per-τ checkpointed loop (stacked DID)
    STEP 3: Aggregate checkpoints → _es_coefs_employed.dta
    STEP 4: Plot figura
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
cap mkdir "$temp/_es_chk"   // carpeta para checkpoints

* --- REQUIRED PACKAGES --------------------------------------------------------
* ssc install reghdfe, replace
* ssc install ftools, replace

* --- CONFIG -------------------------------------------------------------------
local TAU_MIN -12
local TAU_MAX  63
local TAU_REF  -1   // event-time omitido (referencia)

* Para forzar rebuild de algun paso, borrar manualmente:
*   $temp/_es_units.dta       -> rebuild STEP 0.2
*   $temp/_es_sipa_panel.dta  -> rebuild STEP 0.3
*   $temp/_es_panel.dta       -> rebuild STEP 1
*   $temp/_es_chk/_chk_*.dta  -> rebuild un τ específico


/*==============================================================================
  STEP 0: SELF-CONTAINED BUILD (idempotente)
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 0: Build deflator + sorteo + SIPA panel"
di as text       "==================================================================="


/*--- 0.1 Deflator -----------------------------------------------------------*/
capture confirm file "$temp/_es_deflator.dta"
if _rc == 0 {
    di as text _n "--- 0.1 Deflator: skip (ya existe) ---"
}
else {
    di as text _n "--- 0.1 Deflator: building ---"
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
}


/*--- 0.2 Sorteo cross-section ----------------------------------------------*/
capture confirm file "$temp/_es_units.dta"
if _rc == 0 {
    di as text _n "--- 0.2 Sorteo cross-section: skip (ya existe) ---"
}
else {
    di as text _n "--- 0.2 Sorteo cross-section: building ---"
    use "$data/Data_sorteos.dta", clear

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
}


/*--- 0.3 SIPA panel ----------------------------------------------------------*/
capture confirm file "$temp/_es_sipa_panel.dta"
if _rc == 0 {
    di as text _n "--- 0.3 SIPA panel: skip (ya existe) ---"
}
else {
    di as text _n "--- 0.3 SIPA panel: building ---"

    preserve
        use "$temp/_es_units.dta", clear
        keep id_anon
        duplicates drop
        save "$temp/_es_id_list.dta", replace
    restore

    use "$data/Data_SIPA.dta", clear
    drop if mes < 201901
    merge m:1 id_anon using "$temp/_es_id_list.dta", keep(match) nogenerate
    erase "$temp/_es_id_list.dta"

    gen int _y = floor(mes / 100)
    gen int _m = mod(mes, 100)
    gen periodo_month = ym(_y, _m)
    format periodo_month %tm
    drop _y _m

    gen double wage_desest = remuneracion
    replace wage_desest = remuneracion - sac if !missing(sac)
    replace wage_desest = 0 if wage_desest < 0 & !missing(wage_desest)

    merge m:1 periodo_month using "$temp/_es_deflator.dta", keep(master match) nogenerate
    gen double real_wage = wage_desest / deflator
    replace real_wage = 0 if wage_desest == .

    collapse (sum) wage = real_wage, by(id_anon periodo_month)
    gen byte sipa_match = 1

    di as text "    SIPA panel rows: " _N
    save "$temp/_es_sipa_panel.dta", replace
}


/*==============================================================================
  STEP 1: EXPAND TO PERSON-SORTEO × EVENT-TIME PANEL (idempotente)
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 1: Build event-time panel [`TAU_MIN', `TAU_MAX']"
di as text       "==================================================================="

capture confirm file "$temp/_es_panel.dta"
if _rc == 0 {
    di as text _n "--- STEP 1: skip (panel ya existe) ---"
    use "$temp/_es_panel.dta", clear
    di as text "    Loaded panel: N = " _N
}
else {
    di as text _n "--- STEP 1: building panel ---"
    use "$temp/_es_units.dta", clear

    local n_tau = `TAU_MAX' - `TAU_MIN' + 1

    di as text "    units: " _N
    di as text "    expanding by " `n_tau' " event-times -> " _N * `n_tau' " rows"

    expand `n_tau'
    bysort id_anon sorteo_fe: gen int event_time = `TAU_MIN' + (_n - 1)
    gen periodo_month = sorteo_month + event_time
    format periodo_month %tm

    di as text "    Merging SIPA outcomes..."
    merge m:1 id_anon periodo_month using "$temp/_es_sipa_panel.dta", keep(master match) nogenerate

    gen byte employed = (sipa_match == 1)
    drop sipa_match wage

    * Person-sorteo FE id (precomputado)
    egen long unit_id = group(id_anon sorteo_fe)

    compress

    di as text "    Final panel rows: " _N
    count if employed == 1
    di as text "      employed=1: " r(N) " (" %5.2f 100*r(N)/_N "%)"

    save "$temp/_es_panel.dta", replace
    di as text "    Panel saved."
}


/*==============================================================================
  STEP 2: PER-τ CHECKPOINTED LOOP (stacked DID)

  For each τ in [TAU_MIN, TAU_MAX] (excl TAU_REF):
    1. Si existe checkpoint $temp/_es_chk/_chk_<tau>.dta -> skip
    2. Si no:
       a. Preservar panel completo
       b. Subset a event_time in {τ, TAU_REF}
       c. Gen D = (event_time == τ) * ganador
       d. reghdfe employed D, absorb(unit_id periodo_month) cluster(id_anon)
       e. Save (tau, beta, se, ci_lo, ci_hi, n_obs, finished_at) -> checkpoint
       f. Restore
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 2: Per-τ checkpointed loop (stacked DID)"
di as text       "==================================================================="

* Sanity: estamos con _es_panel.dta cargado (de STEP 1)
qui count
local panel_n = r(N)
di as text "    Panel rows en memoria: " %12.0fc `panel_n'
di as text "    Loop τ desde `TAU_MIN' hasta `TAU_MAX' (excl `TAU_REF')"
di as text "    Checkpoints en: $temp/_es_chk/"

local n_done = 0
local n_skip = 0
local n_total = `TAU_MAX' - `TAU_MIN'   // 49 -1 = 48 (excl reference)

forvalues tau = `TAU_MIN'/`TAU_MAX' {
    if `tau' == `TAU_REF' continue

    local chk "$temp/_es_chk/_chk_`tau'.dta"

    capture confirm file "`chk'"
    if _rc == 0 {
        local ++n_skip
        di as text "    τ = `tau': skip (checkpoint existe)"
        continue
    }

    di as text _n "    τ = `tau': running..."
    timer clear 99
    timer on 99

    preserve
        keep if event_time == `tau' | event_time == `TAU_REF'
        gen byte D = (event_time == `tau') * ganador

        qui reghdfe employed D, absorb(unit_id periodo_month) cluster(id_anon)

        local b   = _b[D]
        local se  = _se[D]
        local lo  = `b' - 1.96 * `se'
        local hi  = `b' + 1.96 * `se'
        local n_o = e(N)

        clear
        set obs 1
        gen int    event_time = `tau'
        gen double beta       = `b'
        gen double se         = `se'
        gen double ci_lo      = `lo'
        gen double ci_hi      = `hi'
        gen long   n_obs      = `n_o'
        gen str20  finished_at = "$S_DATE $S_TIME"
        save "`chk'", replace
    restore

    timer off 99
    quietly timer list 99
    local elapsed = r(t99)
    local ++n_done

    di as text "      β = " %9.6f `b' "  se = " %9.6f `se' "  N = " %12.0fc `n_o' "  (" %5.1f `elapsed' "s)"
}

di as text _n "    Summary STEP 2:"
di as text "      Procesados ahora: `n_done'"
di as text "      Skip (existian):  `n_skip'"
di as text "      Total esperado:   `n_total'"


/*==============================================================================
  STEP 3: AGGREGATE CHECKPOINTS
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 3: Aggregate checkpoints"
di as text       "==================================================================="

clear

* Append todos los checkpoints
local first = 1
forvalues tau = `TAU_MIN'/`TAU_MAX' {
    if `tau' == `TAU_REF' continue
    local chk "$temp/_es_chk/_chk_`tau'.dta"
    capture confirm file "`chk'"
    if _rc != 0 {
        di as error "    WARN: missing checkpoint para τ = `tau' (`chk')"
        continue
    }
    if `first' {
        use "`chk'", clear
        local first = 0
    }
    else {
        append using "`chk'"
    }
}

* Agregar la fila de referencia τ = -1 con beta = 0, se = 0
set obs `=_N+1'
replace event_time = `TAU_REF' in L
replace beta       = 0         in L
replace se         = 0         in L
replace ci_lo      = 0         in L
replace ci_hi      = 0         in L
replace n_obs      = .         in L

sort event_time

di as text _n "Coefs assembled:"
list event_time beta se ci_lo ci_hi n_obs, sep(0) noobs

save "$temp/_es_coefs_employed.dta", replace
di as text _n "    Saved: $temp/_es_coefs_employed.dta"


/*==============================================================================
  STEP 4: PLOT
==============================================================================*/

di as text _n(2) "==================================================================="
di as text       "  STEP 4: Plot event study"
di as text       "==================================================================="

use "$temp/_es_coefs_employed.dta", clear

twoway ///
    (rcap ci_lo ci_hi event_time, lcolor(navy) lwidth(medium)) ///
    (scatter beta event_time if event_time != `TAU_REF', ///
        mcolor(navy) msymbol(O) msize(small)) ///
    (scatter beta event_time if event_time == `TAU_REF', ///
        mcolor(white) mlcolor(navy) msymbol(Oh) msize(small)) ///
    (function y = 0, range(`TAU_MIN' `TAU_MAX') lcolor(black) lwidth(thin)), ///
    xline(-0.5, lpattern(dash) lcolor(gs6)) ///
    ytitle("Effect on employment indicator", size(medsmall)) ///
    xtitle("Months relative to sorteo", size(medsmall)) ///
    xlabel(`TAU_MIN'(6)`TAU_MAX', labsize(small)) ///
    ylabel(, labsize(small)) ///
    legend(off) ///
    graphregion(color(white)) plotregion(color(white)) ///
    title("", size(medsmall)) ///
    note("ITT estimates (stacked DID per horizon). Reference month: t = `TAU_REF'. CIs at 95%.", size(vsmall))

graph export "$figs/event_study_employed.pdf", replace
graph export "$figs/event_study_employed.png", replace width(2400)

di as text _n "    Saved $figs/event_study_employed.pdf"

di as text _n(2) "========================================"
di as text       "  event_study_sorteo.do — Complete"
di as text       "========================================"
di as text _n "Outputs:"
di as text   "  $figs/event_study_employed.pdf"
di as text   "  $figs/event_study_employed.png"
di as text   "  $temp/_es_coefs_employed.dta (concatenated coefs)"
di as text   "  $temp/_es_chk/_chk_<tau>.dta (per-τ checkpoints)"
di as text _n "To force rebuild:"
di as text   "  Delete $temp/_es_panel.dta to rebuild STEP 1"
di as text   "  Delete $temp/_es_chk/_chk_<tau>.dta for specific τ"
di as text   "  Delete entire $temp/_es_chk/ folder for full re-run of STEP 2"
