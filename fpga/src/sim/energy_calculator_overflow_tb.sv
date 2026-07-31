`timescale 1ns/1ps
`default_nettype none

module energy_calculator_overflow_tb;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start = 1'b0;
    wire busy;
    wire done;
    wire mem_req;
    wire [10:0] mem_addr;
    logic mem_rvalid = 1'b0;
    logic [32:0] mem_rdata = 33'd0;
    wire result_bram_en;
    wire result_bram_we;
    wire [3:0] result_bram_addr;
    wire [31:0] result_bram_din;
    wire [2:0] harmonic_present_mask;
    wire [2:0] position_valid_mask;
    wire result_valid;
    wire energy_overflow;

    logic [31:0] result_memory [0:15];
    logic pending = 1'b0;
    logic [10:0] pending_addr = 11'd0;
    integer index;
    integer timeout;

    always #5 clk = ~clk;

    energy_calculator #(
        .POWER_WIDTH(33),
        .ENERGY_ACC_WIDTH(36)
    ) dut (
        .clk                    (clk),
        .rst                    (rst),
        .start                  (start),
        .busy                   (busy),
        .done                   (done),
        .base_valid             (1'b1),
        .base_index_500         (16'd40),
        .absolute_threshold     (32'd0),
        .ratio_num              (16'd0),
        .ratio_den              (16'd1),
        .mem_req                (mem_req),
        .mem_addr               (mem_addr),
        .mem_ready              (!pending),
        .mem_rvalid             (mem_rvalid),
        .mem_rdata              (mem_rdata),
        .result_bram_en         (result_bram_en),
        .result_bram_we         (result_bram_we),
        .result_bram_addr       (result_bram_addr),
        .result_bram_din        (result_bram_din),
        .harmonic_present_mask  (harmonic_present_mask),
        .position_valid_mask    (position_valid_mask),
        .result_valid           (result_valid),
        .energy_overflow        (energy_overflow)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            pending    <= 1'b0;
            pending_addr <= 11'd0;
            mem_rvalid <= 1'b0;
            mem_rdata  <= 33'd0;
        end else begin
            mem_rvalid <= pending;
            if (pending) begin
                // 七根U33最大值之和右移3位后超过U32，用于触发防御性饱和。
                mem_rdata <= 33'h1_FFFF_FFFF;
                pending   <= 1'b0;
            end
            if (mem_req && !pending) begin
                pending_addr <= mem_addr;
                pending      <= 1'b1;
            end
            if (result_bram_en && result_bram_we) begin
                result_memory[result_bram_addr] <= result_bram_din;
            end
        end
    end

    initial begin
        for (index = 0; index < 16; index = index + 1) begin
            result_memory[index] = 32'd0;
        end

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst   <= 1'b0;
        start <= 1'b1;
        @(negedge clk);
        start <= 1'b0;

        timeout = 0;
        while (!done && timeout < 2000) begin
            @(negedge clk);
            timeout = timeout + 1;
        end

        assert (done && result_valid && energy_overflow)
            else $fatal(1, "没有触发能量防御性饱和");
        assert (result_memory[2] == 32'hFFFF_FFFF &&
                result_memory[4] == 32'hFFFF_FFFF &&
                result_memory[6] == 32'hFFFF_FFFF)
            else $fatal(1, "溢出能量没有饱和为U32最大值");
        assert (result_memory[0][2] == 1'b1)
            else $fatal(1, "最终状态字没有记录energy_overflow");

        $display("TEST PASSED: energy_calculator_overflow");
        $finish;
    end

    // 实现问题记录：
    // 生产配置U32功率不会触发饱和，因此使用参数化U33输入验证防御性分支。

endmodule

`default_nettype wire
