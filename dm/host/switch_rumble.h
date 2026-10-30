// HD Rumble as a Switch sends it to a Pro Controller or a Joy-Con (nxnative refreshed): each motor's VibrationValue, two bands of a frequency and an amplitude, in the
// controller's own four bytes, and when to send them. Shared by the Mac host's rumble (haptics_apple.m) and the settings window's Test page (dm/mac/launcher_bridge.m).
// Encoding: dekuNukem's Nintendo_Switch_Reverse_Engineering, rumble_data_table.md, as Linux's hid-nintendo and SDL send it. A frequency's code is round(32 log2(f / 10));
// the high band carries (code - 0x60) * 4 (81.75 to 1252.57 Hz) and the low band code - 0x40 (40.88 to 626.28 Hz). An amplitude's code (0 to 100) is the nearest entry of
// sr_amp_table, which stops at 1.003, the actuators' safe limit; the high band carries code * 2, the low band 0x40 + code / 2, with 0x80 on byte 2 for an odd code.
// Bytes: high frequency's low byte; high amplitude | its 9th bit; low frequency | the low amplitude's half step; low amplitude. 00 01 40 40 is neutral (320 Hz, 160 Hz, silent).
// Pacing, as SDL and hid-nintendo learned it: a report at most every SR_MIN_NS (faster ones can turn a Bluetooth controller off), a rumble that has not changed again every
// SR_REFRESH_NS (the motors stop otherwise), SR_ZEROS neutral reports once it stops. A Switch sends every 15 ms, packing the game's 5 ms steps; a Mac's Bluetooth stack gives
// no such slot, so between two reports the stronger of the values the game set goes first and the latest follows: a short impact is late by up to 30 ms, never lost.
#pragma once
#include <math.h>
#include <stdint.h>
#include <string.h>
#include "hle_haptics.h"

enum { SR_MIN_NS = 30000000, SR_REFRESH_NS = 50000000, SR_ZEROS = 5 };
static const float sr_amp_table[101] = {
    0.000000f, 0.007843f, 0.011823f, 0.014061f, 0.016720f, 0.019885f, 0.023648f, 0.028123f, 0.033442f, 0.039771f, 0.047296f, 0.056246f, 0.066886f,
    0.079542f, 0.094592f, 0.112491f, 0.117471f, 0.122671f, 0.128102f, 0.133774f, 0.139697f, 0.145882f, 0.152341f, 0.159085f, 0.166129f, 0.173484f,
    0.181166f, 0.189185f, 0.197561f, 0.206308f, 0.215442f, 0.224982f, 0.229908f, 0.234943f, 0.240087f, 0.245345f, 0.250715f, 0.256206f, 0.261816f,
    0.267549f, 0.273407f, 0.279394f, 0.285514f, 0.291765f, 0.298154f, 0.304681f, 0.311353f, 0.318171f, 0.325138f, 0.332258f, 0.339534f, 0.346969f,
    0.354566f, 0.362331f, 0.370265f, 0.378372f, 0.386657f, 0.395124f, 0.403777f, 0.412619f, 0.421652f, 0.430885f, 0.440321f, 0.449964f, 0.459817f,
    0.469885f, 0.480174f, 0.490689f, 0.501433f, 0.512413f, 0.523633f, 0.535100f, 0.546816f, 0.558790f, 0.571027f, 0.583530f, 0.596307f, 0.609365f,
    0.622708f, 0.636344f, 0.650279f, 0.664518f, 0.679069f, 0.693939f, 0.709133f, 0.724662f, 0.740529f, 0.756745f, 0.773316f, 0.790249f, 0.807554f,
    0.825237f, 0.843307f, 0.861772f, 0.880643f, 0.899928f, 0.919633f, 0.939771f, 0.960348f, 0.981378f, 1.002867f,
};
static const uint8_t sr_neutral[4] = {0x00, 0x01, 0x40, 0x40};
static inline int sr_amp_code(float a) {   // the nearest table entry; 0 for silence or no number, 100 at or past the safe limit
    if (!(a > 0)) return 0;
    if (a >= sr_amp_table[100]) return 100;
    int lo = 0, hi = 100;   // sr_amp_table[lo] <= a < sr_amp_table[hi]
    while (hi - lo > 1) { int mid = (lo + hi) / 2; if (sr_amp_table[mid] <= a) lo = mid; else hi = mid; }
    return a - sr_amp_table[lo] < sr_amp_table[hi] - a ? lo : hi;
}
static inline int sr_freq_code(float f, int lo, int hi) {   // round(32 log2(f / 10)) within a band's codes
    int e = isfinite(f) && f > 0 ? (int)lrintf(log2f(f / 10.f) * 32.f) : lo;
    return e < lo ? lo : e > hi ? hi : e;
}
static inline void sr_encode(const dm_vibration *v, uint8_t out[4]) {
    int ha = sr_amp_code(v->amplitude_high), la = sr_amp_code(v->amplitude_low);
    if (!ha && !la) { memcpy(out, sr_neutral, 4); return; }
    int hf = (sr_freq_code(v->frequency_high, 0x61, 0xDF) - 0x60) * 4, lf = sr_freq_code(v->frequency_low, 0x41, 0xBF) - 0x40;
    out[0] = (uint8_t)(hf & 0xFF);
    out[1] = (uint8_t)(ha * 2 | (hf >> 8 & 0x01));
    out[2] = (uint8_t)(lf | (la & 1 ? 0x80 : 0));
    out[3] = (uint8_t)(0x40 + la / 2);
}
// The frequency and amplitude a band's bytes play (for the Test page and the tests): the inverse of sr_encode, on the codes' grid
static inline void sr_decode(const uint8_t in[4], dm_vibration *v) {
    int hf = in[0] | (in[1] & 1) << 8, ha = in[1] >> 1, lf = in[2] & 0x7F, la = (in[3] - 0x40) * 2 + (in[2] >> 7);
    v->frequency_high = 10.f * exp2f((hf / 4 + 0x60) / 32.f); v->frequency_low = 10.f * exp2f((lf + 0x40) / 32.f);
    v->amplitude_high = ha >= 0 && ha <= 100 ? sr_amp_table[ha] : 0; v->amplitude_low = la >= 0 && la <= 100 ? sr_amp_table[la] : 0;
}
// One motor for a controller with one actuator (a single Joy-Con): each band at the stronger motor's frequency, with the louder of the two amplitudes
static inline dm_vibration sr_mix(dm_vibration a, dm_vibration b) {
    dm_vibration m = a;
    if (b.amplitude_low > a.amplitude_low) { m.amplitude_low = b.amplitude_low; m.frequency_low = b.frequency_low; }
    if (b.amplitude_high > a.amplitude_high) { m.amplitude_high = b.amplitude_high; m.frequency_high = b.frequency_high; }
    return m;
}

// The reports for one controller: the left motor's four bytes, then the right one's
typedef struct { dm_vibration want[2], peak[2]; uint8_t sent[8]; uint64_t last; int zeros, have_sent; } sr_pace;   // want: the latest values; peak: the strongest set since the last report
static inline float sr_level(const dm_vibration *v) { return fmaxf(v->amplitude_low, v->amplitude_high); }
static inline void sr_pace_set(sr_pace *s, const dm_vibration v[2]) {
    for (int m = 0; m < 2; m++) {
        s->want[m] = v[m];
        if (sr_level(&v[m]) > sr_level(&s->peak[m])) s->peak[m] = v[m];
    }
}
static inline int sr_silent(const uint8_t r[8]) { return !memcmp(r, sr_neutral, 4) && !memcmp(r + 4, sr_neutral, 4); }
// The eight bytes due at `now` (ns), if a report is due: 1 and out filled, 0 otherwise
static inline int sr_pace_next(sr_pace *s, uint64_t now, uint8_t out[8]) {
    if (s->have_sent && now - s->last < SR_MIN_NS) return 0;
    uint8_t r[8];
    for (int m = 0; m < 2; m++) {
        const dm_vibration *v = sr_level(&s->peak[m]) > sr_level(&s->want[m]) + 0.02f ? &s->peak[m] : &s->want[m];
        sr_encode(v, r + 4 * m);
    }
    int silent = sr_silent(r), changed = !s->have_sent || memcmp(r, s->sent, 8);
    if (!changed && (silent ? s->zeros <= 0 : now - s->last < SR_REFRESH_NS)) return 0;
    s->zeros = silent ? (changed ? SR_ZEROS - 1 : s->zeros - 1) : 0;
    memcpy(s->sent, r, 8); memcpy(out, r, 8); s->last = now; s->have_sent = 1;
    memset(s->peak, 0, sizeof s->peak);   // the peak is of the values set after this report
    return 1;
}
// Whether a report is still to come: a change not sent yet, a rumble that needs refreshing, or neutral reports left to send
static inline int sr_pace_busy(const sr_pace *s) {
    if (!s->have_sent) return 1;
    uint8_t r[8]; sr_encode(&s->want[0], r); sr_encode(&s->want[1], r + 4);
    return memcmp(r, s->sent, 8) || !sr_silent(s->sent) || s->zeros > 0 || sr_level(&s->peak[0]) > sr_level(&s->want[0]) + 0.02f || sr_level(&s->peak[1]) > sr_level(&s->want[1]) + 0.02f;
}
// A Switch controller's rumble-only output report (0x10): the report ID, a packet number counting 0 to 15, the eight bytes; padded to 49 bytes over Bluetooth, 64 over USB
static inline size_t sr_report(uint8_t *packet, const uint8_t rumble[8], int bluetooth, uint8_t out[64]) {
    memset(out, 0, 64);
    out[0] = 0x10; out[1] = *packet & 0x0F; *packet = (uint8_t)((*packet + 1) & 0x0F);
    memcpy(out + 2, rumble, 8);
    return bluetooth ? 49 : 64;
}
