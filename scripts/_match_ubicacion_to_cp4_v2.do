/*==============================================================================
  Match ubicacion_dateas → CP4 v2 (con cleanup de prefijos INDEC y truncados)
==============================================================================*/

clear all
set more off

global root "/Users/francomartinvazquez/Dropbox (Personal)/Procrear Santanna"
global data "$root/DATA"

capture program drop _normalize
program define _normalize
    syntax varname
    local v `varlist'
    replace `v' = lower(strtrim(`v'))
    replace `v' = subinstr(`v', "á", "a", .)
    replace `v' = subinstr(`v', "é", "e", .)
    replace `v' = subinstr(`v', "í", "i", .)
    replace `v' = subinstr(`v', "ó", "o", .)
    replace `v' = subinstr(`v', "ú", "u", .)
    replace `v' = subinstr(`v', "ü", "u", .)
    replace `v' = subinstr(`v', "ñ", "n", .)
    replace `v' = subinstr(`v', "Á", "a", .)
    replace `v' = subinstr(`v', "É", "e", .)
    replace `v' = subinstr(`v', "Í", "i", .)
    replace `v' = subinstr(`v', "Ó", "o", .)
    replace `v' = subinstr(`v', "Ú", "u", .)
    replace `v' = subinstr(`v', "Ñ", "n", .)
    replace `v' = subinstr(`v', ".", "", .)
    replace `v' = subinstr(`v', "-", " ", .)
    replace `v' = subinstr(`v', "/", " ", .)
    forvalues k = 1/4 {
        replace `v' = subinstr(`v', "  ", " ", .)
    }
    replace `v' = strtrim(`v')
end

capture program drop _strip_code
program define _strip_code
    syntax varname
    local v `varlist'

    * Códigos INDEC: 4+ dígitos al inicio (no afecta "11 de mayo" o "1 de mayo")
    * Caso 1: "0210901 moron" → "moron" (4+ dígitos opc letra N/S + espacio)
    replace `v' = regexr(`v', "^[0-9]{4,}[ns]? +", "")

    * Caso 2: "018rio gallegos" → "rio gallegos" (3+ dígitos sin espacio antes letra)
    * Usamos substr basado en regexm
    gen _has_prefix = regexm(`v', "^([0-9]{3,})([a-z])")
    quietly count if _has_prefix == 1
    if r(N) > 0 {
        replace `v' = regexs(2) + regexr(`v', "^[0-9]{3,}", "") ///
            if _has_prefix == 1
        * Approach simpler: just substr off the leading digits
        replace `v' = regexr(`v', "^[0-9]{3,}", "") if _has_prefix == 1
    }
    drop _has_prefix

    * Solo dígitos → vacío
    replace `v' = regexr(`v', "^[0-9]+$", "")

    * Paréntesis y contenido "(...)"
    replace `v' = regexr(`v', "\([^)]*\)", "")

    * Caracteres raros que vimos: ^, ¹, ìë
    replace `v' = subinstr(`v', "^", "", .)
    replace `v' = subinstr(`v', "¹", "", .)
    replace `v' = subinstr(`v', "ì", "i", .)
    replace `v' = subinstr(`v', "ë", "e", .)
    replace `v' = subinstr(`v', "ê", "e", .)
    replace `v' = subinstr(`v', "ô", "o", .)
    replace `v' = subinstr(`v', "â", "a", .)
    replace `v' = subinstr(`v', "$", "", .)

    replace `v' = strtrim(`v')
    forvalues k = 1/4 {
        replace `v' = subinstr(`v', "  ", " ", .)
    }
end

/*------------------------------------------------------------------------------
  Geonames normalizado → lookups temporales
------------------------------------------------------------------------------*/
use "$data/geonames_ar.dta", clear
gen str place_norm = place_name
_normalize place_norm
gen str prov_norm = provincia
_normalize prov_norm

preserve
    keep place_norm prov_norm cp4 latitude longitude accuracy place_name provincia
    gen str key_full = place_norm + "|" + prov_norm
    gsort key_full -accuracy
    by key_full: keep if _n == 1
    save "$data/_tmp_g_full.dta", replace
restore

preserve
    keep place_norm cp4 latitude longitude accuracy provincia place_name
    bysort place_norm: gen n_provs = _N
    keep if n_provs == 1
    drop n_provs
    save "$data/_tmp_g_place.dta", replace
restore

preserve
    keep place_norm prov_norm cp4 latitude longitude accuracy place_name provincia
    bysort place_norm prov_norm: keep if _n == 1
    save "$data/_tmp_g_place_prov.dta", replace
restore

/*------------------------------------------------------------------------------
  ubicacion_dateas únicas → parsear y limpiar
------------------------------------------------------------------------------*/
use ubicacion_dateas using "$data/Data_sorteos_with_X.dta", clear
drop if mi(ubicacion_dateas)
contract ubicacion_dateas
drop _freq
di as text _n "  Únicas: " _N

gen comma_pos = strrpos(ubicacion_dateas, ",")
gen str loc_raw = ""
gen str prov_raw = ""
replace loc_raw = substr(ubicacion_dateas, 1, comma_pos - 1) if comma_pos > 0
replace prov_raw = substr(ubicacion_dateas, comma_pos + 1, .) if comma_pos > 0
replace loc_raw = ubicacion_dateas if comma_pos == 0
replace prov_raw = "CABA" if comma_pos == 0 & lower(strtrim(loc_raw)) == "caba"
replace loc_raw = "" if comma_pos == 0 & lower(strtrim(loc_raw)) == "caba"
drop comma_pos

_normalize loc_raw
_normalize prov_raw
_strip_code loc_raw

* Normalizar variantes provinciales
replace prov_raw = "ciudad autonoma de buenos aires" if prov_raw == "caba"
replace prov_raw = "ciudad autonoma de buenos aires" if prov_raw == "capital federal"
replace prov_raw = "ciudad autonoma de buenos aires" if prov_raw == "ciudad de buenos aires"
replace prov_raw = "tierra del fuego" if strpos(prov_raw, "tierra del fuego") > 0

gen loc_len = length(loc_raw)
gen byte is_truncated = (loc_len > 0 & loc_len <= 11)

save "$data/_tmp_uniques.dta", replace

/*------------------------------------------------------------------------------
  PASO A: Match exacto place+prov
------------------------------------------------------------------------------*/
gen str key_full = loc_raw + "|" + prov_raw
merge m:1 key_full using "$data/_tmp_g_full.dta", ///
    keep(master match) keepusing(cp4 latitude longitude accuracy place_name provincia)
gen str match_method = ""
replace match_method = "exact_place_prov" if _merge == 3
quietly count if _merge == 3
di as text _n "  PASO A - exact place+prov: " r(N)
drop _merge key_full

/*------------------------------------------------------------------------------
  PASO B: Match solo place (unambiguo)
------------------------------------------------------------------------------*/
rename cp4 cp4_v
rename latitude lat_v
rename longitude lon_v
rename accuracy acc_v
rename place_name pname_v
rename provincia prov_v

gen str place_norm = loc_raw
merge m:1 place_norm using "$data/_tmp_g_place.dta", ///
    keep(master match) keepusing(cp4 latitude longitude accuracy place_name provincia)

quietly count if _merge == 3 & mi(match_method)
di as text "  PASO B - place unambiguo: " r(N)

replace cp4_v = cp4 if mi(cp4_v) & _merge == 3
replace lat_v = latitude if mi(lat_v) & _merge == 3
replace lon_v = longitude if mi(lon_v) & _merge == 3
replace acc_v = accuracy if mi(acc_v) & _merge == 3
replace pname_v = place_name if mi(pname_v) & _merge == 3
replace prov_v = provincia if mi(prov_v) & _merge == 3
replace match_method = "place_unambig" if mi(match_method) & _merge == 3
drop cp4 latitude longitude accuracy place_name provincia place_norm _merge

/*------------------------------------------------------------------------------
  PASO C: Starts-with truncados dentro de la provincia
------------------------------------------------------------------------------*/
preserve
    keep if mi(cp4_v) & is_truncated & !mi(loc_raw) & !mi(prov_raw)
    keep ubicacion_dateas loc_raw prov_raw
    quietly count
    local n_truncs = r(N)
    di as text _n "  Truncados sin match (intento starts-with): " `n_truncs'

    if `n_truncs' > 0 {
        save "$data/_tmp_trunc.dta", replace

        use "$data/_tmp_g_place_prov.dta", clear
        rename place_norm gn_place
        rename prov_norm gn_prov
        rename cp4 gn_cp4
        rename latitude gn_lat
        rename longitude gn_lon
        rename accuracy gn_acc
        rename place_name gn_pname
        rename provincia gn_prov_full

        * joinby por prov para ahorrar
        gen str prov_raw = gn_prov
        joinby prov_raw using "$data/_tmp_trunc.dta", unmatched(none)

        * Filtrar starts-with
        gen byte ok = (strpos(gn_place, loc_raw) == 1)
        keep if ok == 1

        * Best accuracy
        gsort ubicacion_dateas -gn_acc
        by ubicacion_dateas: keep if _n == 1

        keep ubicacion_dateas gn_cp4 gn_lat gn_lon gn_acc gn_pname gn_prov_full
        save "$data/_tmp_trunc_match.dta", replace
        di as text "    Recuperados: " _N
    }
    else {
        clear
        gen str ubicacion_dateas = ""
        gen gn_cp4 = .
        gen gn_lat = .
        gen gn_lon = .
        gen gn_acc = .
        gen str gn_pname = ""
        gen str gn_prov_full = ""
        save "$data/_tmp_trunc_match.dta", replace
    }
restore

merge m:1 ubicacion_dateas using "$data/_tmp_trunc_match.dta", ///
    keep(master match) nogen

quietly count if !mi(gn_cp4) & mi(cp4_v)
di as text "  PASO C - starts-with truncados (adicional): " r(N)

replace cp4_v = gn_cp4 if mi(cp4_v) & !mi(gn_cp4)
replace lat_v = gn_lat if mi(lat_v) & !mi(gn_lat)
replace lon_v = gn_lon if mi(lon_v) & !mi(gn_lon)
replace acc_v = gn_acc if mi(acc_v) & !mi(gn_acc)
replace pname_v = gn_pname if mi(pname_v) & !mi(gn_pname)
replace prov_v = gn_prov_full if mi(prov_v) & !mi(gn_prov_full)
replace match_method = "starts_with_trunc" if mi(match_method) & !mi(gn_cp4)
drop gn_*

/*------------------------------------------------------------------------------
  Stats finales
------------------------------------------------------------------------------*/
rename cp4_v cp4
rename lat_v latitude
rename lon_v longitude
rename acc_v accuracy
rename pname_v place_name
rename prov_v provincia

di as text _n "==========================================================="
di as text "RESULTADOS V2"
di as text "==========================================================="

quietly count
local total = r(N)
di as text "  Total únicas: " `total'

quietly count if !mi(cp4)
local matched = r(N)
di as text "  Matched: " `matched' " (" %5.1f `matched'/`total'*100 "%)"

quietly count if mi(cp4)
local unmatched = r(N)
di as text "  Sin match: " `unmatched' " (" %5.1f `unmatched'/`total'*100 "%)"

di as text _n "  Por método:"
tab match_method, missing

di as text _n "  Sample matches starts-with-trunc:"
list ubicacion_dateas loc_raw place_name cp4 in 1/15 if match_method == "starts_with_trunc", sep(0) abbreviate(40) noobs

/*------------------------------------------------------------------------------
  Coverage ponderada
------------------------------------------------------------------------------*/
preserve
    keep ubicacion_dateas cp4 match_method
    rename cp4 cp4_assigned
    save "$data/_tmp_cov.dta", replace
restore

use ubicacion_dateas using "$data/Data_sorteos_with_X.dta", clear
drop if mi(ubicacion_dateas)
merge m:1 ubicacion_dateas using "$data/_tmp_cov.dta", keep(master match) nogen

quietly count
local n_total = r(N)
quietly count if !mi(cp4_assigned)
local n_matched = r(N)
di as text _n "  Coverage ponderada (filas):"
di as text "    Total: " `n_total'
di as text "    Con CP4: " `n_matched' " (" %5.1f `n_matched'/`n_total'*100 "%)"

erase "$data/_tmp_cov.dta"

/*------------------------------------------------------------------------------
  Guardar lookup
------------------------------------------------------------------------------*/
use "$data/_tmp_uniques.dta", clear  // re-cargar uniques

gen str key_full = loc_raw + "|" + prov_raw
merge m:1 key_full using "$data/_tmp_g_full.dta", ///
    keep(master match) keepusing(cp4 latitude longitude accuracy place_name provincia)
gen str match_method = ""
replace match_method = "exact_place_prov" if _merge == 3
drop _merge key_full

rename cp4 cp4_v
rename latitude lat_v
rename longitude lon_v
rename accuracy acc_v
rename place_name pname_v
rename provincia prov_v

gen str place_norm = loc_raw
merge m:1 place_norm using "$data/_tmp_g_place.dta", ///
    keep(master match) keepusing(cp4 latitude longitude accuracy place_name provincia)
replace cp4_v = cp4 if mi(cp4_v) & _merge == 3
replace lat_v = latitude if mi(lat_v) & _merge == 3
replace lon_v = longitude if mi(lon_v) & _merge == 3
replace acc_v = accuracy if mi(acc_v) & _merge == 3
replace pname_v = place_name if mi(pname_v) & _merge == 3
replace prov_v = provincia if mi(prov_v) & _merge == 3
replace match_method = "place_unambig" if mi(match_method) & _merge == 3
drop cp4 latitude longitude accuracy place_name provincia place_norm _merge

merge m:1 ubicacion_dateas using "$data/_tmp_trunc_match.dta", ///
    keep(master match) nogen
replace cp4_v = gn_cp4 if mi(cp4_v) & !mi(gn_cp4)
replace lat_v = gn_lat if mi(lat_v) & !mi(gn_lat)
replace lon_v = gn_lon if mi(lon_v) & !mi(gn_lon)
replace acc_v = gn_acc if mi(acc_v) & !mi(gn_acc)
replace pname_v = gn_pname if mi(pname_v) & !mi(gn_pname)
replace prov_v = gn_prov_full if mi(prov_v) & !mi(gn_prov_full)
replace match_method = "starts_with_trunc" if mi(match_method) & !mi(gn_cp4)
drop gn_*

rename cp4_v cp4
rename lat_v latitude
rename lon_v longitude
rename acc_v accuracy
rename pname_v place_name
rename prov_v provincia

label var cp4 "Código postal 4 dígitos (matched)"
label var latitude "Latitud (matched)"
label var longitude "Longitud (matched)"
label var accuracy "Accuracy del match geonames"
label var place_name "Nombre localidad en geonames"
label var provincia "Provincia en geonames"
label var match_method "Método de match"
label var loc_raw "Localidad parseada y normalizada"
label var prov_raw "Provincia parseada y normalizada"
label var is_truncated "Loc original parecía truncada (<12 chars)"

order ubicacion_dateas loc_raw prov_raw match_method cp4 place_name provincia latitude longitude accuracy is_truncated
sort ubicacion_dateas

save "$data/lookup_ubicacion_dateas.dta", replace
di as text _n "  Saved: $data/lookup_ubicacion_dateas.dta"

* Residual
preserve
    keep if mi(cp4)
    keep ubicacion_dateas loc_raw prov_raw is_truncated
    save "$data/_residual_ubicacion_for_gemini.dta", replace
    export delimited "$data/_residual_ubicacion_for_gemini.csv", replace
    di as text "  Residual: " _N " filas"
restore

* Cleanup
erase "$data/_tmp_g_full.dta"
erase "$data/_tmp_g_place.dta"
erase "$data/_tmp_g_place_prov.dta"
erase "$data/_tmp_uniques.dta"
erase "$data/_tmp_trunc_match.dta"
capture erase "$data/_tmp_trunc.dta"

di as text _n "  Done."
