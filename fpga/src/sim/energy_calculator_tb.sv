`timescale 1ns/1ps
`default_nettype none

module energy_calculator_tb;

    localparam int POWER_WIDTH      = 32;
    localparam int ENERGY_ACC_WIDTH = 35;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start = 1'b0;
    logic base_valid = 1'b0;
    logic [15:0] base_index_500 = 16'd0;
    logic [31:0] absolute_threshold = 32'd0;
    logic [15:0] ratio_num = 16'd1;
    logic [15:0] ratio_den = 16'd100;

    wire busy;
    wire done;
    wire mem_req;
    wire [10:0] mem_addr;
    wire mem_ready;
    logic mem_rvalid = 1'b0;
    logic [31:0] mem_rdata = 32'd0;

    wire result_bram_en;
    wire result_bram_we;
    wire [3:0] result_bram_addr;
    wire [31:0] result_bram_din;
    wire [2:0] harmonic_present_mask;
    wire [2:0] position_valid_mask;
    wire result_valid;
    wire energy_overflow;

    logic [31:0] spectrum_memory [0:2047];
    logic [31:0] result_memory [0:15];

    integer response_addr_queue [0:1023];
    integer response_due_queue [0:1023];
    integer response_head = 0;
    integer response_tail = 0;
    integer response_delay_cycles = 2;
    logic enable_ready_stalls = 1'b0;

    integer cycle_count = 0;
    integer request_count = 0;
    integer receive_count = 0;
    integer simultaneous_count = 0;
    integer result_write_count = 0;
    integer done_count = 0;
    integer reset_request_start = 0;
    integer write_addr_log [0:2047];
    logic [31:0] write_data_log [0:2047];
    integer index;

    always #5 clk = ~clk;

    assign mem_ready =
        !enable_ready_stalls || ((cycle_count % 5) != 2);

    energy_calculator dut (
        .clk                    (clk),
        .rst                    (rst),
        .start                  (start),
        .busy                   (busy),
        .done                   (done),
        .base_valid             (base_valid),
        .base_index_500         (base_index_500),
        .absolute_threshold     (absolute_threshold),
        .ratio_num              (ratio_num),
        .ratio_den              (ratio_den),
        .mem_req                (mem_req),
        .mem_addr               (mem_addr),
        .mem_ready              (mem_ready),
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

    function automatic integer candidate_bin(
        input integer frequency_index
    );
        begin
            candidate_bin = ((128 * frequency_index) + 62) / 125;
        end
    endfunction

    function automatic logic candidate_position_valid(
        input logic valid_input,
        input integer center_bin
    );
        begin
            candidate_position_valid =
                valid_input && (center_bin >= 3) && (center_bin <= 2044);
        end
    endfunction

    function automatic logic [31:0] scaled_energy(
        input logic [34:0] raw_energy
    );
        logic [35:0] rounded_energy;
        begin
            rounded_energy = {1'b0, raw_energy} + 36'd4;
            scaled_energy = rounded_energy >> 3;
        end
    endfunction

    task automatic clear_spectrum;
        integer clear_index;
        begin
            for (clear_index = 0; clear_index < 2048;
                 clear_index = clear_index + 1) begin
                spectrum_memory[clear_index] = 32'd0;
            end
        end
    endtask

    // 将总能量放在窗口最后一个地址，专门检查第7个返回值是否被计入。
    task automatic set_window_energy(
        input integer center_bin,
        input logic [31:0] raw_energy
    );
        begin
            if ((center_bin >= 3) && (center_bin <= 2044)) begin
                spectrum_memory[center_bin + 3] = raw_energy;
            end
        end
    endtask

    task automatic pulse_start;
        begin
            @(negedge clk);
            start <= 1'b1;
            @(negedge clk);
            start <= 1'b0;
        end
    endtask

    task automatic wait_for_done;
        integer timeout;
        begin
            timeout = 0;
            while (!done && timeout < 5000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            assert (done)
                else $fatal(1, "等待energy done超时");
            #1;
        end
    endtask

    task automatic run_frame_and_check(
        input logic        input_base_valid,
        input integer      input_base_index,
        input logic [31:0] input_base_raw,
        input logic [31:0] input_h2_raw,
        input logic [31:0] input_h3_raw,
        input logic [31:0] input_absolute_threshold,
        input logic [15:0] input_ratio_num,
        input logic [15:0] input_ratio_den,
        input integer      input_response_delay,
        input logic        input_ready_stalls,
        input logic        repeat_start_while_busy
    );
        integer base_center;
        integer h2_center;
        integer h3_center;
        logic base_position;
        logic h2_position;
        logic h3_position;
        logic [2:0] expected_position_mask;
        logic [2:0] expected_present_mask;
        logic [34:0] expected_base_raw;
        logic [34:0] expected_h2_raw;
        logic [34:0] expected_h3_raw;
        logic [63:0] base_ratio_side;
        logic [63:0] h2_ratio_side;
        logic [63:0] h3_ratio_side;
        logic expected_base_invalid;
        logic expected_threshold_invalid;
        logic [31:0] expected_status;
        integer request_start;
        integer write_start;
        integer done_start;
        integer simultaneous_start;
        integer expected_request_count;
        integer log_offset;
        integer reserved_index;
        begin
            while (busy) @(negedge clk);

            clear_spectrum();
            base_center = candidate_bin(input_base_index);
            h2_center   = candidate_bin(2 * input_base_index);
            h3_center   = candidate_bin(3 * input_base_index);
            base_position = candidate_position_valid(
                input_base_valid, base_center);
            h2_position = candidate_position_valid(
                input_base_valid, h2_center);
            h3_position = candidate_position_valid(
                input_base_valid, h3_center);

            set_window_energy(base_center, input_base_raw);
            set_window_energy(h2_center, input_h2_raw);
            set_window_energy(h3_center, input_h3_raw);

            expected_base_raw =
                base_position ? {3'd0, input_base_raw} : 35'd0;
            expected_h2_raw =
                h2_position ? {3'd0, input_h2_raw} : 35'd0;
            expected_h3_raw =
                h3_position ? {3'd0, input_h3_raw} : 35'd0;
            expected_position_mask =
                {h3_position, h2_position, base_position};
            expected_threshold_invalid = (input_ratio_den == 16'd0);
            expected_base_invalid =
                !input_base_valid || !base_position;

            base_ratio_side =
                expected_base_raw * input_ratio_num;
            h2_ratio_side =
                expected_h2_raw * input_ratio_den;
            h3_ratio_side =
                expected_h3_raw * input_ratio_den;
            expected_present_mask[0] =
                input_base_valid && base_position;
            expected_present_mask[1] =
                h2_position &&
                !expected_threshold_invalid &&
                (expected_h2_raw >= input_absolute_threshold) &&
                (h2_ratio_side >= base_ratio_side);
            expected_present_mask[2] =
                h3_position &&
                !expected_threshold_invalid &&
                (expected_h3_raw >= input_absolute_threshold) &&
                (h3_ratio_side >= base_ratio_side);

            expected_status = 32'd0;
            expected_status[0] = 1'b1;
            expected_status[3] = expected_base_invalid;
            expected_status[4] = expected_threshold_invalid;
            expected_status[10:8] = expected_present_mask;
            expected_status[13:11] = expected_position_mask;

            base_valid            <= input_base_valid;
            base_index_500        <= input_base_index[15:0];
            absolute_threshold    <= input_absolute_threshold;
            ratio_num             <= input_ratio_num;
            ratio_den             <= input_ratio_den;
            response_delay_cycles  = input_response_delay;
            enable_ready_stalls   <= input_ready_stalls;

            request_start      = request_count;
            write_start        = result_write_count;
            done_start         = done_count;
            simultaneous_start = simultaneous_count;

            pulse_start();
            if (repeat_start_while_busy) begin
                repeat (2) pulse_start();
            end
            wait_for_done();

            assert (!busy && result_valid && !energy_overflow)
                else $fatal(1, "帧结束状态错误");
            assert (position_valid_mask == expected_position_mask)
                else $fatal(1, "位置有效掩码错误");
            assert (harmonic_present_mask == expected_present_mask)
                else $fatal(1, "谐波存在掩码错误");

            assert (dut.base_energy_raw == expected_base_raw)
                else $fatal(1, "基波原始能量错误");
            assert (dut.harmonic2_energy_raw == expected_h2_raw)
                else $fatal(1, "二次谐波原始能量错误");
            assert (dut.harmonic3_energy_raw == expected_h3_raw)
                else $fatal(1, "三次谐波原始能量错误");

            assert (result_memory[0] == expected_status)
                else $fatal(1, "最终状态字错误：got=%h expected=%h",
                            result_memory[0], expected_status);
            assert (result_memory[1] == input_base_index)
                else $fatal(1, "基波频率编号错误");
            assert (result_memory[2] == scaled_energy(expected_base_raw))
                else $fatal(1, "基波缩放能量错误");
            assert (result_memory[3] == (2 * input_base_index))
                else $fatal(1, "二次谐波频率编号错误");
            assert (result_memory[4] == scaled_energy(expected_h2_raw))
                else $fatal(1, "二次谐波缩放能量错误");
            assert (result_memory[5] == (3 * input_base_index))
                else $fatal(1, "三次谐波频率编号错误");
            assert (result_memory[6] == scaled_energy(expected_h3_raw))
                else $fatal(1, "三次谐波缩放能量错误");
            assert (result_memory[7] == 32'd3)
                else $fatal(1, "ENERGY_SHIFT字段错误");
            assert (result_memory[8] == input_absolute_threshold)
                else $fatal(1, "绝对阈值字段错误");
            assert (result_memory[9] ==
                    {input_ratio_den, input_ratio_num})
                else $fatal(1, "比例参数打包顺序错误");
            for (reserved_index = 10; reserved_index < 16;
                 reserved_index = reserved_index + 1) begin
                assert (result_memory[reserved_index] == 32'd0)
                    else $fatal(1, "保留地址W%0d没有清零",
                                reserved_index);
            end

            expected_request_count =
                7 * (base_position + h2_position + h3_position);
            assert ((request_count - request_start) ==
                    expected_request_count)
                else $fatal(1, "频谱读取请求数量错误");
            assert ((result_write_count - write_start) == 17)
                else $fatal(1, "结果BRAM写入次数错误");

            log_offset = write_start;
            assert (write_addr_log[log_offset] == 0 &&
                    write_data_log[log_offset][1:0] == 2'b10)
                else $fatal(1, "首个W0不是busy状态");
            for (reserved_index = 1; reserved_index < 16;
                 reserved_index = reserved_index + 1) begin
                assert (write_addr_log[log_offset + reserved_index] ==
                        reserved_index)
                    else $fatal(1, "结果BRAM地址顺序错误");
            end
            assert (write_addr_log[log_offset + 16] == 0 &&
                    write_data_log[log_offset + 16] == expected_status)
                else $fatal(1, "最终W0不是最后一次写入");
            // 延迟为1且存在连续请求时，应覆盖同拍提交和返回。
            if ((input_response_delay == 1) &&
                (expected_request_count > 7)) begin
                assert (simultaneous_count > simultaneous_start)
                    else $fatal(1, "未覆盖同拍请求与返回");
            end

            @(posedge clk);
            #1;
            assert ((done_count - done_start) == 1)
                else $fatal(1, "done脉冲计数错误");
            @(negedge clk);
            assert (!done)
                else $fatal(1, "done持续超过一个时钟周期");
        end
    endtask

    // 可变延迟、可反压的Spectrol读取接口模型。
    always_ff @(posedge clk) begin
        if (rst) begin
            mem_rvalid         <= 1'b0;
            mem_rdata          <= 32'd0;
            response_head      <= 0;
            response_tail      <= 0;
            cycle_count        <= 0;
            request_count      <= 0;
            receive_count      <= 0;
            simultaneous_count <= 0;
            result_write_count <= 0;
            done_count         <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            mem_rvalid  <= 1'b0;

            if ((response_head < response_tail) &&
                (response_due_queue[response_head] <= cycle_count)) begin
                mem_rvalid    <= 1'b1;
                mem_rdata     <=
                    spectrum_memory[
                        response_addr_queue[response_head]];
                response_head <= response_head + 1;
                receive_count <= receive_count + 1;
            end

            if (mem_req && mem_ready) begin
                response_addr_queue[response_tail] <= mem_addr;
                response_due_queue[response_tail] <=
                    cycle_count + response_delay_cycles;
                response_tail <= response_tail + 1;
                request_count <= request_count + 1;
            end

            if ((mem_req && mem_ready) && mem_rvalid) begin
                simultaneous_count <= simultaneous_count + 1;
            end

            if (result_bram_en && result_bram_we) begin
                result_memory[result_bram_addr] <= result_bram_din;
                write_addr_log[result_write_count] <= result_bram_addr;
                write_data_log[result_write_count] <= result_bram_din;
                result_write_count <= result_write_count + 1;
            end

            if (done) begin
                done_count <= done_count + 1;
            end
        end
    end

    initial begin
        for (index = 0; index < 2048; index = index + 1) begin
            spectrum_memory[index] = 32'd0;
        end
        for (index = 0; index < 16; index = index + 1) begin
            result_memory[index] = 32'hA5A5_A5A5;
        end

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst <= 1'b0;

        // 只有基波；延迟1用于覆盖连续请求、返回以及两者同拍发生。
        run_frame_and_check(1'b1, 40, 32'd800, 32'd20, 32'd30,
                            32'd100, 16'd1, 16'd100, 1, 1'b0, 1'b0);

        // 分别覆盖二次、三次以及全部谐波存在。
        run_frame_and_check(1'b1, 40, 32'd800, 32'd200, 32'd20,
                            32'd100, 16'd1, 16'd100, 2, 1'b0, 1'b0);
        run_frame_and_check(1'b1, 40, 32'd800, 32'd20, 32'd200,
                            32'd100, 16'd1, 16'd100, 3, 1'b0, 1'b0);
        run_frame_and_check(1'b1, 40, 32'd800, 32'd200, 32'd300,
                            32'd100, 16'd1, 16'd100, 4, 1'b1, 1'b0);

        // base_index=670时三次谐波越界，二次谐波仍在范围内。
        run_frame_and_check(1'b1, 670, 32'd700, 32'd200, 32'd500,
                            32'd100, 16'd1, 16'd100, 2, 1'b1, 1'b0);

        // base_index=1000时二、三次谐波均越界。
        run_frame_and_check(1'b1, 1000, 32'd700, 32'd500, 32'd500,
                            32'd100, 16'd1, 16'd100, 2, 1'b0, 1'b0);

        // 无效基频仍然启动模块并提交一帧无效结果。
        run_frame_and_check(1'b0, 0, 32'd0, 32'd0, 32'd0,
                            32'd100, 16'd1, 16'd100, 2, 1'b0, 1'b0);

        // 比例分母为0时只允许基波存在，并发布threshold_invalid。
        run_frame_and_check(1'b1, 40, 32'd800, 32'd400, 32'd400,
                            32'd100, 16'd1, 16'd0, 2, 1'b0, 1'b0);

        // 原始能量11应四舍五入为1；能量位于第7个返回地址。
        run_frame_and_check(1'b1, 40, 32'd11, 32'd0, 32'd0,
                            32'd1000, 16'd1, 16'd100, 1, 1'b0, 1'b0);

        // 功率谱扩大4倍时，统一缩放后的能量也保持4倍。
        run_frame_and_check(1'b1, 40, 32'd80, 32'd0, 32'd0,
                            32'd1000, 16'd1, 16'd100, 2, 1'b0, 1'b0);
        assert (result_memory[2] == 32'd10)
            else $fatal(1, "一倍功率能量参考错误");
        run_frame_and_check(1'b1, 40, 32'd320, 32'd0, 32'd0,
                            32'd1000, 16'd1, 16'd100, 2, 1'b0, 1'b0);
        assert (result_memory[2] == 32'd40)
            else $fatal(1, "四倍功率没有得到四倍能量");

        // busy期间重复start必须被忽略，不得生成额外帧。
        run_frame_and_check(1'b1, 40, 32'd800, 32'd200, 32'd300,
                            32'd100, 16'd1, 16'd100, 4, 1'b1, 1'b1);

        // 处理中同步复位，随后必须能重新完成一帧。
        clear_spectrum();
        set_window_energy(candidate_bin(40), 32'd800);
        base_valid         <= 1'b1;
        base_index_500     <= 16'd40;
        absolute_threshold <= 32'd100;
        ratio_num          <= 16'd1;
        ratio_den          <= 16'd100;
        response_delay_cycles = 4;
        enable_ready_stalls <= 1'b1;
        reset_request_start = request_count;
        pulse_start();
        wait (request_count >= reset_request_start + 2);
        @(negedge clk);
        rst <= 1'b1;
        repeat (2) @(negedge clk);
        assert (!busy && !done && !mem_req &&
                !result_bram_en && !result_valid)
            else $fatal(1, "处理中复位没有清除控制状态");
        rst <= 1'b0;
        run_frame_and_check(1'b1, 40, 32'd800, 32'd0, 32'd0,
                            32'd100, 16'd1, 16'd100, 2, 1'b0, 1'b0);

        $display("TEST PASSED: energy_calculator");
        $finish;
    end

    // 实现问题记录：
    // 1. 读取模型用请求队列分离ready和rvalid，避免测试依赖固定BRAM延迟。
    // 2. 每个窗口只在最后一个地址放置能量，能够直接暴露遗漏第7个返回值的问题。
    // 3. U32功率配合右移3位时理论上不会饱和，防御性饱和由独立U33测试覆盖。

endmodule

`default_nettype wire
