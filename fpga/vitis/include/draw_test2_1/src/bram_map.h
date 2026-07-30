#ifndef BRAM_MAP_H
#define BRAM_MAP_H

#include "xil_types.h"

#define TIME_SAMPLE_COUNT 32768U
#define SPEC_POINT_COUNT  1024U

enum time_bram_word {
    T_VPP_RAW = 0,
    T_VRMS_SQ_RAW = 1,
    T_F1_HZ = 2,
    T_SAMPLE_COUNT = 3,
    T_DATA_BASE = 4,
    T_DATA_WORDS = TIME_SAMPLE_COUNT / 2U,
    T_TOTAL_WORDS = T_DATA_BASE + T_DATA_WORDS
};

enum spectrum_bram_word {
    S_PEAK_COUNT = 0,
    S_F1_HZ = 1,
    S_A1_RAW = 2,
    S_F2_HZ = 3,
    S_A2_RAW = 4,
    S_F3_HZ = 5,
    S_A3_RAW = 6,
    S_SPECTRUM_COUNT = 7,
    S_DATA_BASE = 8,
    S_DATA_WORDS = SPEC_POINT_COUNT / 2U,
    S_TOTAL_WORDS = S_DATA_BASE + S_DATA_WORDS
};

static inline s16 time_sample_at(
    const volatile u32 *time_bram,
    u32 sample_index)
{
    u32 word = time_bram[T_DATA_BASE + (sample_index >> 1)];

    if ((sample_index & 1U) == 0U)
        return (s16)(word & 0xFFFFU);
    return (s16)(word >> 16);
}

static inline u16 spectrum_point_at(
    const volatile u32 *spectrum_bram,
    u32 point_index)
{
    u32 word = spectrum_bram[S_DATA_BASE + (point_index >> 1)];

    if ((point_index & 1U) == 0U)
        return (u16)(word & 0xFFFFU);
    return (u16)(word >> 16);
}

#endif
