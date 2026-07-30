# =====================================================
# Board: Mizar Z7
# Function: HMI UART1 through PS EMIO
#
# Screen RX <- PS UART1 TX (EMIO): T11
# Screen TX -> PS UART1 RX (EMIO): T10
# =====================================================

set_property PACKAGE_PIN T11 [get_ports UART1_TX_0]
set_property PACKAGE_PIN T10 [get_ports UART1_RX_0]
set_property IOSTANDARD LVCMOS33 [get_ports {UART1_TX_0 UART1_RX_0}]
