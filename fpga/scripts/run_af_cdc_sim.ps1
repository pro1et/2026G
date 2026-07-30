# af_cdc 跨时钟事件握手模块 XSim 自检脚本。
# 必须从 fpga/work 目录运行，使 Vivado 生成物只保留在本地工作区。

$ErrorActionPreference = 'Stop'

$expectedWork = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\work'))
$currentWork = [System.IO.Path]::GetFullPath((Get-Location).Path)

if ($currentWork.TrimEnd('\') -ne $expectedWork.TrimEnd('\')) {
    throw "请从 fpga/work 目录运行此脚本，当前目录为：$currentWork"
}

$rtl = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\hdl\af_cdc.sv'))
$tb = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\sim\af_cdc_tb.sv'))

if ($env:VIVADO_HOME) {
    $vivadoBin = Join-Path $env:VIVADO_HOME 'bin'
    $xvlog = Join-Path $vivadoBin 'xvlog.bat'
    $xelab = Join-Path $vivadoBin 'xelab.bat'
    $xsim = Join-Path $vivadoBin 'xsim.bat'
} else {
    $xvlog = 'xvlog'
    $xelab = 'xelab'
    $xsim = 'xsim'
}

& $xvlog --sv $rtl $tb
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& $xelab af_cdc_tb -s af_cdc_tb_sim
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& $xsim af_cdc_tb_sim -runall
exit $LASTEXITCODE
