/*==============================================================================
  Import Geonames AR.txt → guardar como DATA/geonames_ar.dta
==============================================================================*/

clear all
set more off

global root "/Users/francomartinvazquez/Dropbox (Personal)/Procrear Santanna"
global data "$root/DATA"

* Format AR.txt (tab-separated, no header):
*   1: country_code (AR)
*   2: postal_code (CP4 o CP+suffix)
*   3: place_name (localidad)
*   4: admin_name1 (provincia)
*   5: admin_code1
*   6: admin_name2
*   7: admin_code2
*   8: admin_name3
*   9: admin_code3
*  10: latitude
*  11: longitude
*  12: accuracy (1-6)

import delimited "/tmp/AR.txt", ///
    delimiter(tab) varnames(nonames) stringcols(_all) ///
    clear

di as text "  Filas importadas: " _N

* Rename
rename v1 country_code
rename v2 postal_code
rename v3 place_name
rename v4 provincia
rename v5 admin_code1
rename v6 admin_name2
rename v7 admin_code2
rename v8 admin_name3
rename v9 admin_code3
rename v10 latitude_str
rename v11 longitude_str
rename v12 accuracy_str

* Convert numerics
destring latitude_str, gen(latitude) force
destring longitude_str, gen(longitude) force
destring accuracy_str, gen(accuracy) force
drop latitude_str longitude_str accuracy_str

* Convert postal_code to numeric CP4 (some have suffix like "1234-XYZ" or "1234ABC")
gen str4 cp4_str = substr(postal_code, 1, 4)
destring cp4_str, gen(cp4) force
drop cp4_str

* Drop rows with invalid CP4
quietly count if cp4 == .
di as text "  Filas con CP4 inválido (drop): " r(N)
drop if cp4 == .

* Drop columns we don't need
drop country_code admin_code1 admin_code2 admin_code3 admin_name2 admin_name3

* Stats
di as text _n "  --- Stats finales ---"
di as text "  Filas: " _N

quietly count if latitude != .
di as text "  con lat: " r(N)
quietly levelsof cp4, local(cps)
di as text "  CP4 únicos: " r(r)
quietly levelsof place_name, local(plcs)
di as text "  place_name únicos: " r(r)
quietly levelsof provincia, local(prvs)
di as text "  provincias únicas: " r(r)

di as text _n "  Sample:"
list cp4 place_name provincia latitude longitude accuracy in 1/20, sep(0) noobs abbreviate(40)

di as text _n "  Distribución por provincia:"
tab provincia

* Save
order cp4 place_name provincia latitude longitude accuracy postal_code
sort cp4 place_name

label var cp4 "Código postal 4 dígitos"
label var place_name "Localidad"
label var provincia "Provincia"
label var latitude "Latitud"
label var longitude "Longitud"
label var accuracy "Accuracy (1=estimated, 4=geonameid, 6=centroid)"
label var postal_code "Código postal completo (puede tener sufijo)"

save "$data/geonames_ar.dta", replace
di as text _n "  Saved: $data/geonames_ar.dta"
