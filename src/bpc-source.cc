// -*- mode: c++; c-basic-offset: 2; indent-tabs-mode: nil; -*-
// Part of txtempus, a LF time signal transmitter.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

#include "time-signal-source.h"

// =============================  EXPERIMENTAL  ================================
// BPC is China's longwave time signal (National Time Service Center, Shangqiu),
// carrier 68.5 kHz. Unlike the other stations here it uses QUATERNARY
// pulse-width amplitude modulation:
//
//   * Each second the carrier is reduced (to ~10%) for the first part of the
//     second; the reduction DURATION encodes one base-4 symbol (two bits):
//         100 ms -> 0,  200 ms -> 1,  300 ms -> 2,  400 ms -> 3
//     The remainder of the second is full carrier.
//   * The frame is 20 seconds long and is transmitted THREE times per minute
//     (blocks starting at :00, :20, :40). Each block encodes the time at the
//     start of that block; a 2-bit "frame number" says which block it is.
//   * Second 0 of each block is a reference marker: no amplitude reduction.
//
// The carrier/timing/modulation MECHANISM above is well documented. The exact
// mapping of time fields to bit positions, however, is reverse-engineered (the
// official BPC format is not openly published). The layout below is a TENTATIVE
// best-effort and is intentionally isolated in EncodeBlock() so it is easy to
// correct. VERIFY against the spec or a real BPC receiver before trusting it.
// ============================================================================

namespace {
// Place 'value' into 'width' bits of 'v', with the field's least-significant
// bit at position 'lsb' (bit 0 = LSB).
inline void put_bits(uint64_t &v, int lsb, int width, unsigned value) {
  const uint64_t mask = (width >= 64) ? ~0ULL : ((1ULL << width) - 1);
  v |= (static_cast<uint64_t>(value) & mask) << lsb;
}

inline unsigned popcount_parity(uint64_t x) {
  unsigned p = 0;
  while (x) { p ^= 1u; x &= (x - 1); }
  return p;
}

// Encode the 38 data bits (symbols P1..P19, two bits each, big-endian: P1 is
// bits 37..36, P19 is bits 1..0) for the block whose start time is 'tm', with
// frame number 'frame' (0,1,2).
//
// TENTATIVE field layout (see banner above):
//   [37..36] frame number (0..2)
//   [35]     AM/PM (0=AM, 1=PM)
//   [34..31] hour  (1..12, binary)
//   [30..25] minute (0..59, binary)
//   [24..22] weekday (1=Mon .. 7=Sun)
//   [21..17] day of month (1..31)
//   [16..13] month (1..12)
//   [12..06] year (0..99, i.e. 20xx)
//   [05..02] reserved (0)
//   [01]     even parity over bits [37..02]
//   [00]     reserved (0)
uint64_t EncodeBlock(const struct tm &tm, int frame) {
  int hour12 = tm.tm_hour % 12;
  if (hour12 == 0) hour12 = 12;
  const unsigned ampm = (tm.tm_hour >= 12) ? 1 : 0;
  const unsigned weekday = tm.tm_wday == 0 ? 7 : tm.tm_wday;  // Mon..Sun = 1..7

  uint64_t b = 0;
  put_bits(b, 36, 2, frame);
  put_bits(b, 35, 1, ampm);
  put_bits(b, 31, 4, hour12);
  put_bits(b, 25, 6, tm.tm_min);
  put_bits(b, 22, 3, weekday);
  put_bits(b, 17, 5, tm.tm_mday);
  put_bits(b, 13, 4, tm.tm_mon + 1);
  put_bits(b, 6, 7, tm.tm_year % 100);
  // Even parity over the populated data bits [37..2].
  put_bits(b, 1, 1, popcount_parity(b >> 2));
  return b;
}
}  // namespace

void BPCTimeSignalSource::PrepareMinute(time_t t) {
  // Three 20-second blocks; each carries the time at its own start.
  for (int frame = 0; frame < 3; ++frame) {
    const time_t block_start = t + frame * 20;
    struct tm tm;
    localtime_r(&block_start, &tm);
    const uint64_t bits = EncodeBlock(tm, frame);

    const int base = frame * 20;
    symbols_[base + 0] = 0xFF;  // frame reference marker (no reduction)
    for (int p = 1; p <= 19; ++p) {
      const int shift = 2 * (19 - p);  // P1 -> 36 .. P19 -> 0
      symbols_[base + p] = static_cast<uint8_t>((bits >> shift) & 0x3);
    }
  }
}

TimeSignalSource::SecondModulation
BPCTimeSignalSource::GetModulationForSecond(int second) {
  if (second < 0 || second >= 60) second = ((second % 60) + 60) % 60;
  const uint8_t s = symbols_[second];
  if (s == 0xFF)  // marker: carrier stays high for the whole second
    return {{CarrierPower::HIGH, 0}};
  const int width_ms = (s + 1) * 100;  // 0->100ms, 1->200, 2->300, 3->400
  return {{CarrierPower::LOW, width_ms}, {CarrierPower::HIGH, 0}};
}
