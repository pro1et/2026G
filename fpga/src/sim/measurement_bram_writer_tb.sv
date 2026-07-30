`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：measurement_bram_writer_tb
//
// 主要功能：
//   对measurement_bram_writer执行可重复的自检式功能仿真，检查通道选择、标量
//   锁存、波形拼接、写仲裁、字节地址、完成时序、错误锁存、同步复位和最小帧长。
//
// 使用方法：
//   从fpga/work目录运行fpga/scripts/run_measurement_bram_writer_sim.ps1。
//   全部检查通过时打印TEST PASSED，任一断言失败会立即调用$fatal。
//
// 连接说明：
//   本文件包含主测试实例及WAVE_SAMPLE_COUNT=2的边界实例，仅用于仿真。
//
// 时钟与复位：
//   产生100 MHz仿真时钟；所有激励在下降沿更新，输出在上升沿后检查。
//
// 输入格式：
//   标量使用32位无符号测试值；波形覆盖零、正数、负数及S16边界。
//
// 输出格式：
//   行为级存储器模型按BRAM字节地址记录每次写入并自动比较布局和数据。
//
// 握手时序：
//   start和标量valid均产生单周期脉冲；波形valid同时覆盖连续和间断输入。
//
// 参数说明：
//   主实例保存8点以缩短仿真，边界实例保存最小合法的2点。
//
// 错误行为：
//   测试非法空掩码、忙时重复启动和工作中复位；仿真总超时为50 us。
//
// 使用限制：
//   本测试验证RTL功能，不替代实现后的板级、CDC和完整系统时序检查。
// ============================================================================

module measurement_bram_writer_tb;

    localparam int unsigned WAVE_SAMPLE_COUNT = 8;
    localparam int unsigned BRAM_ADDR_WIDTH   = 17;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic                       rst;
    logic                       start;
    logic [2:0]                 channel_enable;
    logic [31:0]                vpp_data;
    logic                       vpp_valid;
    logic [31:0]                vrms_data;
    logic                       vrms_valid;
    logic signed [15:0]         wave_data;
    logic                       wave_valid;
    logic                       busy;
    logic                       frame_done;
    logic                       vpp_done;
    logic                       vrms_done;
    logic                       wave_done;
    logic                       error;
    logic                       bram_en;
    logic [3:0]                 bram_we;
    logic [BRAM_ADDR_WIDTH-1:0] bram_addr;
    logic [31:0]                bram_wrdata;

    logic                       edge_rst;
    logic                       edge_start;
    logic [2:0]                 edge_channel_enable;
    logic [31:0]                edge_vpp_data;
    logic                       edge_vpp_valid;
    logic [31:0]                edge_vrms_data;
    logic                       edge_vrms_valid;
    logic signed [15:0]         edge_wave_data;
    logic                       edge_wave_valid;
    logic                       edge_busy;
    logic                       edge_frame_done;
    logic                       edge_vpp_done;
    logic                       edge_vrms_done;
    logic                       edge_wave_done;
    logic                       edge_error;
    logic                       edge_bram_en;
    logic [3:0]                 edge_bram_we;
    logic [BRAM_ADDR_WIDTH-1:0] edge_bram_addr;
    logic [31:0]                edge_bram_wrdata;

    logic [31:0] memory [0:31];
    int unsigned write_count;
    int unsigned done_count;
    logic        previous_frame_done;
    int unsigned edge_write_count;
    logic [BRAM_ADDR_WIDTH-1:0] edge_last_addr;
    logic [31:0]                edge_last_data;

    measurement_bram_writer #(
        .WAVE_SAMPLE_COUNT(WAVE_SAMPLE_COUNT),
        .BRAM_ADDR_WIDTH  (BRAM_ADDR_WIDTH)
    ) dut (
        .clk            (clk),
        .rst            (rst),
        .start          (start),
        .channel_enable (channel_enable),
        .vpp_data       (vpp_data),
        .vpp_valid      (vpp_valid),
        .vrms_data      (vrms_data),
        .vrms_valid     (vrms_valid),
        .wave_data      (wave_data),
        .wave_valid     (wave_valid),
        .busy           (busy),
        .frame_done     (frame_done),
        .vpp_done       (vpp_done),
        .vrms_done      (vrms_done),
        .wave_done      (wave_done),
        .error          (error),
        .bram_en        (bram_en),
        .bram_we        (bram_we),
        .bram_addr      (bram_addr),
        .bram_wrdata    (bram_wrdata)
    );

    measurement_bram_writer #(
        .WAVE_SAMPLE_COUNT(2),
        .BRAM_ADDR_WIDTH  (BRAM_ADDR_WIDTH)
    ) dut_edge (
        .clk            (clk),
        .rst            (edge_rst),
        .start          (edge_start),
        .channel_enable (edge_channel_enable),
        .vpp_data       (edge_vpp_data),
        .vpp_valid      (edge_vpp_valid),
        .vrms_data      (edge_vrms_data),
        .vrms_valid     (edge_vrms_valid),
        .wave_data      (edge_wave_data),
        .wave_valid     (edge_wave_valid),
        .busy           (edge_busy),
        .frame_done     (edge_frame_done),
        .vpp_done       (edge_vpp_done),
        .vrms_done      (edge_vrms_done),
        .wave_done      (edge_wave_done),
        .error          (edge_error),
        .bram_en        (edge_bram_en),
        .bram_we        (edge_bram_we),
        .bram_addr      (edge_bram_addr),
        .bram_wrdata    (edge_bram_wrdata)
    );

    // 模拟32位BRAM写端，并持续检查地址对齐、写使能和完成脉宽。
    always @(posedge clk) begin
        if (rst) begin
            write_count         <= 0;
            done_count          <= 0;
            previous_frame_done <= 1'b0;
        end else begin
            if (bram_en) begin
                assert (bram_we == 4'b1111)
                    else $fatal(1, "BRAM写使能错误：time=%0t we=%b", $time, bram_we);
                assert (bram_addr[1:0] == 2'b00)
                    else $fatal(1, "BRAM地址未按4字节对齐：time=%0t addr=%h", $time, bram_addr);
                assert ((bram_addr >> 2) < 32)
                    else $fatal(1, "测试存储器地址越界：time=%0t addr=%h", $time, bram_addr);
                memory[bram_addr >> 2] <= bram_wrdata;
                write_count <= write_count + 1;
            end else begin
                assert (bram_we == 4'b0000)
                    else $fatal(1, "BRAM未使能时写使能非零：time=%0t", $time);
            end

            if (frame_done) begin
                assert (!bram_en)
                    else $fatal(1, "frame_done与最后一次BRAM写重叠：time=%0t", $time);
                assert (!previous_frame_done)
                    else $fatal(1, "frame_done持续超过一个周期：time=%0t", $time);
                done_count <= done_count + 1;
            end
            previous_frame_done <= frame_done;
        end
    end

    // 边界实例单独记录写入沿，避免在时序状态更新后读取已经撤销的组合写信号。
    always @(posedge clk) begin
        if (edge_rst) begin
            edge_write_count <= 0;
            edge_last_addr   <= '0;
            edge_last_data   <= 32'd0;
        end else if (edge_bram_en) begin
            assert (edge_bram_we == 4'b1111)
                else $fatal(1, "最小帧实例BRAM写使能错误");
            edge_write_count <= edge_write_count + 1;
            edge_last_addr   <= edge_bram_addr;
            edge_last_data   <= edge_bram_wrdata;
        end
    end

    task automatic reset_main;
        begin
            @(negedge clk);
            rst            = 1'b1;
            start          = 1'b0;
            channel_enable = 3'b000;
            vpp_data       = 32'd0;
            vpp_valid      = 1'b0;
            vrms_data      = 32'd0;
            vrms_valid     = 1'b0;
            wave_data      = 16'sd0;
            wave_valid     = 1'b0;
            repeat (2) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            @(posedge clk);
            #1;
            assert (!busy && !frame_done && !vpp_done && !vrms_done &&
                    !wave_done && !error && !bram_en && bram_we == 4'b0000)
                else $fatal(1, "主实例复位输出错误：time=%0t", $time);
        end
    endtask

    task automatic pulse_start(input logic [2:0] mask);
        begin
            @(negedge clk);
            channel_enable = mask;
            start          = 1'b1;
            @(posedge clk);
            #1;
            assert (busy)
                else $fatal(1, "合法start未进入忙状态：time=%0t mask=%b", $time, mask);
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task automatic pulse_vpp(input logic [31:0] value);
        begin
            @(negedge clk);
            vpp_data  = value;
            vpp_valid = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            vpp_valid = 1'b0;
        end
    endtask

    task automatic pulse_vrms(input logic [31:0] value);
        begin
            @(negedge clk);
            vrms_data  = value;
            vrms_valid = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            vrms_valid = 1'b0;
        end
    endtask

    // 本任务在样点采样沿后返回，连续调用时可形成无空拍的wave_valid数据流。
    task automatic send_wave(input logic signed [15:0] value);
        begin
            @(negedge clk);
            wave_data  = value;
            wave_valid = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    task automatic stop_wave;
        begin
            @(negedge clk);
            wave_valid = 1'b0;
        end
    endtask

    task automatic wait_for_done;
        int unsigned timeout_cycles;
        begin
            timeout_cycles = 0;
            while (!frame_done && timeout_cycles < 100) begin
                @(posedge clk);
                #1;
                timeout_cycles++;
            end
            assert (frame_done)
                else $fatal(1, "等待frame_done超时：time=%0t", $time);
            assert (!busy)
                else $fatal(1, "frame_done期间busy仍为高：time=%0t", $time);
            @(posedge clk);
            #1;
            assert (!frame_done)
                else $fatal(1, "frame_done未形成单周期脉冲：time=%0t", $time);
        end
    endtask

    initial begin
        rst            = 1'b1;
        start          = 1'b0;
        channel_enable = 3'b000;
        vpp_data       = 32'd0;
        vpp_valid      = 1'b0;
        vrms_data      = 32'd0;
        vrms_valid     = 1'b0;
        wave_data      = 16'sd0;
        wave_valid     = 1'b0;

        edge_rst            = 1'b1;
        edge_start          = 1'b0;
        edge_channel_enable = 3'b000;
        edge_vpp_data       = 32'd0;
        edge_vpp_valid      = 1'b0;
        edge_vrms_data      = 32'd0;
        edge_vrms_valid     = 1'b0;
        edge_wave_data      = 16'sd0;
        edge_wave_valid     = 1'b0;

        // 单独Vpp：只写地址0，不等待其他通道。
        reset_main();
        pulse_start(3'b001);
        pulse_vpp(32'h89AB_CDEF);
        wait_for_done();
        assert (write_count == 1 && done_count == 1 && memory[0] == 32'h89AB_CDEF)
            else $fatal(1, "Vpp单通道测试失败");
        assert (vpp_done && !vrms_done && !wave_done)
            else $fatal(1, "Vpp单通道完成标志错误");

        // 单独Vrms：只写字节地址0x0004。
        reset_main();
        pulse_start(3'b010);
        pulse_vrms(32'h0123_4567);
        wait_for_done();
        assert (write_count == 1 && done_count == 1 && memory[1] == 32'h0123_4567)
            else $fatal(1, "Vrms单通道测试失败");
        assert (!vpp_done && vrms_done && !wave_done)
            else $fatal(1, "Vrms单通道完成标志错误");

        // 单独波形：连续与间断valid混合，检查补码位模式和前低后高拼接。
        reset_main();
        pulse_start(3'b100);
        send_wave(16'sh8000);
        send_wave(-16'sd1);
        stop_wave();
        repeat (2) @(posedge clk);
        send_wave(16'sd0);
        send_wave(16'sd32767);
        send_wave(-16'sd2);
        send_wave(16'sd5);
        send_wave(16'sd6);
        send_wave(-16'sd7);
        stop_wave();
        wait_for_done();
        assert (write_count == 4 && done_count == 1)
            else $fatal(1, "波形写入数量错误：actual=%0d", write_count);
        assert (memory[2] == 32'hFFFF_8000)
            else $fatal(1, "波形字0错误：actual=%h", memory[2]);
        assert (memory[3] == 32'h7FFF_0000)
            else $fatal(1, "波形字1错误：actual=%h", memory[3]);
        assert (memory[4] == 32'h0005_FFFE)
            else $fatal(1, "波形字2错误：actual=%h", memory[4]);
        assert (memory[5] == 32'hFFF9_0006)
            else $fatal(1, "波形字3错误：actual=%h", memory[5]);

        // 三路联合：标量与波形同时到达，验证波形优先且两个标量最终均不丢失。
        reset_main();
        pulse_start(3'b111);
        @(negedge clk);
        wave_data  = 16'sd0;
        wave_valid = 1'b1;
        vpp_data   = 32'hAAAA_5555;
        vpp_valid  = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        wave_data  = 16'sd1;
        vpp_valid  = 1'b0;
        vrms_data  = 32'h1234_5678;
        vrms_valid = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        wave_valid = 1'b0;
        vrms_valid = 1'b0;
        repeat (2) @(posedge clk);
        send_wave(16'sd2);
        send_wave(16'sd3);
        stop_wave();
        repeat (1) @(posedge clk);
        send_wave(16'sd4);
        send_wave(16'sd5);
        send_wave(16'sd6);
        send_wave(16'sd7);
        stop_wave();
        wait_for_done();
        assert (write_count == 6 && done_count == 1)
            else $fatal(1, "三路联合写入数量错误：actual=%0d", write_count);
        assert (memory[0] == 32'hAAAA_5555 && memory[1] == 32'h1234_5678)
            else $fatal(1, "三路联合标量数据错误");
        assert (memory[2] == 32'h0001_0000 && memory[3] == 32'h0003_0002 &&
                memory[4] == 32'h0005_0004 && memory[5] == 32'h0007_0006)
            else $fatal(1, "三路联合波形数据错误");
        assert (vpp_done && vrms_done && wave_done)
            else $fatal(1, "三路联合完成标志错误");

        // 空掩码必须拒绝；错误只能由复位清除。
        reset_main();
        @(negedge clk);
        channel_enable = 3'b000;
        start = 1'b1;
        @(posedge clk);
        #1;
        assert (error && !busy && !frame_done && !bram_en)
            else $fatal(1, "空掩码启动未被拒绝");
        @(negedge clk);
        start = 1'b0;

        // 忙时重复启动置错但不终止当前帧，工作中复位立即恢复安全输出。
        reset_main();
        pulse_start(3'b100);
        send_wave(16'sd10);
        @(negedge clk);
        wave_valid = 1'b0;
        start      = 1'b1;
        @(posedge clk);
        #1;
        assert (error && busy)
            else $fatal(1, "忙时启动未锁存错误或错误终止帧");
        @(negedge clk);
        start = 1'b0;
        rst   = 1'b1;
        @(posedge clk);
        #1;
        assert (!error && !busy && !frame_done && !bram_en && bram_we == 4'b0000)
            else $fatal(1, "工作中同步复位输出不安全");
        @(negedge clk);
        rst = 1'b0;

        // 最小合法帧长：两个样点应在地址0x0008拼成一个字并正常结束。
        repeat (2) @(posedge clk);
        @(negedge clk);
        edge_rst = 1'b0;
        @(negedge clk);
        edge_channel_enable = 3'b100;
        edge_start = 1'b1;
        @(posedge clk);
        #1;
        assert (edge_busy)
            else $fatal(1, "最小帧实例启动失败");
        @(negedge clk);
        edge_start      = 1'b0;
        edge_wave_data  = -16'sd32768;
        edge_wave_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        edge_wave_data = 16'sd32767;
        @(posedge clk);
        #1;
        assert (edge_write_count == 1 && edge_last_addr == 17'h00008 &&
                edge_last_data == 32'h7FFF_8000)
            else $fatal(1, "最小帧波形拼接或地址错误");
        @(negedge clk);
        edge_wave_valid = 1'b0;
        wait (edge_frame_done);
        #1;
        assert (!edge_busy && edge_wave_done && !edge_error)
            else $fatal(1, "最小帧完成状态错误");
        @(posedge clk);
        #1;
        assert (!edge_frame_done)
            else $fatal(1, "最小帧frame_done脉宽错误");

        $display("TEST PASSED");
        $finish;
    end

    initial begin
        #50000;
        $fatal(1, "测试超时");
    end

endmodule

`default_nettype wire
