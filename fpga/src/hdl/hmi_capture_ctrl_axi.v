`timescale 1ns / 1ps
`default_nettype none

// ============================================================================
// 模块名称：hmi_capture_ctrl_axi
//
// 主要功能：
//   为HMI采集链路提供最小AXI4-Lite控制/状态寄存器。PS写CONTROL.START启动一次
//   采集，读取STATUS获得READY、BUSY、DONE、ERROR和LOCKED。模块内部使用af_cdc
//   将START从PS FCLK域传到采集链路100 MHz域，并将单周期DONE事件可靠传回AXI
//   域后锁存，避免PS轮询遗漏。
//
// 寄存器映射：
//   0x00 CONTROL，写：
//        bit 0：START，写1请求启动；仅READY=1且BUSY=0时接受
//        bit 1：CLEAR_DONE，写1清除DONE锁存
//   0x04 STATUS，读：
//        bit 0：BUSY，采集或处理正在进行
//        bit 1：DONE，一帧BRAM写完后锁存；新START或CLEAR_DONE清除
//        bit 2：ERROR，采集链路或CDC协议错误
//        bit 3：READY，可以接受新的START
//        bit 4：LOCKED，板卡Clock Wizard已经锁定
//        bit 5：START_CDC_BUSY，启动事件正在跨时钟传输
//        bit 31:6：0
//
// 使用方法：
//   1. S_AXI连接Zynq M_AXI_GP0经SmartConnect得到的AXI-Lite主口。
//   2. s_axi_aclk连接PS FCLK_CLK0，建议配置为100 MHz。
//   3. measure_clk连接adc_fifo_bram_chain.clk_100m_out。
//   4. measure_rst连接~adc_fifo_bram_chain.rst_100m_n_out。
//   5. start_pulse连接adc_fifo_bram_chain.capture_start。
//   6. measure_*连接adc_fifo_bram_chain对应状态输出。
//
// 时钟与复位：
//   S_AXI属于s_axi_aclk域，低有效异步复位s_axi_aresetn。
//   start_pulse属于measure_clk域，measure_rst为该域高有效复位。
//   两个100 MHz时钟可能异步，禁止在外部绕过本模块直接跨域连接控制事件。
//
// AXI行为：
//   AW和W通道可独立、任意先后到达；模块最多接受一个未完成写事务。
//   读写响应均为OKAY。未定义地址读取返回0，写入被忽略但仍返回OKAY。
//
// 错误行为：
//   忙时或未就绪时写START会被忽略，不置ERROR。af_cdc检测到重复事件时，STATUS
//   的ERROR置高并保持到AXI复位；采集链路ERROR直接反映到STATUS。
//
// 使用限制：
//   measure_done必须是measure_clk域单周期事件，其他measure_*状态必须在
//   measure_clk域稳定产生。软件应以DONE为BRAM可读判据。
// ============================================================================

module hmi_capture_ctrl_axi (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_aclk, ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET s_axi_aresetn, FREQ_HZ 100000000" *)
    input  wire         s_axi_aclk,          // AXI时钟，连接PS FCLK_CLK0 100 MHz

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_aresetn, POLARITY ACTIVE_LOW" *)
    input  wire         s_axi_aresetn,       // AXI低有效复位

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 6, FREQ_HZ 100000000, ID_WIDTH 0, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_CACHE 0, HAS_PROT 1, HAS_QOS 0, HAS_REGION 0, SUPPORTS_NARROW_BURST 0, MAX_BURST_LENGTH 1, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1" *)
    input  wire [5:0]   s_axi_awaddr,        // AXI写地址
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
    input  wire [2:0]   s_axi_awprot,        // AXI写保护属性，本模块不使用
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  wire         s_axi_awvalid,       // AXI写地址有效
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output wire         s_axi_awready,       // AXI可接收写地址

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  wire [31:0]  s_axi_wdata,         // AXI写数据
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  wire [3:0]   s_axi_wstrb,         // AXI写字节使能
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  wire         s_axi_wvalid,        // AXI写数据有效
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output wire         s_axi_wready,        // AXI可接收写数据

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output wire [1:0]   s_axi_bresp,         // AXI写响应，固定OKAY
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output reg          s_axi_bvalid,        // AXI写响应有效
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  wire         s_axi_bready,        // AXI主机接收写响应

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  wire [5:0]   s_axi_araddr,        // AXI读地址
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
    input  wire [2:0]   s_axi_arprot,        // AXI读保护属性，本模块不使用
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  wire         s_axi_arvalid,       // AXI读地址有效
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output wire         s_axi_arready,       // AXI可接收读地址

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output reg  [31:0]  s_axi_rdata,         // AXI读数据
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output wire [1:0]   s_axi_rresp,         // AXI读响应，固定OKAY
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output reg          s_axi_rvalid,        // AXI读数据有效
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  wire         s_axi_rready,        // AXI主机接收读数据

    input  wire         measure_clk,         // 采集链路100 MHz时钟
    input  wire         measure_rst,         // 采集链路高有效复位
    output wire         start_pulse,         // measure_clk域单周期启动事件
    input  wire         measure_ready,       // 采集链路可启动状态
    input  wire         measure_busy,        // 采集链路忙状态
    input  wire         measure_done,        // BRAM写完的measure_clk域单周期事件
    input  wire         measure_error,       // 采集链路粘滞错误
    input  wire         measure_locked       // 板卡Clock Wizard锁定状态
);

    localparam [3:0] ADDR_CONTROL = 4'h0;
    localparam [3:0] ADDR_STATUS  = 4'h1;

    reg        aw_hold;
    reg [5:0]  awaddr_hold;
    reg        w_hold;
    reg [31:0] wdata_hold;
    reg [3:0]  wstrb_hold;

    reg start_event_axi;
    reg done_sticky;

    wire start_cdc_busy;
    wire start_cdc_error;
    wire done_event_axi;
    wire done_cdc_busy;
    wire done_cdc_error;

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] ready_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] busy_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] error_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] locked_sync;

    wire status_error;
    wire [31:0] status_word;
    wire unused_prot;
    wire unused_done_cdc_busy;

    assign status_error = error_sync[1] || start_cdc_error;
    assign status_word = {
        26'd0,
        start_cdc_busy,
        locked_sync[1],
        ready_sync[1],
        status_error,
        done_sticky,
        busy_sync[1]
    };

    assign s_axi_awready = !aw_hold && !s_axi_bvalid;
    assign s_axi_wready  = !w_hold  && !s_axi_bvalid;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_rresp   = 2'b00;
    assign unused_prot   = ^s_axi_awprot ^ ^s_axi_arprot;
    assign unused_done_cdc_busy = done_cdc_busy;

    // 静态状态采用双触发器同步到AXI域；DONE脉冲单独使用事件CDC。
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            ready_sync  <= 2'b00;
            busy_sync   <= 2'b00;
            error_sync  <= 2'b00;
            locked_sync <= 2'b00;
        end else begin
            ready_sync  <= {ready_sync[0], measure_ready};
            busy_sync   <= {busy_sync[0], measure_busy};
            error_sync  <= {error_sync[0], measure_error || done_cdc_error};
            locked_sync <= {locked_sync[0], measure_locked};
        end
    end

    // AW和W独立缓存，满足AXI4-Lite两通道可任意先后到达的要求。
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            aw_hold         <= 1'b0;
            awaddr_hold     <= 6'd0;
            w_hold          <= 1'b0;
            wdata_hold      <= 32'd0;
            wstrb_hold      <= 4'd0;
            s_axi_bvalid    <= 1'b0;
            start_event_axi <= 1'b0;
            done_sticky     <= 1'b0;
        end else begin
            start_event_axi <= 1'b0;

            if (done_event_axi) begin
                done_sticky <= 1'b1;
            end

            if (s_axi_awvalid && s_axi_awready) begin
                aw_hold     <= 1'b1;
                awaddr_hold <= s_axi_awaddr;
            end

            if (s_axi_wvalid && s_axi_wready) begin
                w_hold     <= 1'b1;
                wdata_hold <= s_axi_wdata;
                wstrb_hold <= s_axi_wstrb;
            end

            if (aw_hold && w_hold && !s_axi_bvalid) begin
                if ((awaddr_hold[5:2] == ADDR_CONTROL) &&
                    wstrb_hold[0]) begin
                    if (wdata_hold[1]) begin
                        done_sticky <= 1'b0;
                    end

                    if (wdata_hold[0] && ready_sync[1] &&
                        !busy_sync[1] && !start_cdc_busy) begin
                        start_event_axi <= 1'b1;
                        done_sticky     <= 1'b0;
                    end
                end

                aw_hold      <= 1'b0;
                w_hold       <= 1'b0;
                s_axi_bvalid <= 1'b1;
            end

            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_rdata  <= 32'd0;
            s_axi_rvalid <= 1'b0;
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                case (s_axi_araddr[5:2])
                    ADDR_STATUS: s_axi_rdata <= status_word;
                    default:     s_axi_rdata <= 32'd0;
                endcase
                s_axi_rvalid <= 1'b1;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    // PS FCLK域START事件跨到采集链路100 MHz域。
    af_cdc u_start_cdc (
        .src_clk            (s_axi_aclk),
        .src_rst            (~s_axi_aresetn),
        .src_event          (start_event_axi),
        .src_busy           (start_cdc_busy),
        .src_protocol_error (start_cdc_error),
        .dst_clk            (measure_clk),
        .dst_rst            (measure_rst),
        .dst_event          (start_pulse)
    );

    // 采集链路单周期DONE事件跨回AXI域，再由done_sticky保持供PS轮询。
    af_cdc u_done_cdc (
        .src_clk            (measure_clk),
        .src_rst            (measure_rst),
        .src_event          (measure_done),
        .src_busy           (done_cdc_busy),
        .src_protocol_error (done_cdc_error),
        .dst_clk            (s_axi_aclk),
        .dst_rst            (~s_axi_aresetn),
        .dst_event          (done_event_axi)
    );

endmodule

`default_nettype wire
