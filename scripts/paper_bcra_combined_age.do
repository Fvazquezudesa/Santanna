/*==============================================================================
  PROCREAR — Combined BCRA Table (Age Control, IV-only)

  Single .tex table with 7 columns, all controlling only for edad. IV / 2SLS
  panel only (no ITT).

  Column layout:
    (1) Total Debt       — all entities
    (2) Slow Payer       — all entities
    (3) Q1 Cost          — excl. Hipotecario
    (4) Q2 Cost          — excl. Hipotecario
    (5) Q3 Cost          — excl. Hipotecario
    (6) Banked           — all entities
    (7) Q4 Cost          — excl. Hipotecario

  Q-Cost dummies: holds debt at any entity in cost-quartile X at the last
  BCRA period the applicant is observed. Cutoffs (p25, p50, p75) from the
  median_costo distribution of entities in the analysis sample. NOT mutually
  exclusive at the person level.

  Prerequisites in $temp/:
    cross_section_bcra_v2.dta              (from paper_bcra_outcomes.do)
    cross_section_bcra_nohipo_v2.dta       (from paper_bcra_outcomes.do)
    _q_dummies_person_nohipo_v3_lastperiod.dta
        (from scripts/_explore_q2_q3_cost_nohipo_v3.do — Q1-Q4 dummies,
         last-period semantics, no-Hipo sample)

  Output: $tables/bcra_combined_age.tex
==============================================================================*/

clear all
set more off
set matsize 10000

global root "/Users/francomartinvazquez/Dropbox (Personal)/Procrear Santanna"
global temp "$root/TEMP"
global tables "$root/Procrear/tables"

local controls "edad"

/*------------------------------------------------------------------
  ALL-ENTITIES sample — cols (1) Total Debt, (2) Slow Payer, (6) Banked
------------------------------------------------------------------*/
use "$temp/cross_section_bcra_v2.dta", clear

* --- (1) Total Debt -------------------------------------------------
quietly ivreghdfe total_deuda `controls' (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
local b1   = _b[receptor]
local se1  = _se[receptor]
local n1   = e(N)
local fs1  = e(widstat)
quietly sum total_deuda if ganador == 0
local cm1  = r(mean)

* --- (2) Slow Payer -----------------------------------------------
quietly ivreghdfe moroso_ever `controls' (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
local b2   = _b[receptor]
local se2  = _se[receptor]
local n2   = e(N)
local fs2  = e(widstat)
quietly sum moroso_ever if ganador == 0
local cm2  = r(mean)

* --- (6) Banked -----------------------------------------------------
quietly ivreghdfe active_bcra `controls' (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
local b6   = _b[receptor]
local se6  = _se[receptor]
local n6   = e(N)
local fs6  = e(widstat)
quietly sum active_bcra if ganador == 0
local cm6  = r(mean)


/*------------------------------------------------------------------
  EXCL.-HIPOTECARIO sample — cols (3)-(5) Q1, Q2, Q3 and (7) Q4
------------------------------------------------------------------*/
use "$temp/cross_section_bcra_nohipo_v2.dta", clear
merge m:1 id_anon using "$temp/_q_dummies_person_nohipo_v3_lastperiod.dta", ///
    keep(master match) nogenerate
foreach v in in_q1_costo in_q2_costo in_q3_costo in_q4_costo_check {
    replace `v' = 0 if missing(`v')
}

* (3) Q1
quietly ivreghdfe in_q1_costo `controls' (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
local b3 = _b[receptor]
local se3 = _se[receptor]
local n3 = e(N)
local fs3 = e(widstat)
quietly sum in_q1_costo if ganador == 0
local cm3 = r(mean)

* (4) Q2
quietly ivreghdfe in_q2_costo `controls' (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
local b4 = _b[receptor]
local se4 = _se[receptor]
local n4 = e(N)
local fs4 = e(widstat)
quietly sum in_q2_costo if ganador == 0
local cm4 = r(mean)

* (5) Q3
quietly ivreghdfe in_q3_costo `controls' (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
local b5 = _b[receptor]
local se5 = _se[receptor]
local n5 = e(N)
local fs5 = e(widstat)
quietly sum in_q3_costo if ganador == 0
local cm5 = r(mean)

* (7) Q4
quietly ivreghdfe in_q4_costo_check `controls' (receptor = ganador), absorb(sorteo_fe) cluster(id_anon)
local b7 = _b[receptor]
local se7 = _se[receptor]
local n7 = e(N)
local fs7 = e(widstat)
quietly sum in_q4_costo_check if ganador == 0
local cm7 = r(mean)


/*------------------------------------------------------------------
  Significance stars
------------------------------------------------------------------*/
forvalues j = 1/7 {
    local t`j' = abs(`b`j''/`se`j'')
    if      `t`j'' > 2.576 local star`j' "\sym{***}"
    else if `t`j'' > 1.960 local star`j' "\sym{**}"
    else if `t`j'' > 1.645 local star`j' "\sym{*}"
    else                   local star`j' ""
}

/*------------------------------------------------------------------
  Format: col 1 (Total Debt) in ARS, cols 2-7 as proportions
------------------------------------------------------------------*/
local b1f  : display %9.1fc `b1'
local se1f : display %9.1fc `se1'
local cm1f : display %9.1fc `cm1'
forvalues j = 2/7 {
    local b`j'f  : display %9.4f `b`j''
    local se`j'f : display %9.4f `se`j''
    local cm`j'f : display %6.4f `cm`j''
}
forvalues j = 1/7 {
    local fs`j'f : display %9.0fc `fs`j''
    local n`j'f  : display %12.0fc `n`j''
}


/*------------------------------------------------------------------
  Write the .tex
------------------------------------------------------------------*/
capture file close fh
file open fh using "$tables/bcra_combined_age.tex", write replace

file write fh "\begin{table}[H]\centering" _n
file write fh "\def\sym#1{\ifmmode^{#1}\else\(^{#1}\)\fi}" _n
file write fh "\caption{BCRA Financial Outcomes}" _n
file write fh "\label{tab:bcra_combined_age}" _n
file write fh "\scriptsize" _n
file write fh "\setlength{\tabcolsep}{0pt}" _n
file write fh "\begin{tabular}{@{}l*{7}{>{\centering\arraybackslash}p{0.108\textwidth}}@{}}" _n
file write fh "\hline\hline" _n
file write fh " & Total Debt & Slow Payer & Q1 Cost & Q2 Cost & Q3 Cost & Banked & Q4 Cost \\" _n
file write fh " & (1) & (2) & (3) & (4) & (5) & (6) & (7) \\" _n
file write fh "\hline" _n

file write fh "Recipient & `b1f'`star1' & `b2f'`star2' & `b3f'`star3' & `b4f'`star4' & `b5f'`star5' & `b6f'`star6' & `b7f'`star7' \\" _n
file write fh "          & (`se1f') & (`se2f') & (`se3f') & (`se4f') & (`se5f') & (`se6f') & (`se7f') \\" _n
file write fh "\hline" _n

file write fh "Control mean & `cm1f' & `cm2f' & `cm3f' & `cm4f' & `cm5f' & `cm6f' & `cm7f' \\" _n
file write fh "First-stage F & `fs1f' & `fs2f' & `fs3f' & `fs4f' & `fs5f' & `fs6f' & `fs7f' \\" _n
file write fh "Observations & `n1f' & `n2f' & `n3f' & `n4f' & `n5f' & `n6f' & `n7f' \\" _n
file write fh "\hline\hline" _n
file write fh "\end{tabular}" _n
file write fh "\par\smallskip" _n
file write fh "\begin{minipage}{0.98\textwidth}" _n
file write fh "\scriptsize" _n
file write fh "2SLS. Instrument: \emph{Winner}. All specifications include age at lottery date as the sole covariate plus lottery-round fixed effects. \emph{Total Debt}: sum of debt outstanding in nominal ARS across BCRA-registered entities at the last period the applicant is observed in the credit registry; set to zero if the last observed period is before November 2025. \emph{Slow Payer}: indicator equal to one if the applicant had BCRA situation code \(> 1\) (code 2/3/4/5) at any point in the panel; applicants with no BCRA record are coded as 0. \emph{Banked}: indicator for an active record in the credit registry at the end of the panel. \emph{Q-X Cost}: indicator equal to one if the applicant holds any debt at an entity whose median CFT lies in the X-th quartile of the cost distribution at the last BCRA period the applicant is observed; cutoffs (p25, p50, p75) computed across entities in the analysis sample. The four Q-Cost dummies are not mutually exclusive (a person may hold debt at entities across multiple quartiles). Cost-quartile columns use the excl.-Hipotecario sample (Hipotecario rows dropped before person-month collapse). SE clustered at person level (parentheses).\\" _n
file write fh "\sym{*} \(p<0.10\), \sym{**} \(p<0.05\), \sym{***} \(p<0.01\)" _n
file write fh "\end{minipage}" _n
file write fh "\end{table}" _n

file close fh

di as text _n "==============================================================="
di as text "  Combined BCRA table (7 cols, IV-only) written to:"
di as text "  $tables/bcra_combined_age.tex"
di as text "==============================================================="
