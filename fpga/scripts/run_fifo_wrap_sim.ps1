# fifo_wrap 端到端 XSim 自检脚本。
# 必须从 fpga/work 目录运行，使 Vivado 生成物只保留在本地工作区。

$ErrorActionPreference = 'Stop'

$expectedWork = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\work'))
$currentWork = [System.IO.Path]::GetFullPath((Get-Location).Path)

if ($currentWork.TrimEnd('\') -ne $expectedWork.TrimEnd('\')) {
    throw "请从 fpga/work 目录运行此脚本，当前目录为：$currentWork"
}

$writeCtrl = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\hdl\adc_write_controller.sv'))
$cdc = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\hdl\af_cdc.sv'))
$readCtrl = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\hdl\fifo_ctrl.sv'))
$wrapper = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\hdl\fifo_wrap.v'))
$tb = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\sim\fifo_wrap_tb.sv'))

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

# 一次性建立完整工作库，避免分次 xvlog 覆盖前一批已分析的设计单元。
# fifo_wrap 文件及其语法仍保持 Verilog 形式；--sv 用于兼容同批次的其他模块。
& $xvlog --sv $wrapper $writeCtrl $cdc $readCtrl $tb
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& $xelab fifo_wrap_tb -s fifo_wrap_tb_sim
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& $xsim fifo_wrap_tb_sim -runall
exit $LASTEXITCODE
