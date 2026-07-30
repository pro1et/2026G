`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 模块名称：measurement_bram_writer
//
// 主要功能：
//   将一次测量得到的32位无符号Vpp、32位无符号Vrms和固定点数的16位有符号
//   FIR波形汇总到同一块32位双口BRAM。模块负责输入锁存、波形两点拼接、单写口
//   仲裁、字节地址生成和帧完成通知，不实例化BRAM、AXI接口或中断逻辑。
//
// 使用方法：
//   1. 将所有输入连接到clk域内的测量模块输出。
//   2. 空闲时给出channel_enable，并将start拉高一个clk周期。
//   3. busy拉高后通过对应valid送入本帧数据；单周期valid可被可靠锁存或接收。
//   4. 将bram_*连接到32位True Dual Port BRAM的PL写端，PS从另一端读取。
//   5. frame_done出现后，BRAM中本次启用通道的数据完整有效。
//
// 连接说明：
//   clk/rst          <- 测量数据处理时钟及本时钟域同步复位
//   start            <- 本时钟域测量流程控制器
//   channel_enable   <- 本帧通道选择，bit0/1/2依次对应Vpp/Vrms/波形
//   vpp_*            <- Vpp计算模块
//   vrms_*           <- 有效值计算模块
//   wave_*           <- FIR输出模块
//   busy/frame_done  -> 测量流程控制器或后续AXI状态锁存模块
//   bram_*           -> 32位双口BRAM的PL写端
//
// 时钟与复位：
//   所有端口均属于clk域；异步来源必须在模块外完成CDC。rst为高电平有效同步复位，
//   复位沿后写使能、忙状态、完成脉冲、错误和内部缓存均清零。
//
// 输入格式：
//   vpp_data和vrms_data为32位无符号整数，本模块不执行缩放或饱和。
//   wave_data为16位有符号二进制补码；仅wave_valid为高时计入一个有效样点。
//
// 输出格式：
//   BRAM使用32位数据和字节地址：0x0000为Vpp，0x0004为Vrms，0x0008起为
//   波形。每个波形字低16位为较早样点，高16位为较晚样点。完整写入时
//   bram_en=1且bram_we=4'b1111，其余周期二者为0。
//
// 握手时序：
//   start仅在IDLE接受并锁存channel_enable；busy从接受后的周期开始为高。
//   上游只能在busy为高时发送valid。标量valid被锁存至实际写入，波形每个valid
//   直接接收，奇数序号样点到达时写出一对。写优先级为波形、Vpp、Vrms。
//   所有启用通道完成后先结束最后一次BRAM写，随后frame_done拉高一个clk周期。
//
// 参数说明：
//   WAVE_SAMPLE_COUNT 为启用波形时每帧接收的有效样点数，必须为正偶数。
//   BRAM_ADDR_WIDTH   为BRAM字节地址位宽，必须覆盖最后一个波形字地址。
//
// 错误行为：
//   channel_enable=0的启动请求被拒绝并锁存error。busy期间的新start、同一已启用
//   标量通道在本帧内重复给出valid也会锁存error，但不会破坏当前帧。error仅由
//   rst清除。未启用通道的valid和波形收满后的额外wave_valid均被忽略。
//
// 使用限制：
//   本接口没有输入ready或BRAM背压，BRAM必须能够每clk接受一次写入。输入valid
//   必须与数据对齐；start所在周期不接收测量数据，应在busy有效后再发送。
//   峰值输入吞吐率为每clk一个波形样点，峰值BRAM吞吐率为每clk一个32位字。
//   PS不得在本模块busy期间依赖正在更新地址的读出值。
// ============================================================================

module measurement_bram_writer #(
    parameter int unsigned WAVE_SAMPLE_COUNT = 32768, // 每帧保存的有效波形样点数，必须为正偶数
    parameter int unsigned BRAM_ADDR_WIDTH   = 17     // BRAM字节地址位宽，必须覆盖全部结果
) (
    input  wire logic                       clk,            // 模块工作时钟，所有端口均属于此时钟域
    input  wire logic                       rst,            // 高电平有效同步复位

    input  wire logic                       start,          // 启动单周期脉冲，仅空闲时接受
    input  wire logic [2:0]                 channel_enable, // 通道使能：bit0=Vpp，bit1=Vrms，bit2=波形

    input  wire logic [31:0]                vpp_data,       // 32位无符号Vpp结果，vpp_valid时有效
    input  wire logic                       vpp_valid,      // Vpp结果有效，高电平持续一个或多个周期视为重复输入

    input  wire logic [31:0]                vrms_data,      // 32位无符号Vrms结果，vrms_valid时有效
    input  wire logic                       vrms_valid,     // Vrms结果有效，高电平持续一个或多个周期视为重复输入

    input  wire logic signed [15:0]         wave_data,      // 16位有符号二进制补码波形样点
    input  wire logic                       wave_valid,     // 波形样点有效，每个高电平周期接收一个样点

    output      logic                       busy,           // 正在处理当前帧的状态电平
    output      logic                       frame_done,     // 全部启用通道完成后的单周期脉冲
    output      logic                       vpp_done,       // 本帧Vpp已实际写入BRAM的状态电平
    output      logic                       vrms_done,      // 本帧Vrms已实际写入BRAM的状态电平
    output      logic                       wave_done,      // 本帧波形样点已全部写入BRAM的状态电平
    output      logic                       error,          // 协议错误锁存，仅同步复位清除

    output      logic                       bram_en,        // BRAM端口使能，写周期为高
    output      logic [3:0]                 bram_we,        // BRAM字节写使能，完整写入时为4'b1111
    output      logic [BRAM_ADDR_WIDTH-1:0] bram_addr,      // BRAM字节地址，始终四字节对齐
    output      logic [31:0]                bram_wrdata     // BRAM写数据
);

    localparam int unsigned SAMPLE_INDEX_WIDTH =
        (WAVE_SAMPLE_COUNT <= 2) ? 1 : $clog2(WAVE_SAMPLE_COUNT);
    localparam logic [SAMPLE_INDEX_WIDTH-1:0] LAST_SAMPLE_INDEX =
        SAMPLE_INDEX_WIDTH'(WAVE_SAMPLE_COUNT - 1);
    localparam longint unsigned LAST_BYTE_ADDRESS =
        ((WAVE_SAMPLE_COUNT / 2) + 1) * 4;

    typedef enum logic [1:0] {
        STATE_IDLE,
        STATE_CAPTURE,
        STATE_FINISH
    } state_t;

    state_t state;

    logic [2:0] active_mask;
    logic [31:0] vpp_reg;
    logic [31:0] vrms_reg;
    logic        vpp_pending;
    logic        vrms_pending;
    logic [15:0] sample_hold;
    logic [SAMPLE_INDEX_WIDTH-1:0] sample_index;

    logic wave_write_fire;
    logic vpp_write_fire;
    logic vrms_write_fire;
    logic all_enabled_channels_done;
    logic [BRAM_ADDR_WIDTH-1:0] wave_byte_addr;

    initial begin
        assert (WAVE_SAMPLE_COUNT > 0)
            else $fatal(1, "WAVE_SAMPLE_COUNT必须大于0");
        assert ((WAVE_SAMPLE_COUNT % 2) == 0)
            else $fatal(1, "WAVE_SAMPLE_COUNT必须为偶数");
        assert (BRAM_ADDR_WIDTH > 0 && LAST_BYTE_ADDRESS < (64'(1) << BRAM_ADDR_WIDTH))
            else $fatal(1, "BRAM_ADDR_WIDTH不足以覆盖最后一个波形字地址");
    end

    always_comb begin
        busy       = (state == STATE_CAPTURE);
        frame_done = (state == STATE_FINISH);

        all_enabled_channels_done =
            (!active_mask[0] || vpp_done) &&
            (!active_mask[1] || vrms_done) &&
            (!active_mask[2] || wave_done);

        wave_write_fire = !rst
                       && (state == STATE_CAPTURE)
                       && active_mask[2]
                       && !wave_done
                       && wave_valid
                       && sample_index[0];
        vpp_write_fire  = !wave_write_fire
                       && (state == STATE_CAPTURE)
                       && vpp_pending;
        vrms_write_fire = !wave_write_fire
                       && !vpp_write_fire
                       && (state == STATE_CAPTURE)
                       && vrms_pending;

        // 内部按32位字编号计算，出口统一转换为BRAM Controller字节地址。
        wave_byte_addr = BRAM_ADDR_WIDTH'(
            (2 + (sample_index >> 1)) << 2);

        bram_en     = 1'b0;
        bram_we     = 4'b0000;
        bram_addr   = '0;
        bram_wrdata = 32'd0;

        if (wave_write_fire) begin
            bram_en     = 1'b1;
            bram_we     = 4'b1111;
            bram_addr   = wave_byte_addr;
            bram_wrdata = {wave_data[15:0], sample_hold};
        end else if (vpp_write_fire) begin
            bram_en     = 1'b1;
            bram_we     = 4'b1111;
            bram_addr   = BRAM_ADDR_WIDTH'(0);
            bram_wrdata = vpp_reg;
        end else if (vrms_write_fire) begin
            bram_en     = 1'b1;
            bram_we     = 4'b1111;
            bram_addr   = BRAM_ADDR_WIDTH'(4);
            bram_wrdata = vrms_reg;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state        <= STATE_IDLE;
            active_mask  <= 3'b000;
            vpp_reg      <= 32'd0;
            vrms_reg     <= 32'd0;
            vpp_pending  <= 1'b0;
            vrms_pending <= 1'b0;
            sample_hold  <= 16'd0;
            sample_index <= '0;
            vpp_done     <= 1'b0;
            vrms_done    <= 1'b0;
            wave_done    <= 1'b0;
            error        <= 1'b0;
        end else begin
            unique case (state)
                STATE_IDLE: begin
                    if (start) begin
                        if (channel_enable == 3'b000) begin
                            error <= 1'b1;
                        end else begin
                            active_mask  <= channel_enable;
                            vpp_pending  <= 1'b0;
                            vrms_pending <= 1'b0;
                            sample_hold  <= 16'd0;
                            sample_index <= '0;
                            vpp_done     <= 1'b0;
                            vrms_done    <= 1'b0;
                            wave_done    <= 1'b0;
                            state        <= STATE_CAPTURE;
                        end
                    end
                end

                STATE_CAPTURE: begin
                    if (start) begin
                        // 当前帧继续运行，但记录上层在忙期间错误重复启动。
                        error <= 1'b1;
                    end

                    if (active_mask[0] && vpp_valid) begin
                        if (vpp_pending || vpp_done) begin
                            error <= 1'b1;
                        end else begin
                            vpp_reg     <= vpp_data;
                            vpp_pending <= 1'b1;
                        end
                    end

                    if (active_mask[1] && vrms_valid) begin
                        if (vrms_pending || vrms_done) begin
                            error <= 1'b1;
                        end else begin
                            vrms_reg     <= vrms_data;
                            vrms_pending <= 1'b1;
                        end
                    end

                    if (active_mask[2] && wave_valid && !wave_done) begin
                        if (!sample_index[0]) begin
                            sample_hold <= wave_data[15:0];
                        end

                        if (sample_index == LAST_SAMPLE_INDEX) begin
                            sample_index <= '0;
                            wave_done    <= 1'b1;
                        end else begin
                            sample_index <= sample_index + 1'b1;
                        end
                    end

                    if (vpp_write_fire) begin
                        vpp_pending <= 1'b0;
                        vpp_done    <= 1'b1;
                    end

                    if (vrms_write_fire) begin
                        vrms_pending <= 1'b0;
                        vrms_done    <= 1'b1;
                    end

                    // 完成标志在实际写入沿后更新，因此此转移至少晚于最后一次BRAM写一拍。
                    if (all_enabled_channels_done) begin
                        state <= STATE_FINISH;
                    end
                end

                STATE_FINISH: begin
                    state <= STATE_IDLE;
                end

                default: begin
                    state        <= STATE_IDLE;
                    active_mask  <= 3'b000;
                    vpp_pending  <= 1'b0;
                    vrms_pending <= 1'b0;
                    sample_index <= '0;
                    error        <= 1'b1;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
