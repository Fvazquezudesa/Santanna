/*==============================================================================
  PROCREAR — Leverage Dynamics (Balanced Sorteos)

  Among credit recipients, examines how income stability CHANGES from
  pre-sorteo to post-sorteo, and whether this change depends on leverage.

  Approach A: Pre-post differences (cross-sectional)
    Compute stability pre and post sorteo, take Delta = post - pre,
    regress Delta on leverage (continuous + tercile).

  Approach B: Event study (panel with 6-month bins)
    Compute stability within 6-month semesters relative to sorteo,
    plot evolution by leverage tercile, test Post x leverage interaction
    with person FE.

  Windows: 24-month (symmetric) and full (all available SIPA months)

  REQUIRES: procrear_leverage_balanced.do (produces cross_section_leverage_balanced.dta)

  Table prefix: ballevdyn24_ / ballevdynfull_ / ballevdynes24_ / ballevdynesfull_
  Figure prefix: bales24_ / balesfull_
==============================================================================*/

clear all
set more off
set matsize 10000

* --- PROJECT PATHS ------------------------------------------------------------
global root "/Users/francomartinvazquez/Dropbox (Personal)/Procrear Santanna"
global data "$root/DATA"
global tables "$root/Procrear/tables"
global figures "$root/Figures"
global temp "$root/TEMP"

cap mkdir "$tables"
cap mkdir "$figures"


/*==============================================================================
  STEP 1: PREPARE RECIPIENTS SAMPLE WITH LEVERAGE
==============================================================================*/

di as text _n "=== STEP 1: Preparing recipients sample (Balanced) ===" _n

use "$temp/cross_section_leverage_balanced.dta", clear
keep if receptor == 1 & leverage != .

* Standardize leverage among recipients
quietly sum leverage
gen double lev_recip_std = (leverage - r(mean)) / r(sd)

* Terciles among recipients
xtile lev_recip_terc = leverage, nq(3)
label define lev_lbl 1 "Low Leverage" 2 "Medium" 3 "High Leverage", replace
label values lev_recip_terc lev_lbl

di as text "Recipients with valid leverage: " _N
di as text _n "Leverage by tercile:"
tabstat leverage, by(lev_recip_terc) stats(mean median min max n)

save "$temp/_recip_dynamics_bal.dta", replace


/*==============================================================================
  STEP 2: 24-MONTH WINDOW — BUILD PANEL, PRE-POST, EVENT STUDY BINS

  Expand each recipient to 48 months: 24 pre-sorteo + 24 post-sorteo.
  Merge with SIPA. Then collapse for (A) pre-post and (B) event study.
==============================================================================*/

di as text _n "=== STEP 2: 24-month window (Balanced) ===" _n

* --- 2A: Build monthly panel (-24 to +24) ------------------------------------

di as text "--- 2A: Building 24m panel ---"

use "$temp/_recip_dynamics_bal.dta", clear
keep row_id id_anon sorteo_month

expand 48
sort row_id
by row_id: gen int _seq = _n

* Map to relative months: seq 1-24 → rel -24 to -1, seq 25-48 → rel 1 to 24
gen int rel_month = _seq - 25 if _seq <= 24
replace rel_month = _seq - 24 if _seq > 24
gen periodo_month = sorteo_month + rel_month
format periodo_month %tm
gen byte post = (rel_month > 0)
gen int semester = cond(rel_month > 0, ceil(rel_month / 6), -ceil(-rel_month / 6))

drop _seq

* Merge SIPA
merge m:1 id_anon periodo_month using "$temp/sipa_panel.dta", ///
    keep(master match) keepusing(total_wage)
gen byte employed = (_merge == 3)
gen double wage = total_wage if _merge == 3
replace wage = 0 if _merge == 1
drop _merge total_wage

* Compute transitions for both groupings (pre/post and semester)
sort row_id post periodo_month
by row_id post: gen byte _tr_prepost = 0 if _n == 1
by row_id post: replace _tr_prepost = (employed != employed[_n-1]) if _n > 1

sort row_id semester periodo_month
by row_id semester: gen byte _tr_sem = 0 if _n == 1
by row_id semester: replace _tr_sem = (employed != employed[_n-1]) if _n > 1

di as text "24m panel rows: " _N
save "$temp/_dyn_panel_24m_bal.dta", replace


* --- 2B: Pre-post collapse (24m) --------------------------------------------

di as text _n "--- 2B: Pre-post collapse ---"

use "$temp/_dyn_panel_24m_bal.dta", clear

gen double wage_sq = wage^2

collapse (mean) pct_employed=employed mean_wage=wage ///
         (sum) sum_sq=wage_sq n_transitions=_tr_prepost ///
         (count) T=wage, by(row_id post)

* SD and CV
gen double var_ = sum_sq / T - mean_wage^2
replace var_ = 0 if var_ < 0
gen double sd_wage = sqrt(var_)
gen double cv_wage = sd_wage / mean_wage if mean_wage > 0
gen byte any_gap = (pct_employed < 1)
gen double tr_rate = n_transitions / T * 12   // transitions per year

keep row_id post cv_wage sd_wage pct_employed any_gap tr_rate

* Reshape wide: 0=pre, 1=post
reshape wide cv_wage sd_wage pct_employed any_gap tr_rate, i(row_id) j(post)

foreach v in cv_wage sd_wage pct_employed any_gap tr_rate {
    rename `v'0 `v'_pre24
    rename `v'1 `v'_post24
    gen double d_`v'_24 = `v'_post24 - `v'_pre24
}

di as text "Pre-post deltas (24m):"
sum d_*

save "$temp/_prepost_24m_bal.dta", replace


* --- 2C: Event study bins (24m) — 6-month semesters -------------------------

di as text _n "--- 2C: Event study bins ---"

use "$temp/_dyn_panel_24m_bal.dta", clear

gen double wage_sq = wage^2

collapse (mean) pct_employed=employed mean_wage=wage ///
         (sum) sum_sq=wage_sq n_transitions=_tr_sem ///
         (count) T_bin=wage, by(row_id semester)

gen double var_ = sum_sq / T_bin - mean_wage^2
replace var_ = 0 if var_ < 0
gen double sd_wage = sqrt(var_)
gen double cv_wage = sd_wage / mean_wage if mean_wage > 0
gen byte any_gap = (pct_employed < 1)

drop sum_sq var_ T_bin mean_wage

di as text "Event study bins (24m):"
tab semester

save "$temp/_es_bins_24_bal.dta", replace
erase "$temp/_dyn_panel_24m_bal.dta"


/*==============================================================================
  STEP 3: FULL WINDOW — BUILD PANEL, PRE-POST, EVENT STUDY BINS

  Uses all available SIPA months before and after sorteo.
  Window length varies by sorteo date.
==============================================================================*/

di as text _n "=== STEP 3: Full window (Balanced) ===" _n

* Find SIPA range
use "$temp/sipa_panel.dta", clear
quietly sum periodo_month
local first_sipa = r(min)
local last_sipa = r(max)
di as text "SIPA range: " %tm `first_sipa' " to " %tm `last_sipa'


* --- 3A: Build full-window panel ---------------------------------------------

di as text "--- 3A: Building full panel ---"

use "$temp/_recip_dynamics_bal.dta", clear
keep row_id id_anon sorteo_month

gen int n_pre = sorteo_month - `first_sipa'
gen int n_post = `last_sipa' - sorteo_month
replace n_pre = 0 if n_pre < 0
replace n_post = 0 if n_post < 0
gen int n_total = n_pre + n_post

di as text "Window lengths:"
sum n_pre n_post n_total

drop if n_total == 0

expand n_total
sort row_id
by row_id: gen int _seq = _n

* Map _seq to relative month
* First n_pre obs → pre-sorteo (rel -n_pre to -1)
* Next n_post obs → post-sorteo (rel 1 to n_post)
gen int rel_month = _seq - n_pre - 1 if _seq <= n_pre
replace rel_month = _seq - n_pre if _seq > n_pre
gen periodo_month = sorteo_month + rel_month
format periodo_month %tm
gen byte post = (rel_month > 0)
gen int semester = cond(rel_month > 0, ceil(rel_month / 6), -ceil(-rel_month / 6))

drop _seq n_pre n_post n_total

* Merge SIPA
merge m:1 id_anon periodo_month using "$temp/sipa_panel.dta", ///
    keep(master match) keepusing(total_wage)
gen byte employed = (_merge == 3)
gen double wage = total_wage if _merge == 3
replace wage = 0 if _merge == 1
drop _merge total_wage

* Transitions
sort row_id post periodo_month
by row_id post: gen byte _tr_prepost = 0 if _n == 1
by row_id post: replace _tr_prepost = (employed != employed[_n-1]) if _n > 1

sort row_id semester periodo_month
by row_id semester: gen byte _tr_sem = 0 if _n == 1
by row_id semester: replace _tr_sem = (employed != employed[_n-1]) if _n > 1

di as text "Full panel rows: " _N
save "$temp/_dyn_panel_full_bal.dta", replace


* --- 3B: Pre-post collapse (full) -------------------------------------------

di as text _n "--- 3B: Pre-post collapse ---"

use "$temp/_dyn_panel_full_bal.dta", clear

gen double wage_sq = wage^2

collapse (mean) pct_employed=employed mean_wage=wage ///
         (sum) sum_sq=wage_sq n_transitions=_tr_prepost ///
         (count) T=wage, by(row_id post)

gen double var_ = sum_sq / T - mean_wage^2
replace var_ = 0 if var_ < 0
gen double sd_wage = sqrt(var_)
gen double cv_wage = sd_wage / mean_wage if mean_wage > 0
gen byte any_gap = (pct_employed < 1)
gen double tr_rate = n_transitions / T * 12

keep row_id post cv_wage sd_wage pct_employed any_gap tr_rate

reshape wide cv_wage sd_wage pct_employed any_gap tr_rate, i(row_id) j(post)

foreach v in cv_wage sd_wage pct_employed any_gap tr_rate {
    rename `v'0 `v'_prefull
    rename `v'1 `v'_postfull
    gen double d_`v'_full = `v'_postfull - `v'_prefull
}

di as text "Pre-post deltas (full window):"
sum d_*

save "$temp/_prepost_full_bal.dta", replace


* --- 3C: Event study bins (full) — 6-month semesters ------------------------

di as text _n "--- 3C: Event study bins ---"

use "$temp/_dyn_panel_full_bal.dta", clear

gen double wage_sq = wage^2

collapse (mean) pct_employed=employed mean_wage=wage ///
         (sum) sum_sq=wage_sq n_transitions=_tr_sem ///
         (count) T_bin=wage, by(row_id semester)

gen double var_ = sum_sq / T_bin - mean_wage^2
replace var_ = 0 if var_ < 0
gen double sd_wage = sqrt(var_)
gen double cv_wage = sd_wage / mean_wage if mean_wage > 0
gen byte any_gap = (pct_employed < 1)

drop sum_sq var_ T_bin mean_wage

di as text "Event study bins (full) — semester range:"
sum semester

save "$temp/_es_bins_full_bal.dta", replace
erase "$temp/_dyn_panel_full_bal.dta"


/*==============================================================================
  STEP 4: PRE-POST REGRESSIONS

  Among recipients: Delta(outcome) = a + b * leverage + sorteo_fe + e

  b > 0 for Delta(pct_employed) → higher leverage → bigger employment gain
  b < 0 for Delta(CV/SD) → higher leverage → bigger variability reduction

  Two specs:
    A. Continuous leverage (standardized)
    B. Leverage tercile dummies (Low as reference)
==============================================================================*/

di as text _n "=== STEP 4: Pre-post regressions (Balanced) ===" _n

use "$temp/_recip_dynamics_bal.dta", clear
merge 1:1 row_id using "$temp/_prepost_24m_bal.dta", keep(master match) nogenerate
merge 1:1 row_id using "$temp/_prepost_full_bal.dta", keep(master match) nogenerate

save "$temp/_recip_prepost_bal.dta", replace

foreach win in "24" "full" {

    if "`win'" == "24"   local win_note "24-month symmetric windows pre and post sorteo."
    if "`win'" == "full" local win_note "Full pre and post sorteo windows (variable length)."

    foreach ctl in "noctl" "ctl" {
        if "`ctl'" == "noctl" local controls ""
        if "`ctl'" == "noctl" local note_ctl "No pre-treatment controls."
        if "`ctl'" == "ctl"   local controls "pre_wage pre_employed edad mujer"
        if "`ctl'" == "ctl"   local note_ctl "Controls: pre-wage, pre-employment, age, gender."

        * ---- A. Continuous leverage → Delta outcomes ----
        eststo clear

        foreach v in cv_wage sd_wage pct_employed any_gap tr_rate {
            eststo s_`v': reghdfe d_`v'_`win' lev_recip_std `controls', ///
                absorb(sorteo_fe) cluster(id_anon)
            quietly sum d_`v'_`win' if e(sample)
            estadd scalar ymean = r(mean)
        }

        esttab s_* using "$tables/ballevdyn`win'_prepost_`ctl'.tex", replace ///
            keep(lev_recip_std) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(ymean N r2, labels("Dep. var. mean" "Observations" "R-squared") ///
                  fmt(%9.3f %9.0fc %9.3f)) ///
            mtitles("CV Wage" "SD Wage" "Pct Employed" "Any Gap" "Trans/Year") ///
            coeflabels(lev_recip_std "Leverage (std)") ///
            title("Pre-Post Change in Stability by Leverage (Recipients Only)") ///
            note("OLS. Recipients only. Dep.\ var.: post minus pre change. `note_ctl' `win_note' Leverage standardized (mean=0, SD=1). SE clustered at person level. Sorteo FE absorbed.") ///
            substitute(`"\begin{tabular}"' `"\small\begin{tabular}"' `"\multicolumn{6}{l}{"' `"\multicolumn{6}{p{0.95\textwidth}}{"') ///
            label

        * ---- B. Leverage tercile dummies → Delta outcomes ----
        eststo clear

        foreach v in cv_wage sd_wage pct_employed any_gap tr_rate {
            eststo s_`v': reghdfe d_`v'_`win' ib(1).lev_recip_terc `controls', ///
                absorb(sorteo_fe) cluster(id_anon)
            quietly sum d_`v'_`win' if e(sample) & lev_recip_terc == 1
            estadd scalar cmean_low = r(mean)
        }

        esttab s_* using "$tables/ballevdyn`win'_prepost_terc_`ctl'.tex", replace ///
            keep(2.lev_recip_terc 3.lev_recip_terc) se(%9.4f) b(%9.4f) ///
            star(* 0.10 ** 0.05 *** 0.01) ///
            stats(cmean_low N r2, labels("Mean (Low Leverage)" "Observations" "R-squared") ///
                  fmt(%9.3f %9.0fc %9.3f)) ///
            mtitles("CV Wage" "SD Wage" "Pct Employed" "Any Gap" "Trans/Year") ///
            coeflabels(2.lev_recip_terc "Medium vs Low" 3.lev_recip_terc "High vs Low") ///
            title("Pre-Post Change by Leverage Tercile (Recipients Only)") ///
            note("OLS. Recipients only. Reference: Low Leverage. Dep.\ var.: post minus pre change. `note_ctl' `win_note' SE clustered at person level. Sorteo FE absorbed.") ///
            substitute(`"\begin{tabular}"' `"\label{tab:leverage_tercile}\small\begin{tabular}"' `"\multicolumn{6}{l}{"' `"\multicolumn{6}{p{0.95\textwidth}}{"') ///
            label
    }
}


/*==============================================================================
  STEP 5: EVENT STUDY — PERSON FE PANEL REGRESSIONS

  Panel: recipient x semester (6-month bins).
  Test: does the pre-to-post change in stability differ by leverage?

  Y_{is} = alpha_i + delta * Post + gamma * Post x leverage_std + e_{is}

  gamma is the key coefficient: differential change per SD of leverage.
==============================================================================*/

di as text _n "=== STEP 5: Event study panel regressions (Balanced) ===" _n

foreach win in "24" "full" {

    if "`win'" == "24"   local win_note "6-month bins, 24-month pre/post."
    if "`win'" == "full" local win_note "6-month bins, full pre/post window."

    use "$temp/_es_bins_`win'_bal.dta", clear
    merge m:1 row_id using "$temp/_recip_dynamics_bal.dta", ///
        keepusing(lev_recip_terc lev_recip_std id_anon) nogenerate

    gen byte _post = (semester > 0)

    * Panel FE: Post x Leverage interaction
    eststo clear

    foreach v in cv_wage sd_wage pct_employed any_gap n_transitions {
        capture eststo s_`v': reghdfe `v' i._post##c.lev_recip_std, ///
            absorb(row_id) cluster(id_anon)
        if _rc == 0 {
            estadd scalar b_post = _b[1._post]
        }
    }

    esttab s_* using "$tables/ballevdynes`win'_panel.tex", replace ///
        keep(1._post#c.lev_recip_std) se(%9.4f) b(%9.4f) ///
        star(* 0.10 ** 0.05 *** 0.01) ///
        stats(b_post N r2, labels("Post main effect" "Obs (person x semester)" "R-squared") ///
              fmt(%9.4f %9.0fc %9.3f)) ///
        mtitles("CV Wage" "SD Wage" "Pct Employed" "Any Gap" "Transitions") ///
        coeflabels(1._post#c.lev_recip_std "Post $\times$ Leverage (std)") ///
        title("Event Study: Post $\times$ Leverage Interaction (`win_note')") ///
        note("Person FE panel regression. Recipients only. Leverage standardized (mean=0, SD=1). SE clustered at person level.") ///
        substitute(`"\begin{tabular}"' `"\label{tab:leverage_es}\small\begin{tabular}"' `"\multicolumn{6}{l}{"' `"\multicolumn{6}{p{0.95\textwidth}}{"') ///
        label
}


/*==============================================================================
  STEP 6: EVENT STUDY FIGURES

  Collapse bin-level stability to leverage tercile x semester means.
  Plot time paths by leverage tercile.
==============================================================================*/

di as text _n "=== STEP 6: Event study figures (Balanced) ===" _n

foreach win in "24" "full" {

    if "`win'" == "24" {
        local sem_min = -4
        local sem_max = 4
        local win_label "24-Month Window"
        local xlab "xlabel(-4(1)4)"
    }
    if "`win'" == "full" {
        local sem_min = -8
        local sem_max = 12
        local win_label "Full Window"
        local xlab "xlabel(-8(2)12)"
    }

    use "$temp/_es_bins_`win'_bal.dta", clear
    merge m:1 row_id using "$temp/_recip_dynamics_bal.dta", ///
        keepusing(lev_recip_terc) nogenerate

    * Restrict to plotable range
    keep if semester >= `sem_min' & semester <= `sem_max'

    * Collapse to tercile x semester means
    collapse (mean) pct_employed sd_wage cv_wage any_gap n_transitions ///
             (count) n_obs = pct_employed, by(lev_recip_terc semester)

    save "$temp/_es_means_`win'_bal.dta", replace

    * --- Generate figures ---

    local outcomes "pct_employed sd_wage cv_wage any_gap n_transitions"
    local fig_titles `" "Pct Months Employed" "SD of Wages" "CV of Wages" "Any Employment Gap" "Employment Transitions" "'

    local n_out : word count `outcomes'

    forvalues i = 1/`n_out' {
        local v : word `i' of `outcomes'
        local ftitle : word `i' of `fig_titles'

        twoway (connected `v' semester if lev_recip_terc == 1, ///
                    msymbol(O) lcolor(navy) mcolor(navy) lwidth(medthick)) ///
               (connected `v' semester if lev_recip_terc == 2, ///
                    msymbol(D) lcolor(forest_green) mcolor(forest_green) lwidth(medthick)) ///
               (connected `v' semester if lev_recip_terc == 3, ///
                    msymbol(T) lcolor(cranberry) mcolor(cranberry) lwidth(medthick)), ///
               xline(0, lcolor(gs10) lpattern(dash)) ///
               xtitle("Semesters relative to sorteo (6-month bins)") ///
               ytitle("`ftitle'") ///
               legend(order(1 "Low Leverage" 2 "Medium" 3 "High Leverage") rows(1) pos(6)) ///
               title("`ftitle' by Leverage Tercile (Balanced)") ///
               subtitle("`win_label' — Recipients only") ///
               `xlab' scheme(s2color) name(bales`win'_`v', replace)

        graph export "$figures/bales`win'_`v'.pdf", replace
        graph export "$figures/bales`win'_`v'.png", replace width(1200)

        di as text "  Saved: bales`win'_`v'.pdf / .png"
    }
}


/*==============================================================================
  CLEANUP
==============================================================================*/

cap erase "$temp/_recip_dynamics_bal.dta"
cap erase "$temp/_prepost_24m_bal.dta"
cap erase "$temp/_prepost_full_bal.dta"
cap erase "$temp/_recip_prepost_bal.dta"
* Keep _es_bins and _es_means for custom analyses


/*==============================================================================
  SUMMARY
==============================================================================*/

di as text _n(3) "================================================"
di as text       "  PROCREAR Leverage Dynamics (Balanced Sorteos) — Complete"
di as text       "================================================"
di as text _n "Balanced sorteos: p_wage>0.1, N>=30, winners>=5"
di as text _n "Approach A: Pre-post differences (post - pre)"
di as text "  Continuous leverage + leverage tercile dummies"
di as text "Approach B: Event study with 6-month semesters"
di as text "  Person FE: Post x leverage interaction"
di as text "  Figures: raw means by leverage tercile"
di as text _n "Windows: 24-month symmetric and full pre/post"
di as text "Sample: Credit recipients with valid leverage (balanced sorteos)"
di as text _n "Tables saved to: $tables/"
di as text "  --- Pre-post continuous (2 windows x noctl/ctl = 4) ---"
di as text "  ballevdyn24_prepost_*.tex / ballevdynfull_prepost_*.tex"
di as text "  --- Pre-post tercile (2 windows x noctl/ctl = 4) ---"
di as text "  ballevdyn24_prepost_terc_*.tex / ballevdynfull_prepost_terc_*.tex"
di as text "  --- Event study panel FE (2 windows = 2) ---"
di as text "  ballevdynes24_panel.tex / ballevdynesfull_panel.tex"
di as text _n "Figures saved to: $figures/"
di as text "  --- Event study plots (5 outcomes x 2 windows = 10) ---"
di as text "  bales24_{outcome}.pdf / balesfull_{outcome}.pdf"
di as text _n "Event study means saved to: $temp/"
di as text "  _es_means_24m_bal.dta / _es_means_full_bal.dta"
di as text _n "Total: 10 tables + 10 figures"
