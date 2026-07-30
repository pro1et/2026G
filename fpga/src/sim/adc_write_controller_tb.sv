`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：adc_write_controller_tb
//
// 主要功能：
//   对 adc_write_controller 执行可重复的自检式仿真，覆盖正常、间断有效、
//   最后一拍、重复启动、消费确认、FIFO 异常、清错、复位和单点帧边界。
//
// 使用方法：
//   从 fpga/work 运行 fpga/scripts/run_adc_write_controller_sim.ps1。
//   测试通过时打印 TEST PASSED；任一检查失败会调用 $fatal 并使仿真失败。
//
// 连接说明：
//   本文件仅用于仿真，不加入综合源文件。
//
// 时钟与复位：
//   产生 100 MHz 仿真时钟；被测逻辑不依赖具体频率。所有激励在下降沿改变，
//   避免与上升沿采样产生竞争。
//
// 输入格式：
//   两路输入使用 16 位有符号二进制补码，包含正数、负数、零和符号边界。
//
// 输出格式：
//   自动检查 FIFO 打包顺序、写次数、状态电平、事件脉宽和错误恢复。
//
// 握手时序：
//   启动、消费和清错激励均按单周期脉冲产生。
//
// 参数说明：
//   主实例使用 8 点帧加速仿真；边界实例使用 1 点帧验证最小合法参数。
//
// 错误行为：
//   检查失败立即 $fatal，不继续输出成功结果。
//
// 使用限制：
//   这是 RTL 功能仿真，不替代综合、CDC、时序和板级验证。
// ============================================================================

module adc_write_controller_tb;

    localparam int unsigned DATA_WIDTH       = 16;
    localparam int unsigned TEST_FRAME_LENGTH = 8;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic                         rst;
    logic                         capture_start;
    logic                         frame_consumed;
    logic                         clear_error;
    logic                         fifo_ready;
    logic signed [DATA_WIDTH-1:0] data_a;
    logic signed [DATA_WIDTH-1:0] data_b;
    logic                         in_valid;
    logic                         fifo_full;
    logic                         fifo_wr_rst_busy;
    logic [(2*DATA_WIDTH)-1:0]     fifo_din;
    logic                         fifo_wr_en;
    logic                         capture_busy;
    logic                         frame_pending;
    logic                         frame_done_event;
    logic                         overflow_error;

    logic                         edge_rst;
    logic                         edge_start;
    logic                         edge_consumed;
    logic                         edge_clear_error;
    logic                         edge_fifo_ready;
    logic signed [DATA_WIDTH-1:0] edge_data_a;
    logic signed [DATA_WIDTH-1:0] edge_data_b;
    logic                         edge_in_valid;
    logic                         edge_fifo_full;
    logic                         edge_fifo_wr_rst_busy;
    logic [(2*DATA_WIDTH)-1:0]     edge_fifo_din;
    logic                         edge_fifo_wr_en;
    logic                         edge_capture_busy;
    logic                         edge_frame_pending;
    logic                         edge_frame_done_event;
    logic                         edge_overflow_error;

    int unsigned write_total;

    adc_write_controller #(
        .DATA_WIDTH  (DATA_WIDTH),
        .FRAME_LENGTH(TEST_FRAME_LENGTH)
    ) dut (
        .clk              (clk),
        .rst              (rst),
        .capture_start    (capture_start),
        .frame_consumed   (frame_consumed),
        .clear_error      (clear_error),
        .fifo_ready       (fifo_ready),
        .data_a           (data_a),
        .data_b           (data_b),
        .in_valid         (in_valid),
        .fifo_full        (fifo_full),
        .fifo_wr_rst_busy (fifo_wr_rst_busy),
        .fifo_din         (fifo_din),
        .fifo_wr_en       (fifo_wr_en),
        .capture_busy     (capture_busy),
        .frame_pending    (frame_pending),
        .frame_done_event (frame_done_event),
        .overflow_error   (overflow_error)
    );

    adc_write_controller #(
        .DATA_WIDTH  (DATA_WIDTH),
        .FRAME_LENGTH(1)
    ) dut_edge (
        .clk              (clk),
        .rst              (edge_rst),
        .capture_start    (edge_start),
        .frame_consumed   (edge_consumed),
        .clear_error      (edge_clear_error),
        .fifo_ready       (edge_fifo_ready),
        .data_a           (edge_data_a),
        .data_b           (edge_data_b),
        .in_valid         (edge_in_valid),
        .fifo_full        (edge_fifo_full),
        .fifo_wr_rst_busy (edge_fifo_wr_rst_busy),
        .fifo_din         (edge_fifo_din),
        .fifo_wr_en       (edge_fifo_wr_en),
        .capture_busy     (edge_capture_busy),
        .frame_pending    (edge_frame_pending),
        .frame_done_event (edge_frame_done_event),
        .overflow_error   (edge_overflow_error)
    );

    // 每次真正写入时检查双通道位模式未被符号扩展或交换。
    always @(posedge clk) begin
        if (rst) begin
            write_total <= 0;
        end else if (fifo_wr_en) begin
            assert (fifo_din === {data_a, data_b})
                else $fatal(1,
                    "FIFO 打包错误：time=%0t actual=%h expected=%h",
                    $time, fifo_din, {data_a, data_b});
            write_total <= write_total + 1;
        end
    end

    task automatic reset_main;
        begin
            @(negedge clk);
            rst              = 1'b1;
            capture_start    = 1'b0;
            frame_consumed   = 1'b0;
            clear_error      = 1'b0;
            fifo_ready       = 1'b1;
            data_a           = '0;
            data_b           = '0;
            in_valid         = 1'b0;
            fifo_full        = 1'b0;
            fifo_wr_rst_busy = 1'b0;
            repeat (2) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            @(posedge clk);
            #1;
            assert (!fifo_wr_en && !capture_busy && !frame_pending
                    && !frame_done_event && !overflow_error)
                else $fatal(1, "主实例复位后输出状态错误，time=%0t", $time);
        end
    endtask

    task automatic pulse_start;
        begin
            @(negedge clk);
            capture_start = 1'b1;
            @(posedge clk);
            #1;
            assert (capture_busy)
                else $fatal(1, "合法启动未进入采集状态，time=%0t", $time);
            @(negedge clk);
            capture_start = 1'b0;
        end
    endtask

    task automatic send_sample(
        input logic signed [DATA_WIDTH-1:0] sample_a,
        input logic signed [DATA_WIDTH-1:0] sample_b,
        input logic                         expect_last
    );
        int unsigned writes_before;
        begin
            writes_before = write_total;
            @(negedge clk);
            data_a   = sample_a;
            data_b   = sample_b;
            in_valid = 1'b1;
            @(posedge clk);
            #1;
            assert (write_total == writes_before + 1)
                else $fatal(1, "有效样点未写入，time=%0t", $time);
            assert (frame_done_event == expect_last)
                else $fatal(1,
                    "帧完成事件错误：time=%0t actual=%0b expected=%0b",
                    $time, frame_done_event, expect_last);
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task automatic insert_invalid_cycle;
        int unsigned writes_before;
        begin
            writes_before = write_total;
            @(negedge clk);
            in_valid = 1'b0;
            @(posedge clk);
            #1;
            assert (write_total == writes_before && capture_busy)
                else $fatal(1, "无效周期错误写入或退出采集，time=%0t", $time);
        end
    endtask

    initial begin
        rst              = 1'b1;
        capture_start    = 1'b0;
        frame_consumed   = 1'b0;
        clear_error      = 1'b0;
        fifo_ready       = 1'b1;
        data_a           = '0;
        data_b           = '0;
        in_valid         = 1'b0;
        fifo_full        = 1'b0;
        fifo_wr_rst_busy = 1'b0;

        edge_rst              = 1'b1;
        edge_start            = 1'b0;
        edge_consumed         = 1'b0;
        edge_clear_error      = 1'b0;
        edge_fifo_ready       = 1'b1;
        edge_data_a           = '0;
        edge_data_b           = '0;
        edge_in_valid         = 1'b0;
        edge_fifo_full        = 1'b0;
        edge_fifo_wr_rst_busy = 1'b0;

        // 正常帧：包含间断 valid、符号边界和采集中重复启动。
        reset_main();
        pulse_start();
        send_sample(16'sh8000,  16'sh7fff, 1'b0);
        send_sample(-16'sd1,    16'sd0,    1'b0);
        insert_invalid_cycle();

        @(negedge clk);
        capture_start = 1'b1;
        @(posedge clk);
        #1;
        assert (capture_busy && write_total == 2)
            else $fatal(1, "采集中的重复启动破坏当前帧，time=%0t", $time);
        @(negedge clk);
        capture_start = 1'b0;

        send_sample(16'sd123,   -16'sd456, 1'b0);
        send_sample(16'sd32767, 16'sh8000, 1'b0);
        send_sample(-16'sd17,    16'sd19,   1'b0);
        send_sample(16'sd20,     16'sd21,   1'b0);
        send_sample(16'sd22,     16'sd23,   1'b0);
        send_sample(16'sd24,     16'sd25,   1'b1);
        #1;
        assert (write_total == TEST_FRAME_LENGTH && frame_pending && !capture_busy)
            else $fatal(1, "正常帧结束状态或写入数量错误，time=%0t", $time);

        // WAIT 状态忽略启动，并仅由消费事件释放。
        @(negedge clk);
        capture_start = 1'b1;
        @(posedge clk);
        #1;
        assert (frame_pending && !capture_busy && !frame_done_event)
            else $fatal(1, "等待消费期间错误接受启动，time=%0t", $time);
        @(negedge clk);
        capture_start  = 1'b0;
        frame_consumed = 1'b1;
        @(posedge clk);
        #1;
        assert (!frame_pending && !capture_busy)
            else $fatal(1, "消费确认后未返回空闲，time=%0t", $time);
        @(negedge clk);
        frame_consumed = 1'b0;

        // 有效样点遇到 FIFO 满：禁止该拍写入并锁存错误。
        reset_main();
        pulse_start();
        send_sample(16'sd1, 16'sd2, 1'b0);
        @(negedge clk);
        data_a    = 16'sd3;
        data_b    = 16'sd4;
        in_valid  = 1'b1;
        fifo_full = 1'b1;
        @(posedge clk);
        #1;
        assert (overflow_error && !capture_busy && !fifo_wr_en
                && !frame_done_event && !frame_pending && write_total == 1)
            else $fatal(1, "FIFO 满错误处理不正确，time=%0t", $time);

        // FIFO 仍满时 clear_error 不得恢复；恢复可用后才接受清错。
        @(negedge clk);
        in_valid    = 1'b0;
        clear_error = 1'b1;
        @(posedge clk);
        #1;
        assert (overflow_error)
            else $fatal(1, "FIFO 未恢复时错误被提前清除，time=%0t", $time);
        @(negedge clk);
        fifo_full = 1'b0;
        @(posedge clk);
        #1;
        assert (!overflow_error && !capture_busy && !frame_pending)
            else $fatal(1, "FIFO 恢复后清错失败，time=%0t", $time);
        @(negedge clk);
        clear_error = 1'b0;

        // 采集中 fifo_ready 撤销会使已写入半帧不再可信，必须锁存错误。
        pulse_start();
        send_sample(16'sd5, 16'sd6, 1'b0);
        @(negedge clk);
        fifo_ready = 1'b0;
        @(posedge clk);
        #1;
        assert (overflow_error && !capture_busy && !fifo_wr_en)
            else $fatal(1, "采集中 FIFO 失去 ready 未触发帧错误，time=%0t", $time);
        @(negedge clk);
        clear_error = 1'b1;
        @(posedge clk);
        #1;
        assert (overflow_error)
            else $fatal(1, "FIFO 未 ready 时错误被提前清除，time=%0t", $time);
        @(negedge clk);
        fifo_ready = 1'b1;
        @(posedge clk);
        #1;
        assert (!overflow_error && !capture_busy && !frame_pending)
            else $fatal(1, "FIFO 重新 ready 后清错失败，time=%0t", $time);
        @(negedge clk);
        clear_error = 1'b0;

        // 采集中 FIFO 进入复位忙，即使当前无有效样点也必须判定帧损坏。
        pulse_start();
        insert_invalid_cycle();
        @(negedge clk);
        fifo_wr_rst_busy = 1'b1;
        @(posedge clk);
        #1;
        assert (overflow_error && !capture_busy && !fifo_wr_en)
            else $fatal(1, "FIFO 写端复位忙未触发帧错误，time=%0t", $time);

        // 工作中同步复位清除所有状态，不产生虚假完成或写入。
        @(negedge clk);
        rst = 1'b1;
        @(posedge clk);
        #1;
        assert (!overflow_error && !capture_busy && !frame_pending
                && !frame_done_event && !fifo_wr_en)
            else $fatal(1, "工作中复位后的输出不安全，time=%0t", $time);
        @(negedge clk);
        rst              = 1'b0;
        fifo_wr_rst_busy = 1'b0;

        // 最小帧长实例：第一组有效样点既要写入，也要在同拍结束帧。
        repeat (2) @(posedge clk);
        @(negedge clk);
        edge_rst = 1'b0;
        @(negedge clk);
        edge_start = 1'b1;
        @(posedge clk);
        #1;
        assert (edge_capture_busy)
            else $fatal(1, "单点帧实例启动失败，time=%0t", $time);
        @(negedge clk);
        edge_start    = 1'b0;
        edge_data_a   = 16'sh8000;
        edge_data_b   = 16'sd32767;
        edge_in_valid = 1'b1;
        @(posedge clk);
        #1;
        assert (edge_frame_done_event && edge_frame_pending
                && !edge_capture_busy
                && edge_fifo_din === {edge_data_a, edge_data_b})
            else $fatal(1, "单点帧最后一拍处理错误，time=%0t", $time);
        @(negedge clk);
        edge_in_valid = 1'b0;

        $display("TEST PASSED");
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "测试超时");
    end

endmodule

`default_nettype wire
