param(
    [ValidateSet('behavioral', 'timing')]
    [string]$Mode = 'behavioral'
)

$ErrorActionPreference = 'Stop'

$expectedWork = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\work'))
$currentWork = [System.IO.Path]::GetFullPath((Get-Location).Path)
if ($currentWork.TrimEnd('\') -ne $expectedWork.TrimEnd('\')) {
    throw "Run this script from fpga/work. Current directory: $currentWork"
}

$vivadoRoot = $env:VIVADO_HOME
if (-not $vivadoRoot) {
    $vivadoRoot = 'F:\vivado2022\Vivado\2022.2'
}
$vivado = Join-Path $vivadoRoot 'bin\vivado.bat'
if (-not (Test-Path -LiteralPath $vivado)) {
    throw "Vivado was not found under VIVADO_HOME: $vivadoRoot"
}

# The Codex shell does not inherit this standard Windows variable, while the
# Vivado batch loader requires it to select the 64-bit executable.
if (-not $env:PROCESSOR_ARCHITECTURE) {
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'
}

$tcl = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot 'run_measurement_timing_pipeline_sim.tcl'))
& $vivado -mode batch -source $tcl -tclargs $Mode
exit $LASTEXITCODE

