$ErrorActionPreference = 'Stop'

$expectedWork = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\work'))
$currentWork = [System.IO.Path]::GetFullPath((Get-Location).Path)
if ($currentWork.TrimEnd('\') -ne $expectedWork.TrimEnd('\')) {
    throw "Run this script from fpga/work. Current directory: $currentWork"
}

$vivadoRoot = if ($env:VIVADO_HOME) {
    $env:VIVADO_HOME
} else {
    'F:\vivado2022\Vivado\2022.2'
}
$vivadoBin = Join-Path $vivadoRoot 'bin\unwrapped\win64.o'
$xvlog = Join-Path $vivadoBin 'xvlog.exe'
$xelab = Join-Path $vivadoBin 'xelab.exe'
$xsim = Join-Path $vivadoBin 'xsim.exe'

$env:RDI_APPROOT = $vivadoRoot
$env:RDI_DATADIR = Join-Path $vivadoRoot 'data'
$env:XILINX_VIVADO = $vivadoRoot
$env:HDI_APPROOT = $vivadoRoot
$env:RDI_PLATFORM = 'win64'
$env:RDI_OPT_EXT = '.o'
$env:RDI_BINDIR = Join-Path $vivadoRoot 'bin'
$env:TCL_LIBRARY = Join-Path $vivadoRoot 'tps\tcl\tcl8.5'
$env:ISL_IOSTREAMS_RSA = Join-Path $vivadoRoot 'tps\isl'
$env:RDI_BUILD = 'yes'
$env:RT_LIBPATH = Join-Path $vivadoRoot 'scripts\rt\data'
$env:RT_TCL_PATH = Join-Path $vivadoRoot 'scripts\rt\base_tcl\tcl'
$env:SYNTH_COMMON = $env:RT_LIBPATH
$vivadoLib = Join-Path $vivadoRoot 'lib\win64.o'
$env:RDI_LIBDIR = $vivadoLib
$vivadoMingw = Join-Path $vivadoRoot 'tps\mingw\6.2.0\win64.o\nt\bin'
$vivadoJava = Join-Path $vivadoRoot 'tps\win64\jre11.0.11_9\bin'
$env:RDI_JAVAROOT = Split-Path $vivadoJava
$env:RDI_USE_JDK11 = '1'
$env:RDI_JAVAFXROOT = Join-Path $vivadoRoot 'tps\win64\javafx-sdk-11.0.2'
$env:RDI_JAVACEFROOT = Join-Path $vivadoRoot 'tps\win64\java-cef-95.0.4630.69'
$vivadoCrt = Join-Path $vivadoBin 'Microsoft.VC141.CRT'
$vivadoTpsWin = Join-Path $vivadoRoot 'tps\win64'
$vivadoPython = Join-Path $vivadoRoot 'tps\win64\python-3.8.3'
$env:PYTHONHOME = $vivadoPython
$env:PYTHONPATH = "$vivadoPython;$vivadoPython\bin;$vivadoPython\lib;$vivadoPython\lib\site-packages"
$vivadoCef = Join-Path $env:RDI_JAVACEFROOT 'bin\lib\win64'
$vivadoFxLib = Join-Path $env:RDI_JAVAFXROOT 'lib'
$vivadoFxBin = Join-Path $env:RDI_JAVAFXROOT 'bin'
$env:PATH = "$env:RDI_BINDIR;$vivadoCef;$vivadoFxLib;$vivadoFxBin;$vivadoLib;$vivadoJava\server;$vivadoJava;$vivadoTpsWin;$vivadoCrt;$vivadoBin;$env:PATH;$vivadoMingw;$vivadoPython;$vivadoPython\bin;$vivadoPython\lib;$vivadoPython\lib\site-packages"

$rtl = [System.IO.Path]::GetFullPath(
    (Join-Path $currentWork '..\src\hdl\energy_calculator.sv'))
$testbenches = @(
    @{
        Source = '..\src\sim\energy_calculator_tb.sv'
        Top = 'energy_calculator_tb'
    },
    @{
        Source = '..\src\sim\energy_calculator_overflow_tb.sv'
        Top = 'energy_calculator_overflow_tb'
    }
)

foreach ($testbench in $testbenches) {
    $tbSource = [System.IO.Path]::GetFullPath(
        (Join-Path $currentWork $testbench.Source))
    $snapshot = "$($testbench.Top)_sim"

    & $xvlog --sv $rtl $tbSource
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    & $xelab $testbench.Top -s $snapshot
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    & $xsim $snapshot -runall
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

exit 0
