/*==============================================================================
  Match ubicacion_dateas → CP4 + lat/lon usando geonames_ar

  Pipeline:
    1. Cargar valores únicos de ubicacion_dateas
    2. Parsear "Localidad, Provincia"
    3. Normalizar (lowercase, sin acentos, trim, sin caracteres especiales)
    4. Match exacto contra geonames_ar normalizado
    5. Fallback: solo localidad (si única)
    6. Generar residual para Gemini API
    7. Guardar lookup_ubicacion_dateas.dta
==============================================================================*/

clear all
set more off

global root "/Users/francomartinvazquez/Dropbox (Personal)/Procrear Santanna"
global data "$root/DATA"

/*------------------------------------------------------------------------------
  Helper: normalizar string (lowercase, sin acentos, sin caracteres especiales)
------------------------------------------------------------------------------*/
capture program drop _normalize
program define _normalize
    syntax varname
    local v `varlist'
    replace `v' = lower(strtrim(`v'))

    * Reemplazar acentos
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

    * Sacar caracteres especiales (puntos, guiones)
    replace `v' = subinstr(`v', ".", "", .)
    replace `v' = subinstr(`v', "-", " ", .)
    replace `v' = subinstr(`v', "/", " ", .)

    * Comprimir espacios múltiples (max 4 pasadas)
    forvalues k = 1/4 {
        replace `v' = subinstr(`v', "  ", " ", .)
    }
    replace `v' = strtrim(`v')
end

/*------------------------------------------------------------------------------
  PASO 1: Cargar geonames y normalizar
------------------------------------------------------------------------------*/
di as text _n "==========================================================="
di as text "PASO 1: Preparar geonames_ar normalizado"
di as text "==========================================================="

use "$data/geonames_ar.dta", clear
di as text "  Filas: " _N

* Normalizar campos
gen str place_norm = place_name
_normalize place_norm

gen str prov_norm = provincia
_normalize prov_norm

* Mapear provincia → variantes comunes en ubicacion_dateas
* (Buenos Aires CABA suele venir como "CABA" sola sin provincia)
gen str prov_alt = ""
replace prov_alt = "caba" if prov_norm == "ciudad autonoma de buenos aires"
replace prov_alt = "ciudad de buenos aires" if prov_norm == "ciudad autonoma de buenos aires"
replace prov_alt = "capital federal" if prov_norm == "ciudad autonoma de buenos aires"
replace prov_alt = "tierra del fuego antartida e islas del atlantico sur" if prov_norm == "tierra del fuego"

* Crear key principal: place|prov
gen str key_full = place_norm + "|" + prov_norm

* Agrupar (algunos place_name tienen múltiples CP4 - tomamos el primero por accuracy)
* Mantenemos todos para ver pero también un "primary" lookup
preserve
    keep place_norm prov_norm key_full cp4 latitude longitude accuracy place_name provincia

    * Por cada key_full, quedarnos con la mejor accuracy
    gsort key_full -accuracy
    by key_full: keep if _n == 1

    save "$data/_tmp_geonames_key_full.dta", replace
    di as text "  Keys únicas (place+prov): " _N
restore

* Otro lookup: solo por place_name (para fallback)
preserve
    keep place_norm cp4 latitude longitude accuracy provincia place_name

    * Marcar localidades que aparecen en >1 provincia (ambiguas)
    bysort place_norm: gen n_provs = _N

    * Para fallback solo guardamos las que aparecen en una sola provincia
    keep if n_provs == 1
    drop n_provs

    save "$data/_tmp_geonames_place_only.dta", replace
    di as text "  Place únicos (solo 1 provincia): " _N
restore

/*------------------------------------------------------------------------------
  PASO 2: Extraer valores únicos de ubicacion_dateas
------------------------------------------------------------------------------*/
di as text _n "==========================================================="
di as text "PASO 2: Extraer ubicacion_dateas únicas desde Data_sorteos_with_X"
di as text "==========================================================="

use ubicacion_dateas using "$data/Data_sorteos_with_X.dta", clear
quietly count
di as text "  Filas totales en Data_sorteos_with_X: " _N

* Eliminar missing y duplicados
drop if mi(ubicacion_dateas)
quietly count
di as text "  Filas con ubicacion_dateas no missing: " _N

contract ubicacion_dateas
drop _freq
di as text "  Valores únicos: " _N

/*------------------------------------------------------------------------------
  PASO 3: Parsear "Localidad, Provincia"
------------------------------------------------------------------------------*/
di as text _n "==========================================================="
di as text "PASO 3: Parsear ubicacion_dateas → (localidad, provincia)"
di as text "==========================================================="

* Buscar la última coma (la división Localidad, Provincia)
gen comma_pos = strrpos(ubicacion_dateas, ",")

* Si hay coma: localidad = antes, provincia = después
gen str loc_raw = ""
gen str prov_raw = ""

replace loc_raw = substr(ubicacion_dateas, 1, comma_pos - 1) if comma_pos > 0
replace prov_raw = substr(ubicacion_dateas, comma_pos + 1, .) if comma_pos > 0

* Si NO hay coma: todo es la "localidad" (o puede ser solo "CABA")
replace loc_raw = ubicacion_dateas if comma_pos == 0
replace prov_raw = "" if comma_pos == 0

* Caso especial: si dice "CABA" sola
replace prov_raw = "CABA" if comma_pos == 0 & (lower(strtrim(loc_raw)) == "caba")
replace loc_raw = "" if comma_pos == 0 & (lower(strtrim(loc_raw)) == "caba")

drop comma_pos

* Normalizar
_normalize loc_raw
_normalize prov_raw

/*------------------------------------------------------------------------------
  PASO 4: Match exacto place+prov
------------------------------------------------------------------------------*/
di as text _n "==========================================================="
di as text "PASO 4: Match exacto (place+prov)"
di as text "==========================================================="

* Construir key
gen str key_full = loc_raw + "|" + prov_raw

merge m:1 key_full using "$data/_tmp_geonames_key_full.dta", ///
    keep(master match) keepusing(cp4 latitude longitude accuracy place_name provincia)

quietly count if _merge == 3
di as text "  Match exacto (place+prov): " r(N)
quietly count if _merge == 1
di as text "  No match: " r(N)

rename _merge merge_exact
gen str match_method = "exact_place_prov" if merge_exact == 3

/*------------------------------------------------------------------------------
  PASO 5: Fallback - solo localidad (para los que no tuvieron match)
------------------------------------------------------------------------------*/
di as text _n "==========================================================="
di as text "PASO 5: Fallback solo por localidad"
di as text "==========================================================="

* Para los que tuvieron _merge != 3, intentar match solo por place
* Renombrar las cols del primer merge para preservar
rename cp4 cp4_v1
rename latitude latitude_v1
rename longitude longitude_v1
rename accuracy accuracy_v1
rename place_name place_name_v1
rename provincia provincia_v1

* Crear place_norm = loc_raw para el merge
gen str place_norm = loc_raw

merge m:1 place_norm using "$data/_tmp_geonames_place_only.dta", ///
    keep(master match) keepusing(cp4 latitude longitude accuracy place_name provincia)

quietly count if _merge == 3 & mi(match_method)
di as text "  Match adicional (solo place, unambiguo): " r(N)

* Consolidar: si exact match falló, usar fallback
replace cp4_v1 = cp4 if mi(cp4_v1) & _merge == 3
replace latitude_v1 = latitude if mi(latitude_v1) & _merge == 3
replace longitude_v1 = longitude if mi(longitude_v1) & _merge == 3
replace accuracy_v1 = accuracy if mi(accuracy_v1) & _merge == 3
replace place_name_v1 = place_name if mi(place_name_v1) & _merge == 3
replace provincia_v1 = provincia if mi(provincia_v1) & _merge == 3
replace match_method = "place_only_unambig" if mi(match_method) & _merge == 3

drop cp4 latitude longitude accuracy place_name provincia place_norm _merge

* Renombrar de vuelta
rename cp4_v1 cp4
rename latitude_v1 latitude
rename longitude_v1 longitude
rename accuracy_v1 accuracy
rename place_name_v1 place_name
rename provincia_v1 provincia

/*------------------------------------------------------------------------------
  PASO 6: Stats finales
------------------------------------------------------------------------------*/
di as text _n "==========================================================="
di as text "PASO 6: Resultados"
di as text "==========================================================="

quietly count
local total = r(N)
di as text "  Total ubicacion_dateas únicas: " `total'

quietly count if !mi(cp4)
di as text "  Matched (con CP4): " r(N) " (" %5.1f r(N)/`total'*100 "%)"

quietly count if mi(cp4)
di as text "  Sin match (residual para Gemini): " r(N) " (" %5.1f r(N)/`total'*100 "%)"

di as text _n "  Distribución por método:"
tab match_method, missing

di as text _n "  Sample de matches exitosos:"
list ubicacion_dateas loc_raw prov_raw cp4 place_name provincia in 1/15 if !mi(cp4), sep(0) abbreviate(40) noobs

di as text _n "  Sample de NO matches:"
preserve
    keep if mi(cp4)
    list ubicacion_dateas loc_raw prov_raw in 1/30, sep(0) abbreviate(60) noobs
restore

/*------------------------------------------------------------------------------
  PASO 7: Guardar
------------------------------------------------------------------------------*/
label var cp4 "Código postal 4 dígitos (matched)"
label var latitude "Latitud (matched)"
label var longitude "Longitud (matched)"
label var accuracy "Accuracy del match geonames"
label var place_name "Nombre localidad en geonames"
label var provincia "Provincia en geonames"
label var match_method "Método de match (exact_place_prov, place_only_unambig)"
label var loc_raw "Localidad parseada y normalizada"
label var prov_raw "Provincia parseada y normalizada"

order ubicacion_dateas loc_raw prov_raw match_method cp4 place_name provincia latitude longitude accuracy
sort ubicacion_dateas

save "$data/lookup_ubicacion_dateas.dta", replace
di as text _n "  Saved: $data/lookup_ubicacion_dateas.dta"

* Guardar residual aparte (para enviar a Gemini)
preserve
    keep if mi(cp4)
    keep ubicacion_dateas loc_raw prov_raw
    save "$data/_residual_ubicacion_for_gemini.dta", replace

    * También como CSV
    export delimited "$data/_residual_ubicacion_for_gemini.csv", replace
    di as text "  Saved residual: $data/_residual_ubicacion_for_gemini.dta y .csv (" _N " filas)"
restore

* Limpiar temporales
erase "$data/_tmp_geonames_key_full.dta"
erase "$data/_tmp_geonames_place_only.dta"
di as text _n "  Done."
