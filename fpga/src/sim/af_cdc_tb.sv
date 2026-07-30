`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 测试平台名称：af_cdc_tb
//
// 验证目标：
//   自检 af_cdc 在 30 MHz 到 100 MHz、100 MHz 到 30 MHz 和非整数频率比下的
//   事件完整性，并覆盖忙时重复提交、源/目标时钟暂停、空闲及忙时协调复位、
//   长时间 toggle 往返和目标事件单周期宽度。
// ============================================================================

module af_cdc_tb;

    logic src_clk_a = 1'b0;
    logic dst_clk_a = 1'b0;
    logic src_clk_b = 1'b0;
    logic dst_clk_b = 1'b0;
    logic src_clk_c = 1'b0;
    logic dst_clk_c = 1'b0;

    logic src_clk_en_a = 1'b1;
    logic dst_clk_en_a = 1'b1;

    logic src_rst_a = 1'b1;
    logic dst_rst_a = 1'b1;
    logic src_event_a = 1'b0;
    logic src_busy_a;
    logic src_protocol_error_a;
    logic dst_event_a;

    logic src_rst_b = 1'b1;
    logic dst_rst_b = 1'b1;
    logic src_event_b = 1'b0;
    logic src_busy_b;
    logic src_protocol_error_b;
    logic dst_event_b;

    logic src_rst_c = 1'b1;
    logic dst_rst_c = 1'b1;
    logic src_event_c = 1'b0;
    logic src_busy_c;
    logic src_protocol_error_c;
    logic dst_event_c;

    integer received_a = 0;
    integer received_b = 0;
    integer received_c = 0;
    logic previous_dst_event_a = 1'b0;
    logic previous_dst_event_b = 1'b0;
    logic previous_dst_event_c = 1'b0;

    // A：约 30 MHz 到 100 MHz；初始边沿故意错开。
    initial begin
        #1.7;
        forever begin
            #16.6665;
            if (src_clk_en_a) begin
                src_clk_a = ~src_clk_a;
            end else begin
                src_clk_a = 1'b0;
            end
        end
    end

    initial begin
        #0.3;
        forever begin
            #5.0;
            if (dst_clk_en_a) begin
                dst_clk_a = ~dst_clk_a;
            end else begin
                dst_clk_a = 1'b0;
            end
        end
    end

    // B：100 MHz 到约 30 MHz，验证反向实例的快到慢传输。
    initial begin
        #2.1;
        forever #5.0 src_clk_b = ~src_clk_b;
    end

    initial begin
        #4.4;
        forever #16.6665 dst_clk_b = ~dst_clk_b;
    end

    // C：约 71 MHz 到约 43 MHz，采用非整数频率比并作长期往返测试。
    initial begin
        #0.9;
        forever #7.0 src_clk_c = ~src_clk_c;
    end

    initial begin
        #3.2;
        forever #11.5 dst_clk_c = ~dst_clk_c;
    end

    af_cdc #(.SYNC_STAGES(2)) dut_a (
        .src_clk(src_clk_a),
        .src_rst(src_rst_a),
        .src_event(src_event_a),
        .src_busy(src_busy_a),
        .src_protocol_error(src_protocol_error_a),
        .dst_clk(dst_clk_a),
        .dst_rst(dst_rst_a),
        .dst_event(dst_event_a)
    );

    af_cdc #(.SYNC_STAGES(3)) dut_b (
        .src_clk(src_clk_b),
        .src_rst(src_rst_b),
        .src_event(src_event_b),
        .src_busy(src_busy_b),
        .src_protocol_error(src_protocol_error_b),
        .dst_clk(dst_clk_b),
        .dst_rst(dst_rst_b),
        .dst_event(dst_event_b)
    );

    af_cdc #(.SYNC_STAGES(2)) dut_c (
        .src_clk(src_clk_c),
        .src_rst(src_rst_c),
        .src_event(src_event_c),
        .src_busy(src_busy_c),
        .src_protocol_error(src_protocol_error_c),
        .dst_clk(dst_clk_c),
        .dst_rst(dst_rst_c),
        .dst_event(dst_event_c)
    );

    always @(posedge dst_clk_a) begin
        if (!dst_rst_a) begin
            assert (!(dst_event_a && previous_dst_event_a))
                else $fatal(1, "A 的 dst_event 超过一个目标时钟周期，time=%0t", $time);
            if (dst_event_a) received_a = received_a + 1;
            previous_dst_event_a <= dst_event_a;
        end else begin
            previous_dst_event_a <= 1'b0;
        end
    end

    always @(posedge dst_clk_b) begin
        if (!dst_rst_b) begin
            assert (!(dst_event_b && previous_dst_event_b))
                else $fatal(1, "B 的 dst_event 超过一个目标时钟周期，time=%0t", $time);
            if (dst_event_b) received_b = received_b + 1;
            previous_dst_event_b <= dst_event_b;
        end else begin
            previous_dst_event_b <= 1'b0;
        end
    end

    always @(posedge dst_clk_c) begin
        if (!dst_rst_c) begin
            assert (!(dst_event_c && previous_dst_event_c))
                else $fatal(1, "C 的 dst_event 超过一个目标时钟周期，time=%0t", $time);
            if (dst_event_c) received_c = received_c + 1;
            previous_dst_event_c <= dst_event_c;
        end else begin
            previous_dst_event_c <= 1'b0;
        end
    end

    task automatic pulse_a;
        begin
            @(negedge src_clk_a);
            src_event_a = 1'b1;
            @(negedge src_clk_a);
            src_event_a = 1'b0;
        end
    endtask

    task automatic pulse_b;
        begin
            @(negedge src_clk_b);
            src_event_b = 1'b1;
            @(negedge src_clk_b);
            src_event_b = 1'b0;
        end
    endtask

    task automatic pulse_c;
        begin
            @(negedge src_clk_c);
            src_event_c = 1'b1;
            @(negedge src_clk_c);
            src_event_c = 1'b0;
        end
    endtask

    task automatic wait_idle_a;
        integer cycles;
        begin
            cycles = 0;
            while (src_busy_a && cycles < 100) begin
                @(posedge src_clk_a);
                cycles = cycles + 1;
            end
            assert (!src_busy_a)
                else $fatal(1, "A 握手超时，time=%0t", $time);
        end
    endtask

    task automatic wait_idle_b;
        integer cycles;
        begin
            cycles = 0;
            while (src_busy_b && cycles < 150) begin
                @(posedge src_clk_b);
                cycles = cycles + 1;
            end
            assert (!src_busy_b)
                else $fatal(1, "B 握手超时，time=%0t", $time);
        end
    endtask

    task automatic wait_idle_c;
        integer cycles;
        begin
            cycles = 0;
            while (src_busy_c && cycles < 150) begin
                @(posedge src_clk_c);
                cycles = cycles + 1;
            end
            assert (!src_busy_c)
                else $fatal(1, "C 握手超时，time=%0t", $time);
        end
    endtask

    initial begin : test_sequence
        integer index;
        integer expected_a;
        integer expected_b;
        integer expected_c;
        integer count_before_reset;

        // 两侧时钟运行时协调复位，保证所有 toggle 初值一致。
        repeat (5) @(posedge src_clk_a);
        src_rst_a = 1'b0;
        repeat (5) @(posedge src_clk_b);
        src_rst_b = 1'b0;
        repeat (5) @(posedge src_clk_c);
        src_rst_c = 1'b0;
        repeat (5) @(posedge dst_clk_a);
        dst_rst_a = 1'b0;
        repeat (5) @(posedge dst_clk_b);
        dst_rst_b = 1'b0;
        repeat (5) @(posedge dst_clk_c);
        dst_rst_c = 1'b0;

        assert (!src_busy_a && !src_busy_b && !src_busy_c)
            else $fatal(1, "复位释放后 src_busy 未清零");

        // 正常单事件及连续合法事件。
        expected_a = received_a + 1;
        pulse_a();
        assert (src_busy_a) else $fatal(1, "A 接收事件后 src_busy 未拉高");
        wait_idle_a();
        assert (received_a == expected_a)
            else $fatal(1, "A 单事件数量错误，actual=%0d expected=%0d", received_a, expected_a);

        for (index = 0; index < 12; index = index + 1) begin
            expected_a = expected_a + 1;
            pulse_a();
            wait_idle_a();
        end
        assert (received_a == expected_a && !src_protocol_error_a)
            else $fatal(1, "A 连续合法事件测试失败");

        // 忙时第二个事件必须被拒绝，首个事件仍完成且错误保持。
        expected_a = expected_a + 1;
        pulse_a();
        assert (src_busy_a) else $fatal(1, "A 重复事件测试未进入忙状态");
        pulse_a();
        wait_idle_a();
        repeat (5) @(posedge dst_clk_a);
        assert (received_a == expected_a)
            else $fatal(1, "A 忙时事件未被正确拒绝");
        assert (src_protocol_error_a)
            else $fatal(1, "A 忙时重复事件未置协议错误");

        // 空闲时协调复位应清除错误，且不得产生虚假目标事件。
        count_before_reset = received_a;
        src_rst_a = 1'b1;
        dst_rst_a = 1'b1;
        repeat (5) @(posedge src_clk_a);
        repeat (5) @(posedge dst_clk_a);
        src_rst_a = 1'b0;
        dst_rst_a = 1'b0;
        repeat (8) @(posedge dst_clk_a);
        assert (!src_busy_a && !src_protocol_error_a && received_a == count_before_reset)
            else $fatal(1, "A 空闲协调复位行为错误");

        // 目标时钟暂停时请求保持，恢复后只接收一次。
        @(negedge dst_clk_a);
        dst_clk_en_a = 1'b0;
        expected_a = received_a + 1;
        pulse_a();
        repeat (8) @(posedge src_clk_a);
        assert (src_busy_a && received_a == (expected_a - 1))
            else $fatal(1, "A 目标时钟暂停期间请求状态错误");
        dst_clk_en_a = 1'b1;
        wait_idle_a();
        assert (received_a == expected_a)
            else $fatal(1, "A 目标时钟恢复后事件丢失或重复");

        // 源时钟暂停后目标域仍可接收，确认须待源时钟恢复后解除 busy。
        expected_a = expected_a + 1;
        pulse_a();
        @(negedge src_clk_a);
        src_clk_en_a = 1'b0;
        repeat (12) @(posedge dst_clk_a);
        assert (received_a == expected_a && src_busy_a)
            else $fatal(1, "A 源时钟暂停测试失败");
        src_clk_en_a = 1'b1;
        wait_idle_a();

        // 忙时同时复位两侧：在途事件被系统初始化丢弃，之后不得出现虚假事件。
        @(negedge dst_clk_a);
        dst_clk_en_a = 1'b0;
        pulse_a();
        assert (src_busy_a) else $fatal(1, "A 忙时复位前未进入忙状态");
        src_rst_a = 1'b1;
        dst_rst_a = 1'b1;
        dst_clk_en_a = 1'b1;
        repeat (5) @(posedge src_clk_a);
        repeat (5) @(posedge dst_clk_a);
        count_before_reset = received_a;
        src_rst_a = 1'b0;
        dst_rst_a = 1'b0;
        repeat (8) @(posedge dst_clk_a);
        assert (!src_busy_a && !src_protocol_error_a && received_a == count_before_reset)
            else $fatal(1, "A 忙时协调复位产生虚假事件或状态未清除");

        // 100 MHz 到约 30 MHz，使用三级同步链。
        expected_b = received_b;
        for (index = 0; index < 16; index = index + 1) begin
            expected_b = expected_b + 1;
            pulse_b();
            wait_idle_b();
        end
        assert (received_b == expected_b && !src_protocol_error_b)
            else $fatal(1, "B 快到慢事件测试失败");

        // 非整数频率比长期运行，使请求 toggle 多次往返翻转。
        expected_c = received_c;
        for (index = 0; index < 100; index = index + 1) begin
            expected_c = expected_c + 1;
            pulse_c();
            wait_idle_c();
        end
        assert (received_c == expected_c && !src_protocol_error_c)
            else $fatal(1, "C 非整数频率比长期测试失败");

        $display("TEST PASSED: A=%0d, B=%0d, C=%0d", received_a, received_b, received_c);
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "全局仿真超时");
    end

endmodule

`default_nettype wire
