#include "hmi_measure_app.h"

#include "bram_map.h"

#include <stdio.h>

#include "sleep.h"
#include "xil_io.h"
#include "xparameters.h"
#include "xstatus.h"
#include "xuartps.h"

#define TIME_BRAM_BASEADDR       XPAR_AXI_BRAM_CTRL_0_S_AXI_BASEADDR
#define SPEC_BRAM_BASEADDR       XPAR_AXI_BRAM_CTRL_1_S_AXI_BASEADDR
#define MEASURE_CTRL_BASEADDR    XPAR_HMI_MEASURE_CTRL_AXI_0_BASEADDR

#define CTRL_OFFSET              0x00U
#define STATUS_OFFSET            0x04U
#define CTRL_START               0x00000001U
#define STATUS_BUSY              0x00000001U
#define STATUS_DONE              0x00000002U
#define STATUS_ERROR             0x00000004U

#define ADC_SAMPLE_RATE_HZ       32000000U
#define HMI_BAUD_RATE            9600U
#define HMI_PLOT_WIDTH           480U
#define HMI_PLOT_HEIGHT          230U
#define TIME_AXIS_LABEL_COUNT    11U
#define COPY_TIMEOUT_US          100000U
#define HMI_ADDT_TIMEOUT_US      1000000U

/*
 * Current COE calibration: one ADC/FFT raw code represents 1 mV.
 * Replace this constant (or the conversion functions) after real calibration.
 */
#define CALIBRATION_UV_PER_CODE  1000U

#define NEXTION_TOUCH            0x65U
#define NEXTION_ADDT_READY       0xFEU
#define NEXTION_ADDT_FINISHED    0xFDU
#define NEXTION_END              0xFFU

#define PAGE_HOME                0U
#define PAGE_TIME                1U
#define PAGE_SPECTRUM            2U

#define COMP_HOME_START          0x01U
#define COMP_TIME_MEASURE        0x16U
#define COMP_TIME_ONE_PERIOD     0x17U
#define COMP_TIME_THREE_PERIODS  0x18U
#define COMP_TIME_TO_SPECTRUM    0x19U
#define COMP_SPEC_MEASURE        0x16U
#define COMP_SPEC_TO_TIME        0x18U

typedef struct {
    u32 vpp_raw;
    u32 vrms_sq_raw;
    u32 f1_hz;
    u32 sample_count;
    u32 peak_count;
    u32 peak_freq_hz[3];
    u32 peak_amp_raw[3];
    u32 spectrum_count;
    u32 valid;
} MeasurementHeader;

static XUartPs HmiUart;
static u8 RxFrame[7];
static u32 RxIndex;
static MeasurementHeader Header;

static volatile u32 *const TimeBram =
    (volatile u32 *)TIME_BRAM_BASEADDR;
static volatile u32 *const SpectrumBram =
    (volatile u32 *)SPEC_BRAM_BASEADDR;

static void hmi_send_bytes(const u8 *data, u32 length)
{
    u32 sent = 0U;

    while (sent < length) {
        sent += XUartPs_Send(&HmiUart, (u8 *)&data[sent], length - sent);
    }
    while (XUartPs_IsSending(&HmiUart) != 0U) {
        /* Wait until the final byte has left UART1. */
    }
}

static void hmi_send_command(const char *command)
{
    static const u8 terminator[3] = {
        NEXTION_END, NEXTION_END, NEXTION_END
    };
    u32 length = 0U;

    while (command[length] != '\0')
        ++length;

    hmi_send_bytes((const u8 *)command, length);
    hmi_send_bytes(terminator, sizeof(terminator));
}

static void hmi_set_text(const char *object_name, const char *text)
{
    char command[96];

    (void)snprintf(command, sizeof(command), "%s.txt=\"%s\"",
                   object_name, text);
    hmi_send_command(command);
}

static void hmi_clear_curve(void)
{
    hmi_send_command("cle s0.id,0");
}

static int hmi_wait_return_code(u8 expected_code)
{
    u32 elapsed_us;
    u32 match_index = 0U;
    const u8 expected_frame[4] = {
        expected_code, NEXTION_END, NEXTION_END, NEXTION_END
    };

    for (elapsed_us = 0U;
         elapsed_us < HMI_ADDT_TIMEOUT_US;
         elapsed_us += 100U) {
        u8 byte;

        while (XUartPs_Recv(&HmiUart, &byte, 1U) == 1U) {
            if (byte == expected_frame[match_index]) {
                ++match_index;
                if (match_index == sizeof(expected_frame))
                    return XST_SUCCESS;
            } else {
                match_index = (byte == expected_frame[0]) ? 1U : 0U;
            }
        }
        usleep(100U);
    }
    return XST_FAILURE;
}

static int hmi_stream_curve(const u8 *points, u32 point_count)
{
    char command[40];

    hmi_clear_curve();
    (void)snprintf(command, sizeof(command), "addt s0.id,0,%lu",
                   (unsigned long)point_count);
    hmi_send_command(command);

    if (hmi_wait_return_code(NEXTION_ADDT_READY) != XST_SUCCESS)
        return XST_FAILURE;

    /*
     * addt data is a raw byte stream.  It has no 0xFF command terminator;
     * exactly point_count bytes must be transmitted.
     */
    hmi_send_bytes(points, point_count);

    return hmi_wait_return_code(NEXTION_ADDT_FINISHED);
}

static u64 integer_sqrt_u64(u64 value)
{
    u64 result = 0ULL;
    u64 bit = 1ULL << 62;

    while (bit > value)
        bit >>= 2;

    while (bit != 0ULL) {
        if (value >= result + bit) {
            value -= result + bit;
            result = (result >> 1) + bit;
        } else {
            result >>= 1;
        }
        bit >>= 2;
    }
    return result;
}

static void format_voltage_raw(char *text, u32 text_size, u32 raw)
{
    u64 microvolts = (u64)raw * (u64)CALIBRATION_UV_PER_CODE;
    u32 volts = (u32)(microvolts / 1000000ULL);
    u32 fraction_1e4 = (u32)((microvolts % 1000000ULL) / 100ULL);

    (void)snprintf(text, text_size, "%lu.%04lu V",
                   (unsigned long)volts, (unsigned long)fraction_1e4);
}

static void format_vrms(char *text, u32 text_size, u32 vrms_sq_raw)
{
    u64 scale_sq =
        (u64)CALIBRATION_UV_PER_CODE * (u64)CALIBRATION_UV_PER_CODE;
    u64 microvolts = integer_sqrt_u64((u64)vrms_sq_raw * scale_sq);
    u32 volts = (u32)(microvolts / 1000000ULL);
    u32 fraction_1e4 = (u32)((microvolts % 1000000ULL) / 100ULL);

    (void)snprintf(text, text_size, "%lu.%04lu V",
                   (unsigned long)volts, (unsigned long)fraction_1e4);
}

static void format_frequency(char *text, u32 text_size, u32 frequency_hz)
{
    (void)snprintf(text, text_size, "%lu Hz",
                   (unsigned long)frequency_hz);
}

static int measurement_read_header(void)
{
    Header.vpp_raw = TimeBram[T_VPP_RAW];
    Header.vrms_sq_raw = TimeBram[T_VRMS_SQ_RAW];
    Header.f1_hz = TimeBram[T_F1_HZ];
    Header.sample_count = TimeBram[T_SAMPLE_COUNT];

    Header.peak_count = SpectrumBram[S_PEAK_COUNT];
    Header.peak_freq_hz[0] = SpectrumBram[S_F1_HZ];
    Header.peak_amp_raw[0] = SpectrumBram[S_A1_RAW];
    Header.peak_freq_hz[1] = SpectrumBram[S_F2_HZ];
    Header.peak_amp_raw[1] = SpectrumBram[S_A2_RAW];
    Header.peak_freq_hz[2] = SpectrumBram[S_F3_HZ];
    Header.peak_amp_raw[2] = SpectrumBram[S_A3_RAW];
    Header.spectrum_count = SpectrumBram[S_SPECTRUM_COUNT];

    Header.valid =
        (Header.sample_count == TIME_SAMPLE_COUNT) &&
        (Header.spectrum_count == SPEC_POINT_COUNT) &&
        (Header.peak_count <= 3U) &&
        (Header.f1_hz != 0U);

    return (Header.valid != 0U) ? XST_SUCCESS : XST_FAILURE;
}

static int measurement_start_and_wait(void)
{
    u32 elapsed_us;
    u32 status;

    Xil_Out32(MEASURE_CTRL_BASEADDR + CTRL_OFFSET, CTRL_START);

    for (elapsed_us = 0U; elapsed_us < COPY_TIMEOUT_US; ++elapsed_us) {
        status = Xil_In32(MEASURE_CTRL_BASEADDR + STATUS_OFFSET);
        if ((status & STATUS_ERROR) != 0U)
            return XST_FAILURE;
        if (((status & STATUS_DONE) != 0U) &&
            ((status & STATUS_BUSY) == 0U)) {
            return measurement_read_header();
        }
        usleep(1U);
    }
    return XST_FAILURE;
}

static u32 find_rising_zero_crossing(void)
{
    u32 index;
    s16 previous = time_sample_at(TimeBram, 0U);

    for (index = 1U; index < Header.sample_count; ++index) {
        s16 current = time_sample_at(TimeBram, index);
        if ((previous <= 0) && (current > 0))
            return index;
        previous = current;
    }
    return 0U;
}

static void hmi_draw_time_axis(u32 cycles)
{
    u64 total_us_tenths;
    u32 label;

    if (Header.f1_hz == 0U)
        return;

    total_us_tenths =
        ((u64)cycles * 10000000ULL + (Header.f1_hz / 2U)) /
        Header.f1_hz;

    for (label = 0U; label < TIME_AXIS_LABEL_COUNT; ++label) {
        char object_name[20];
        char text[24];
        u64 value_tenths =
            (total_us_tenths * label + ((TIME_AXIS_LABEL_COUNT - 1U) / 2U)) /
            (TIME_AXIS_LABEL_COUNT - 1U);

        (void)snprintf(object_name, sizeof(object_name), "page1.t%lu",
                       (unsigned long)(11U + label));
        (void)snprintf(text, sizeof(text), "%lu.%01lu us",
                       (unsigned long)(value_tenths / 10ULL),
                       (unsigned long)(value_tenths % 10ULL));
        hmi_set_text(object_name, text);
    }
}

static void hmi_draw_time_waveform(u32 cycles)
{
    s16 samples[HMI_PLOT_WIDTH];
    u8 pixels[HMI_PLOT_WIDTH];
    u32 start;
    u32 period_samples;
    u32 span_samples;
    u32 point;
    s32 minimum = 32767;
    s32 maximum = -32768;

    if ((Header.valid == 0U) || (Header.f1_hz == 0U))
        return;

    start = find_rising_zero_crossing();
    period_samples =
        (ADC_SAMPLE_RATE_HZ + (Header.f1_hz / 2U)) / Header.f1_hz;
    if (period_samples == 0U)
        period_samples = 1U;

    span_samples = period_samples * cycles;
    if (span_samples < 2U)
        span_samples = 2U;
    if (start >= Header.sample_count - 1U)
        start = 0U;
    if (span_samples > Header.sample_count - start)
        span_samples = Header.sample_count - start;

    for (point = 0U; point < HMI_PLOT_WIDTH; ++point) {
        u64 position_numerator =
            (u64)point * (u64)(span_samples - 1U);
        u32 index = (u32)(position_numerator / (HMI_PLOT_WIDTH - 1U));
        u32 fraction =
            (u32)(position_numerator % (HMI_PLOT_WIDTH - 1U));
        s32 sample0 = time_sample_at(TimeBram, start + index);
        s32 sample1 = sample0;
        s32 sample;

        if (index + 1U < span_samples)
            sample1 = time_sample_at(TimeBram, start + index + 1U);

        sample =
            (sample0 * (s32)((HMI_PLOT_WIDTH - 1U) - fraction) +
             sample1 * (s32)fraction) /
            (s32)(HMI_PLOT_WIDTH - 1U);
        samples[point] = (s16)sample;
        if (sample < minimum)
            minimum = sample;
        if (sample > maximum)
            maximum = sample;
    }

    for (point = 0U; point < HMI_PLOT_WIDTH; ++point) {
        u32 pixel = HMI_PLOT_HEIGHT / 2U;
        if (maximum > minimum) {
            pixel = (u32)(((s32)samples[point] - minimum) *
                          (s32)HMI_PLOT_HEIGHT /
                          (maximum - minimum));
        }
        if (pixel > HMI_PLOT_HEIGHT)
            pixel = HMI_PLOT_HEIGHT;
        pixels[point] = (u8)pixel;
    }
    (void)hmi_stream_curve(pixels, HMI_PLOT_WIDTH);
}

static void hmi_draw_spectrum_waveform(void)
{
    u16 compressed[HMI_PLOT_WIDTH];
    u8 pixels[HMI_PLOT_WIDTH];
    u32 point;
    u32 global_max = 0U;

    if (Header.valid == 0U)
        return;

    for (point = 0U; point < HMI_PLOT_WIDTH; ++point) {
        u32 first = (point * Header.spectrum_count) / HMI_PLOT_WIDTH;
        u32 last =
            ((point + 1U) * Header.spectrum_count) / HMI_PLOT_WIDTH;
        u32 source;
        u16 interval_max = 0U;

        if (last <= first)
            last = first + 1U;
        if (last > Header.spectrum_count)
            last = Header.spectrum_count;

        for (source = first; source < last; ++source) {
            u16 value = spectrum_point_at(SpectrumBram, source);
            if (value > interval_max)
                interval_max = value;
        }
        compressed[point] = interval_max;
        if (interval_max > global_max)
            global_max = interval_max;
    }

    for (point = 0U; point < HMI_PLOT_WIDTH; ++point) {
        u32 pixel = 0U;
        if (global_max != 0U) {
            pixel = ((u32)compressed[point] * HMI_PLOT_HEIGHT) /
                    global_max;
        }
        if (pixel > HMI_PLOT_HEIGHT)
            pixel = HMI_PLOT_HEIGHT;
        pixels[point] = (u8)pixel;
    }
    (void)hmi_stream_curve(pixels, HMI_PLOT_WIDTH);
}

static void hmi_show_time_values(void)
{
    char text[32];

    format_voltage_raw(text, sizeof(text), Header.vpp_raw);
    hmi_set_text("page1.t32", text);
    format_vrms(text, sizeof(text), Header.vrms_sq_raw);
    hmi_set_text("page1.t33", text);
    format_frequency(text, sizeof(text), Header.f1_hz);
    hmi_set_text("page1.t34", text);
}

static void hmi_show_spectrum_values(void)
{
    char text[32];
    u32 peak;

    for (peak = 0U; peak < 3U; ++peak) {
        char object_name[20];
        u32 amplitude =
            (peak < Header.peak_count) ? Header.peak_amp_raw[peak] : 0U;

        format_voltage_raw(text, sizeof(text), amplitude);
        (void)snprintf(object_name, sizeof(object_name), "page2.t%lu",
                       (unsigned long)(32U + peak));
        hmi_set_text(object_name, text);
    }
}

static void hmi_show_error(u32 page)
{
    if (page == PAGE_SPECTRUM) {
        hmi_set_text("page2.t32", "DATA ERROR");
        hmi_set_text("page2.t33", "--");
        hmi_set_text("page2.t34", "--");
    } else {
        hmi_set_text("page1.t32", "DATA ERROR");
        hmi_set_text("page1.t33", "--");
        hmi_set_text("page1.t34", "--");
    }
}

static void measure_and_show_time(void)
{
    if (measurement_start_and_wait() != XST_SUCCESS) {
        Header.valid = 0U;
        hmi_show_error(PAGE_TIME);
        return;
    }
    hmi_show_time_values();
    hmi_draw_time_axis(1U);
    hmi_draw_time_waveform(1U);
}

static void measure_and_show_spectrum(void)
{
    if (measurement_start_and_wait() != XST_SUCCESS) {
        Header.valid = 0U;
        hmi_show_error(PAGE_SPECTRUM);
        return;
    }
    hmi_show_spectrum_values();
    hmi_draw_spectrum_waveform();
}

static void hmi_handle_touch(u8 page, u8 component, u8 event)
{
    if (event != 0U)
        return;

    if ((page == PAGE_HOME) && (component == COMP_HOME_START)) {
        measure_and_show_time();
    } else if ((page == PAGE_TIME) &&
               (component == COMP_TIME_MEASURE)) {
        measure_and_show_time();
    } else if ((page == PAGE_TIME) &&
               (component == COMP_TIME_ONE_PERIOD)) {
        if ((Header.valid != 0U) ||
            (measurement_read_header() == XST_SUCCESS)) {
            hmi_show_time_values();
            hmi_draw_time_axis(1U);
            hmi_draw_time_waveform(1U);
        } else {
            hmi_show_error(PAGE_TIME);
        }
    } else if ((page == PAGE_TIME) &&
               (component == COMP_TIME_THREE_PERIODS)) {
        if ((Header.valid != 0U) ||
            (measurement_read_header() == XST_SUCCESS)) {
            hmi_show_time_values();
            hmi_draw_time_axis(3U);
            hmi_draw_time_waveform(3U);
        } else {
            hmi_show_error(PAGE_TIME);
        }
    } else if ((page == PAGE_TIME) &&
               (component == COMP_TIME_TO_SPECTRUM)) {
        if ((Header.valid != 0U) ||
            (measurement_read_header() == XST_SUCCESS)) {
            hmi_show_spectrum_values();
            hmi_draw_spectrum_waveform();
        } else {
            hmi_show_error(PAGE_SPECTRUM);
        }
    } else if ((page == PAGE_SPECTRUM) &&
               (component == COMP_SPEC_MEASURE)) {
        measure_and_show_spectrum();
    } else if ((page == PAGE_SPECTRUM) &&
               (component == COMP_SPEC_TO_TIME)) {
        if ((Header.valid != 0U) ||
            (measurement_read_header() == XST_SUCCESS)) {
            hmi_show_time_values();
            hmi_draw_time_axis(1U);
            hmi_draw_time_waveform(1U);
        } else {
            hmi_show_error(PAGE_TIME);
        }
    }
}

static void hmi_consume_byte(u8 byte)
{
    if (RxIndex == 0U) {
        if (byte == NEXTION_TOUCH)
            RxFrame[RxIndex++] = byte;
        return;
    }

    RxFrame[RxIndex++] = byte;
    if (RxIndex < sizeof(RxFrame))
        return;

    if ((RxFrame[4] == NEXTION_END) &&
        (RxFrame[5] == NEXTION_END) &&
        (RxFrame[6] == NEXTION_END)) {
        hmi_handle_touch(RxFrame[1], RxFrame[2], RxFrame[3]);
    }
    RxIndex = 0U;
}

int HmiMeasureApp_Init(void)
{
    XUartPs_Config *config;
    int status;

    config = XUartPs_LookupConfig(XPAR_PS7_UART_1_DEVICE_ID);
    if (config == NULL)
        return XST_FAILURE;

    status = XUartPs_CfgInitialize(&HmiUart, config, config->BaseAddress);
    if (status != XST_SUCCESS)
        return status;

    status = XUartPs_SetBaudRate(&HmiUart, HMI_BAUD_RATE);
    if (status != XST_SUCCESS)
        return status;

    XUartPs_SetOperMode(&HmiUart, XUARTPS_OPER_MODE_NORMAL);
    RxIndex = 0U;
    Header.valid = 0U;

    /*
     * Disable Nextion command acknowledgements. Touch event packets are still
     * returned, while 0x01/0x00 command-response bytes cannot disturb parsing.
     */
    hmi_send_command("bkcmd=0");
    return XST_SUCCESS;
}

void HmiMeasureApp_Service(void)
{
    u8 byte;

    while (XUartPs_Recv(&HmiUart, &byte, 1U) == 1U)
        hmi_consume_byte(byte);

    usleep(1000U);
}
