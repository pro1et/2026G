#ifndef BRAM_MAP_H
#define BRAM_MAP_H

#include <stdint.h>

#define TIME_SAMPLE_COUNT           32768U
#define SPEC_POINT_COUNT            1024U

enum time_bram_word {
    T_VPP_RAW = 0,
    T_VRMS_SQ_RAW = 1,
    T_F1_HZ = 2,
    T_SAMPLE_COUNT = 3,
    T_DATA_BASE = 4,
    T_DATA_WORDS = TIME_SAMPLE_COUNT / 2,
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
    S_DATA_WORDS = SPEC_POINT_COUNT / 2,
    S_TOTAL_WORDS = S_DATA_BASE + S_DATA_WORDS
};

static inline uint32_t bram_word_byte_offset(uint32_t word)
{
    return word * sizeof(uint32_t);
}

static inline int16_t time_sample_at(
    const volatile uint32_t *time_bram,
    uint32_t sample_index)
{
    uint32_t word = time_bram[T_DATA_BASE + (sample_index >> 1)];
    return (sample_index & 1U) == 0U
        ? (int16_t)(word & UINT32_C(0xFFFF))
        : (int16_t)(word >> 16);
}

static inline uint16_t spectrum_point_at(
    const volatile uint32_t *spectrum_bram,
    uint32_t point_index)
{
    uint32_t word = spectrum_bram[S_DATA_BASE + (point_index >> 1)];
    return (point_index & 1U) == 0U
        ? (uint16_t)(word & UINT32_C(0xFFFF))
        : (uint16_t)(word >> 16);
}

#endif
