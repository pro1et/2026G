`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：fifo_ctrl_tb
//
// 主要功能：
//   使用 FWFT FIFO 行为模型对 fifo_ctrl 执行自检，覆盖正常帧、首尾反压、间断
//   ready、下一帧提前到达、重复帧事件、FIFO 数据不足、读端复位忙和中途复位。
//
// 使用方法：
//   从 fpga/work 运行 fpga/scripts/run_fifo_ctrl_sim.ps1。测试通过时打印
//   TEST PASSED；任一检查失败会调用 $fatal。
//
// 连接说明：
//   本文件仅用于仿真，不加入综合源文件。
//
// 时钟与复位：
//   使用 100 MHz 仿真时钟和高电平有效同步复位。
//
// 输入格式：
//   FIFO 模型提供 16 位补码位模式，并验证负数位模式原样传到 signed fir_data。
//
// 输出格式：
//   自动检查读使能、样点索引、首尾标志、完成脉冲和粘滞错误状态。
//
// 握手时序：
//   所有外部激励在下降沿改变，避免与被测模块上升沿采样竞争。
//
// 参数说明：
//   被测实例使用 8 点帧加速功能仿真。
//
// 错误行为：
//   测试超时或任何断言失败均以失败状态结束。
//
// 使用限制：
//   行为模型验证控制逻辑，不替代 FIFO IP 联合仿真和顶层 CDC/时序检查。
// ============================================================================

module fifo_ctrl_tb;

    localparam int unsigned DATA_WIDTH = 16;
    localparam int unsigned FRAME_SIZE = 8;
    localparam int unsigned FIFO_CAPACITY = 64;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic                     rst;
    logic                     frame_ready_event;
    logic [DATA_WIDTH-1:0]    fifo_dout;
    logic                     fifo_empty;
    logic                     fifo_rd_rst_busy;
    logic                     fifo_rd_en;
    logic signed [DATA_WIDTH-1:0] fir_data;
    logic                     fir_valid;
    logic                     fir_ready;
    logic                     fir_first;
    logic                     fir_last;
    logic                     fir_frame_done;
    logic                     transfer_busy;
    logic                     fifo_frame_done;
    logic                     underflow_error;
    logic                     protocol_error;
    logic [$clog2(FRAME_SIZE)-1:0] transfer_index;

    logic                         edge_rst;
    logic                         edge_frame_ready_event;
    logic                         edge_fifo_rd_en;
    logic signed [DATA_WIDTH-1:0] edge_fir_data;
    logic                         edge_fir_valid;
    logic                         edge_fir_ready;
    logic                         edge_fir_first;
    logic                         edge_fir_last;
    logic                         edge_transfer_busy;
    logic                         edge_fifo_frame_done;
    logic                         edge_underflow_error;
    logic                         edge_protocol_error;
    logic                         edge_transfer_index;

    logic [DATA_WIDTH-1:0] fifo_mem [0:FIFO_CAPACITY-1];
    int unsigned fifo_rd_ptr;
    int unsigned fifo_wr_ptr;
    int unsigned fifo_count;
    int unsigned frame_transfer_count;
    int unsigned total_read_count;

    fifo_ctrl #(
        .DATA_WIDTH(DATA_WIDTH),
        .FRAME_SIZE(FRAME_SIZE)
    ) dut (
        .clk              (clk),
        .rst              (rst),
        .frame_ready_event(frame_ready_event),
        .fifo_dout        (fifo_dout),
        .fifo_empty       (fifo_empty),
        .fifo_rd_rst_busy (fifo_rd_rst_busy),
        .fifo_rd_en       (fifo_rd_en),
        .fir_data         (fir_data),
        .fir_valid        (fir_valid),
        .fir_ready        (fir_ready),
        .fir_first        (fir_first),
        .fir_last         (fir_last),
        .fir_frame_done   (fir_frame_done),
        .transfer_busy    (transfer_busy),
        .fifo_frame_done  (fifo_frame_done),
        .underflow_error  (underflow_error),
        .protocol_error   (protocol_error),
        .transfer_index   (transfer_index)
    );

    // 最小合法帧长实例用于验证零位宽保护和首尾同拍语义。
    fifo_ctrl #(
        .DATA_WIDTH(DATA_WIDTH),
        .FRAME_SIZE(1)
    ) dut_edge (
        .clk              (clk),
        .rst              (edge_rst),
        .frame_ready_event(edge_frame_ready_event),
        .fifo_dout        (16'h8000),
        .fifo_empty       (1'b0),
        .fifo_rd_rst_busy (1'b0),
        .fifo_rd_en       (edge_fifo_rd_en),
        .fir_data         (edge_fir_data),
        .fir_valid        (edge_fir_valid),
        .fir_ready        (edge_fir_ready),
        .fir_first        (edge_fir_first),
        .fir_last         (edge_fir_last),
        .fir_frame_done   (1'b0),
        .transfer_busy    (edge_transfer_busy),
        .fifo_frame_done  (edge_fifo_frame_done),
        .underflow_error  (edge_underflow_error),
        .protocol_error   (edge_protocol_error),
        .transfer_index   (edge_transfer_index)
    );

    always_comb begin
        fifo_empty = (fifo_count == 0);
        if (fifo_count == 0) begin
            fifo_dout = '0;
        end else begin
            fifo_dout = fifo_mem[fifo_rd_ptr];
        end
    end

    // FWFT 模型只在 rd_en 上升沿弹出当前 dout。
    always @(posedge clk) begin
        if (rst) begin
            fifo_rd_ptr <= 0;
            fifo_wr_ptr <= 0;
            fifo_count  <= 0;
        end else if (fifo_rd_en) begin
            assert (fifo_count > 0)
                else $fatal(1, "FIFO 空时出现读使能，time=%0t", $time);
            if (fifo_rd_ptr == FIFO_CAPACITY - 1) begin
                fifo_rd_ptr <= 0;
            end else begin
                fifo_rd_ptr <= fifo_rd_ptr + 1;
            end
            fifo_count <= fifo_count - 1;
        end
    end

    // 逐次握手检查索引、首尾标志、有符号位模式和读使能对齐。
    always_ff @(posedge clk) begin
        if (rst) begin
            frame_transfer_count <= 0;
            total_read_count      <= 0;
        end else begin
            assert (fifo_rd_en == (fir_valid && fir_ready))
                else $fatal(1, "FIFO 读使能与 FIR 握手不一致，time=%0t", $time);

            if (fir_valid && fir_ready) begin
                assert (transfer_index == frame_transfer_count)
                    else $fatal(1,
                        "传输索引错误：time=%0t actual=%0d expected=%0d",
                        $time, transfer_index, frame_transfer_count);
                assert (fir_first == (frame_transfer_count == 0))
                    else $fatal(1, "fir_first 错误，time=%0t", $time);
                assert (fir_last == (frame_transfer_count == FRAME_SIZE - 1))
                    else $fatal(1, "fir_last 错误，time=%0t", $time);
                assert (fir_data === $signed(fifo_dout))
                    else $fatal(1, "有符号数据映射错误，time=%0t", $time);

                total_read_count <= total_read_count + 1;
                if (frame_transfer_count == FRAME_SIZE - 1) begin
                    frame_transfer_count <= 0;
                end else begin
                    frame_transfer_count <= frame_transfer_count + 1;
                end
            end
        end
    end

    task automatic reset_all;
        begin
            @(negedge clk);
            rst                  = 1'b1;
            frame_ready_event    = 1'b0;
            fifo_rd_rst_busy     = 1'b0;
            fir_ready            = 1'b0;
            fir_frame_done       = 1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            @(posedge clk);
            #1;
            assert (!fifo_rd_en && !fir_valid && !transfer_busy
                    && !fifo_frame_done && !underflow_error && !protocol_error
                    && transfer_index == 0)
                else $fatal(1, "复位后输出状态错误，time=%0t", $time);
        end
    endtask

    task automatic load_samples(
        input logic [DATA_WIDTH-1:0] base_value,
        input int unsigned sample_count
    );
        int unsigned i;
        int unsigned write_index;
        begin
            @(negedge clk);
            assert (fifo_count + sample_count <= FIFO_CAPACITY)
                else $fatal(1, "测试 FIFO 容量不足");
            write_index = fifo_wr_ptr;
            for (i = 0; i < sample_count; i = i + 1) begin
                fifo_mem[write_index] = base_value + DATA_WIDTH'(i);
                if (write_index == FIFO_CAPACITY - 1) begin
                    write_index = 0;
                end else begin
                    write_index = write_index + 1;
                end
            end
            fifo_wr_ptr = write_index;
            fifo_count  = fifo_count + sample_count;
        end
    endtask

    task automatic pulse_frame_ready;
        begin
            @(negedge clk);
            frame_ready_event = 1'b1;
            @(posedge clk);
            @(negedge clk);
            frame_ready_event = 1'b0;
        end
    endtask

    task automatic pulse_fir_done;
        begin
            @(negedge clk);
            fir_frame_done = 1'b1;
            @(posedge clk);
            @(negedge clk);
            fir_frame_done = 1'b0;
        end
    endtask

    task automatic wait_for_valid;
        int unsigned cycles;
        begin
            cycles = 0;
            while (!fir_valid && cycles < 30) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end
            assert (fir_valid)
                else $fatal(1, "等待 fir_valid 超时，time=%0t", $time);
        end
    endtask

    task automatic drain_with_pattern;
        int unsigned cycles;
        begin
            cycles = 0;
            while (!fifo_frame_done && cycles < 100) begin
                @(negedge clk);
                fir_ready = ((cycles % 4) != 1);
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end
            assert (fifo_frame_done)
                else $fatal(1, "间断 ready 传输未完成，time=%0t", $time);
            @(negedge clk);
            fir_ready = 1'b0;
        end
    endtask

    initial begin
        rst               = 1'b1;
        frame_ready_event = 1'b0;
        fifo_rd_rst_busy  = 1'b0;
        fir_ready         = 1'b0;
        fir_frame_done    = 1'b0;
        fifo_rd_ptr       = 0;
        fifo_wr_ptr       = 0;
        fifo_count        = 0;
        edge_rst               = 1'b1;
        edge_frame_ready_event = 1'b0;
        edge_fir_ready         = 1'b0;

        // 第一帧：验证负数位模式、帧首反压和帧尾反压。
        reset_all();
        load_samples(16'h8000, FRAME_SIZE);
        pulse_frame_ready();
        wait_for_valid();

        repeat (3) begin
            @(posedge clk);
            #1;
            assert (fir_valid && fir_first && !fir_last
                    && !fifo_rd_en && transfer_index == 0
                    && fir_data === 16'sh8000)
                else $fatal(1, "帧首反压保持失败，time=%0t", $time);
        end

        @(negedge clk);
        fir_ready = 1'b1;
        while (!(fir_valid && fir_last)) begin
            @(posedge clk);
            #1;
        end
        @(negedge clk);
        fir_ready = 1'b0;

        repeat (3) begin
            @(posedge clk);
            #1;
            assert (fir_valid && fir_last && !fifo_rd_en
                    && transfer_index == FRAME_SIZE - 1
                    && !fifo_frame_done)
                else $fatal(1, "帧尾反压保持失败，time=%0t", $time);
        end

        @(negedge clk);
        fir_ready = 1'b1;
        @(posedge clk);
        #1;
        assert (fifo_frame_done && !transfer_busy && fifo_count == 0)
            else $fatal(1, "第一帧完成时序错误，time=%0t", $time);
        @(negedge clk);
        fir_ready = 1'b0;

        // FIR 尚未完成时允许 ADC 写好下一帧并锁存事件，但不得立即输入 FIR。
        load_samples(16'h0100, FRAME_SIZE);
        pulse_frame_ready();
        repeat (4) begin
            @(posedge clk);
            #1;
            assert (!fir_valid && !fifo_rd_en && fifo_count == FRAME_SIZE)
                else $fatal(1, "等待 FIR 完成时提前读取下一帧，time=%0t", $time);
        end
        pulse_fir_done();
        drain_with_pattern();
        assert (fifo_count == 0 && total_read_count == 2 * FRAME_SIZE)
            else $fatal(1, "第二帧数据数量错误，time=%0t", $time);
        pulse_fir_done();

        // 帧事件到达时读端复位忙：事件必须保留，解除后才能开始传输。
        reset_all();
        load_samples(16'h0200, FRAME_SIZE);
        @(negedge clk);
        fifo_rd_rst_busy = 1'b1;
        pulse_frame_ready();
        repeat (4) begin
            @(posedge clk);
            #1;
            assert (!fir_valid && !fifo_rd_en && !underflow_error)
                else $fatal(1, "读端复位忙期间错误启动，time=%0t", $time);
        end
        @(negedge clk);
        fifo_rd_rst_busy = 1'b0;
        drain_with_pattern();
        pulse_fir_done();

        // 已有待处理帧时再次收到事件，必须进入协议错误状态。
        reset_all();
        load_samples(16'h0300, FRAME_SIZE);
        @(negedge clk);
        fifo_rd_rst_busy = 1'b1;
        pulse_frame_ready();
        pulse_frame_ready();
        @(posedge clk);
        #1;
        assert (protocol_error && !fir_valid && !fifo_rd_en)
            else $fatal(1, "重复帧事件未触发协议错误，time=%0t", $time);

        // FIFO 数据少于声明帧长，传输完已有数据后必须报下溢且不得报正常完成。
        reset_all();
        load_samples(16'h0400, 3);
        pulse_frame_ready();
        @(negedge clk);
        fir_ready = 1'b1;
        begin : wait_underflow
            int unsigned cycles;
            cycles = 0;
            while (!underflow_error && cycles < 30) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end
        end
        assert (underflow_error && !fifo_frame_done && !fir_valid && fifo_count == 0)
            else $fatal(1, "FIFO 数据不足处理错误，time=%0t", $time);

        // 传输过程中复位必须立即回到确定状态并清除粘滞错误。
        reset_all();
        load_samples(16'h0500, FRAME_SIZE);
        pulse_frame_ready();
        wait_for_valid();
        @(negedge clk);
        rst = 1'b1;
        @(posedge clk);
        #1;
        assert (!fir_valid && !fifo_rd_en && !transfer_busy
                && !fifo_frame_done && !underflow_error && !protocol_error
                && transfer_index == 0)
            else $fatal(1, "传输中复位行为错误，time=%0t", $time);

        // FRAME_SIZE=1 时同一个样点必须同时带 fir_first 和 fir_last。
        repeat (2) @(posedge clk);
        @(negedge clk);
        edge_rst = 1'b0;
        @(negedge clk);
        edge_frame_ready_event = 1'b1;
        @(posedge clk);
        @(negedge clk);
        edge_frame_ready_event = 1'b0;
        begin : wait_edge_valid
            int unsigned cycles;
            cycles = 0;
            while (!edge_fir_valid && cycles < 20) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end
        end
        assert (edge_fir_valid && edge_fir_first && edge_fir_last
                && edge_transfer_index == 0 && edge_fir_data === 16'sh8000)
            else $fatal(1, "单点帧首尾语义错误，time=%0t", $time);
        @(negedge clk);
        edge_fir_ready = 1'b1;
        #1;
        assert (edge_fifo_rd_en)
            else $fatal(1, "单点帧未产生 FIFO 读使能，time=%0t", $time);
        @(posedge clk);
        #1;
        assert (edge_fifo_frame_done && !edge_transfer_busy && !edge_underflow_error
                && !edge_protocol_error)
            else $fatal(1, "单点帧完成时序错误，time=%0t", $time);

        $display("TEST PASSED");
        $finish;
    end

    initial begin
        #30000;
        $fatal(1, "测试超时");
    end

endmodule

`default_nettype wire
