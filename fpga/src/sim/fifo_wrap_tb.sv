`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 测试平台名称：fifo_wrap_tb
//
// 验证目标：
//   使用 FWFT 异步 FIFO 行为模型，对 fifo_wrap 进行端到端自检。覆盖 30 MHz 写域
//   到 100 MHz 读域、16 位有符号位模式、整帧计数、FIR 反压、帧首尾、双向 CDC、
//   连续两帧以及空闲协调复位后的恢复能力。
// ============================================================================

module fifo_wrap_tb;

    localparam int FRAME_SIZE = 8;

    logic wr_clk = 1'b0;
    logic rd_clk = 1'b0;
    logic wr_rst = 1'b1;
    logic rd_rst = 1'b1;
    logic fifo_rst = 1'b1;

    logic signed [15:0] adc_data = '0;
    logic adc_valid = 1'b0;
    logic capture_start = 1'b0;
    logic clear_error = 1'b0;

    wire signed [15:0] fir_data;
    wire fir_valid;
    logic fir_ready = 1'b0;
    wire fir_first;
    wire fir_last;
    logic fir_frame_done = 1'b0;

    wire capture_busy;
    wire frame_pending;
    wire fifo_ready;
    wire wr_error;
    wire rd_error;

    logic signed [15:0] expected_data [0:2*FRAME_SIZE-1];
    integer received_count = 0;
    integer ready_pattern = 0;

    always #16.6665 wr_clk = ~wr_clk;
    initial begin
        #1.3;
        forever #5.0 rd_clk = ~rd_clk;
    end

    fifo_wrap #(
        .DATA_WIDTH (16),
        .FRAME_SIZE (FRAME_SIZE)
    ) dut (
        .wr_clk         (wr_clk),
        .wr_rst         (wr_rst),
        .rd_clk         (rd_clk),
        .rd_rst         (rd_rst),
        .fifo_rst       (fifo_rst),
        .adc_data       (adc_data),
        .adc_valid      (adc_valid),
        .capture_start  (capture_start),
        .clear_error    (clear_error),
        .fir_data       (fir_data),
        .fir_valid      (fir_valid),
        .fir_ready      (fir_ready),
        .fir_first      (fir_first),
        .fir_last       (fir_last),
        .fir_frame_done (fir_frame_done),
        .capture_busy   (capture_busy),
        .frame_pending  (frame_pending),
        .fifo_ready     (fifo_ready),
        .wr_error       (wr_error),
        .rd_error       (rd_error)
    );

    // 周期性制造 FIR 反压，检查 FWFT 数据和帧边界能否保持到握手。
    always @(negedge rd_clk) begin
        if (rd_rst) begin
            fir_ready    <= 1'b0;
            ready_pattern <= 0;
        end else begin
            ready_pattern <= ready_pattern + 1;
            fir_ready <= ((ready_pattern % 4) != 1);
        end
    end

    always @(posedge rd_clk) begin
        if (!rd_rst && fir_valid && fir_ready) begin
            assert (received_count < 2*FRAME_SIZE)
                else $fatal(1, "FIR 收到超出预期数量的数据，time=%0t", $time);
            assert (fir_data === expected_data[received_count])
                else $fatal(1,
                    "FIR 数据错误，index=%0d actual=%0d expected=%0d time=%0t",
                    received_count, fir_data, expected_data[received_count], $time);
            assert (fir_first == ((received_count % FRAME_SIZE) == 0))
                else $fatal(1, "fir_first 错误，index=%0d time=%0t", received_count, $time);
            assert (fir_last == ((received_count % FRAME_SIZE) == FRAME_SIZE-1))
                else $fatal(1, "fir_last 错误，index=%0d time=%0t", received_count, $time);
            received_count = received_count + 1;
        end
    end

    task automatic pulse_capture_start;
        begin
            @(negedge wr_clk);
            capture_start = 1'b1;
            @(negedge wr_clk);
            capture_start = 1'b0;
        end
    endtask

    task automatic pulse_fir_done;
        begin
            @(negedge rd_clk);
            fir_frame_done = 1'b1;
            @(negedge rd_clk);
            fir_frame_done = 1'b0;
        end
    endtask

    task automatic send_frame(input integer first_index);
        integer sample_index;
        begin
            pulse_capture_start();
            wait (capture_busy);
            for (sample_index = 0; sample_index < FRAME_SIZE;
                 sample_index = sample_index + 1) begin
                @(negedge wr_clk);
                adc_data  = expected_data[first_index + sample_index];
                adc_valid = 1'b1;
            end
            @(negedge wr_clk);
            adc_valid = 1'b0;
            adc_data  = '0;
            wait (frame_pending);
        end
    endtask

    initial begin : test_sequence
        integer index;

        expected_data[0] = -16'sd32768;
        expected_data[1] = -16'sd12345;
        expected_data[2] = -16'sd1;
        expected_data[3] =  16'sd0;
        expected_data[4] =  16'sd1;
        expected_data[5] =  16'sd12345;
        expected_data[6] =  16'sd30000;
        expected_data[7] =  16'sd32767;
        for (index = 0; index < FRAME_SIZE; index = index + 1) begin
            expected_data[FRAME_SIZE + index] = $signed(16'sh4100 + index);
        end

        // FIFO 异步复位先释放，等待 IP 两侧 busy 清除后再同步释放控制逻辑。
        repeat (5) @(posedge wr_clk);
        fifo_rst = 1'b0;
        wait (!dut.fifo_wr_rst_busy && !dut.fifo_rd_rst_busy);
        @(negedge wr_clk);
        wr_rst = 1'b0;
        @(negedge rd_clk);
        rd_rst = 1'b0;

        repeat (3) @(posedge wr_clk);
        assert (fifo_ready && !wr_error && !rd_error)
            else $fatal(1, "初始化后 wrapper 未就绪或出现错误");

        // 第一帧覆盖有符号最值、零和正负数。
        send_frame(0);
        wait (received_count == FRAME_SIZE);
        wait (!frame_pending);
        repeat (3) @(posedge rd_clk);
        pulse_fir_done();

        // 第二帧验证完整握手结束后可重新采集。
        repeat (3) @(posedge wr_clk);
        send_frame(FRAME_SIZE);
        wait (received_count == 2*FRAME_SIZE);
        wait (!frame_pending);
        repeat (2) @(posedge rd_clk);
        pulse_fir_done();

        repeat (8) @(posedge wr_clk);
        assert (!capture_busy && !frame_pending && !wr_error && !rd_error)
            else $fatal(1, "两帧结束后的状态错误");

        // 空闲状态再次协调复位，检查无虚假事件且可以恢复就绪。
        wr_rst   = 1'b1;
        rd_rst   = 1'b1;
        fifo_rst = 1'b1;
        repeat (5) @(posedge wr_clk);
        fifo_rst = 1'b0;
        wait (!dut.fifo_wr_rst_busy && !dut.fifo_rd_rst_busy);
        @(negedge wr_clk);
        wr_rst = 1'b0;
        @(negedge rd_clk);
        rd_rst = 1'b0;
        repeat (8) @(posedge wr_clk);

        assert (fifo_ready && !capture_busy && !frame_pending
                && !wr_error && !rd_error && received_count == 2*FRAME_SIZE)
            else $fatal(1, "协调复位后的恢复状态错误");

        $display("TEST PASSED: fifo_wrap 完成 %0d 个样点的端到端传输", received_count);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "fifo_wrap 端到端仿真超时");
    end

endmodule

// ============================================================================
// fifo_generator_0 仿真替身
//
// 仅用于 wrapper 单元测试，模拟 16 位、独立时钟、FWFT 和复位 busy 行为。
// 综合与工程集成必须使用 src/ip 中的真实 Xilinx FIFO Generator IP。
// ============================================================================
module fifo_generator_0 (
    input  wire        rst,
    input  wire        wr_clk,
    input  wire        rd_clk,
    input  wire [15:0] din,
    input  wire        wr_en,
    input  wire        rd_en,
    output wire [15:0] dout,
    output wire        full,
    output wire        empty,
    output wire        wr_rst_busy,
    output wire        rd_rst_busy
);

    logic [15:0] memory [0:65536];
    integer write_pointer = 0;
    integer read_pointer = 0;
    logic [1:0] write_reset_pipe = 2'b11;
    logic [1:0] read_reset_pipe = 2'b11;

    assign empty = (write_pointer == read_pointer);
    assign full  = ((write_pointer - read_pointer) >= 65536);
    assign dout  = empty ? 16'b0 : memory[read_pointer];
    assign wr_rst_busy = |write_reset_pipe;
    assign rd_rst_busy = |read_reset_pipe;

    always @(posedge wr_clk or posedge rst) begin
        if (rst) begin
            write_pointer   <= 0;
            write_reset_pipe <= 2'b11;
        end else begin
            write_reset_pipe <= {write_reset_pipe[0], 1'b0};
            if (wr_en && !full && !wr_rst_busy) begin
                memory[write_pointer] <= din;
                write_pointer <= write_pointer + 1;
            end
        end
    end

    always @(posedge rd_clk or posedge rst) begin
        if (rst) begin
            read_pointer   <= 0;
            read_reset_pipe <= 2'b11;
        end else begin
            read_reset_pipe <= {read_reset_pipe[0], 1'b0};
            if (rd_en && !empty && !rd_rst_busy) begin
                read_pointer <= read_pointer + 1;
            end
        end
    end

endmodule

`default_nettype wire
