/*==============================================================================
  Investigar la columna ubicacion_dateas en Data_sorteos
==============================================================================*/

clear all
set more off

global root "/Users/francomartinvazquez/Dropbox (Personal)/Procrear Santanna"
global data "$root/DATA"

* --- Check ambos archivos ---
foreach f in "Data_sorteos.dta" "Data_sorteos_with_X.dta" {
    di as text _n _n "==========================================================="
    di as text "FILE: `f'"
    di as text "==========================================================="

    capture confirm file "$data/`f'"
    if _rc != 0 {
        di as text "  No existe"
        continue
    }

    use "$data/`f'", clear
    di as text "  Filas: " _N

    di as text _n "  Lista de variables del archivo:"
    describe, simple

    capture confirm variable ubicacion_dateas
    if _rc == 0 {
        di as text _n "  *** ubicacion_dateas EXISTE ***"
        describe ubicacion_dateas

        di as text _n "  Tipo: "
        capture confirm string variable ubicacion_dateas
        if _rc == 0 di as text "    STRING"
        else di as text "    NUMERIC"

        di as text _n "  Missing rate:"
        quietly count if ubicacion_dateas == ""
        local n_empty = r(N)
        quietly count if mi(ubicacion_dateas)
        local n_mi = r(N)
        di as text "    empty: " `n_empty' "  missing: " `n_mi'
        di as text "    de " _N " filas"

        di as text _n "  Valores únicos (max 30 más frecuentes):"
        capture noisily {
            preserve
            contract ubicacion_dateas, freq(N)
            gsort -N
            list ubicacion_dateas N in 1/30, sep(0) abbreviate(50) noobs
            di as text _n "    Total valores únicos: " _N
            restore
        }

        di as text _n "  Muestra de 20 valores (random):"
        preserve
        keep ubicacion_dateas
        sample 20, count
        list, sep(0) abbreviate(80) noobs
        restore
    }
    else {
        di as text _n "  ubicacion_dateas NO existe en este archivo"
    }
}
