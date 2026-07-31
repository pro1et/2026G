$ErrorActionPreference = 'Stop'

$expectedWork = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\work'))
$currentWork = [System.IO.Path]::GetFullPath((Get-Location).Path)
if ($currentWork.TrimEnd('\') -ne $expectedWork.TrimEnd('\')) {
    throw "Run this script from fpga/work. Current directory: $currentWork"
}

$vivadoRoot = $env:VIVADO_HOME
if (-not $vivadoRoot) {
    throw 'VIVADO_HOME is not set. Run in the vivado2022 Conda environment.'
}
$vivado = Join-Path $vivadoRoot 'bin\vivado.bat'
if (-not (Test-Path -LiteralPath $vivado)) {
    throw "Vivado was not found: $vivado"
}
if (-not $env:PROCESSOR_ARCHITECTURE) {
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'
}

$tcl = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot 'run_adc_fft_spectrol_loop_sim.tcl'))
& $vivado -mode batch -source $tcl
if ($LASTEXITCODE -ne 0) {
    throw "Vivado simulation failed with exit code $LASTEXITCODE"
}
