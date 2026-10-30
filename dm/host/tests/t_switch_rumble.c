// switch_rumble.h: the HD Rumble bytes of rumble_data_table.md (frequency rows and every safe amplitude row), the neutral value, the safe limit, and the pacing
// (at most one report per 30 ms, a refresh every 50 ms, five neutral reports at the end, a short peak between two reports sent before the latest value)
#include <assert.h>
#include <stdio.h>
#include "../switch_rumble.h"

static dm_vibration vib(float al, float fl, float ah, float fh) { return (dm_vibration){al, fl, ah, fh}; }
static void encode(dm_vibration v, uint8_t out[4]) { sr_encode(&v, out); }
static int bytes(const uint8_t *r, int a, int b, int c, int d) { return r[0] == a && r[1] == b && r[2] == c && r[3] == d; }

int main(void) {
    uint8_t r[4];
    // frequency rows of the table: (Hz, the high band's two bytes or -1, the low band's byte or -1)
    static const struct { float hz; int hf0, hf1, lf; } rows[] = {
        {40.875885f, -1, -1, 0x01}, {49.674313f, -1, -1, 0x0A}, {73.360321f, -1, -1, 0x1C}, {89.15094f, 0x14, 0x00, 0x25}, {131.660431f, 0x5C, 0x00, 0x37},
        {160, 0x80, 0x00, 0x40}, {236.292191f, 0xC8, 0x00, 0x52}, {334.167603f, 0x08, 0x01, 0x62}, {348.962463f, 0x10, 0x01, 0x64}, {515.356934f, 0x58, 0x01, 0x76},
        {626.286133f, 0x7C, 0x01, 0x7F}, {761.092529f, 0xA0, 0x01, -1}, {987.014954f, 0xD0, 0x01, -1}, {1252.572266f, 0xFC, 0x01, -1},
    };
    for (size_t i = 0; i < sizeof rows / sizeof rows[0]; i++) {
        if (rows[i].hf0 >= 0) { encode(vib(0, 160, 1, rows[i].hz), r); assert(r[0] == rows[i].hf0 && (r[1] & 1) == rows[i].hf1); }
        if (rows[i].lf >= 0) { encode(vib(1, rows[i].hz, 0, 320), r); assert((r[2] & 0x7F) == rows[i].lf); }
    }
    // every safe amplitude row: HA = 2 * code, LA = 0x40 + code / 2 with 0x80 on byte 2 for an odd code; the codes come back from the bytes
    for (int i = 1; i <= 100; i++) {
        encode(vib(sr_amp_table[i], 160, sr_amp_table[i], 320), r);
        assert(r[0] == 0x00 && r[1] == (2 * i | 1) && r[2] == (0x40 | (i & 1 ? 0x80 : 0)) && r[3] == 0x40 + i / 2);
        dm_vibration back; sr_decode(r, &back);
        assert(back.amplitude_low == sr_amp_table[i] && back.amplitude_high == sr_amp_table[i] && fabsf(back.frequency_low - 160) < 0.01f && fabsf(back.frequency_high - 320) < 0.01f);
    }
    // the document's example: high 0x01A8 at HA 0x88, low 0x63 at LA 0x804D
    encode(vib(sr_amp_table[27], 10.f * exp2f((0x63 + 0x40) / 32.f), sr_amp_table[0x44], 10.f * exp2f((0x1A8 / 4 + 0x60) / 32.f)), r);
    assert(bytes(r, 0xA8, 0x89, 0xE3, 0x4D));
    // neutral, nearest codes, the safe limit, out-of-range frequencies, no number
    encode(vib(0, 160, 0, 320), r); assert(bytes(r, 0x00, 0x01, 0x40, 0x40));
    encode(vib(0.003f, 90, 0.003f, 700), r); assert(bytes(r, 0x00, 0x01, 0x40, 0x40));   // below the first step: silent
    assert(sr_amp_code(0.5f) == 68 && sr_amp_code(0.505f) == 68 && sr_amp_code(0.51f) == 69 && sr_amp_code(1) == 100 && sr_amp_code(2) == 100 && sr_amp_code(NAN) == 0 && sr_amp_code(-1) == 0);
    encode(vib(1, 10, 1, 5000), r); assert((r[2] & 0x7F) == 0x01 && r[0] == 0xFC && (r[1] & 1));   // clamped to 40.88 Hz and 1252.57 Hz
    encode(vib(1, 2000, 1, 20), r); assert((r[2] & 0x7F) == 0x7F && r[0] == 0x04 && !(r[1] & 1));   // clamped to 626.28 Hz and 81.75 Hz
    encode(vib(1, NAN, 1, NAN), r); assert(r[1] >> 1 == 100 && r[3] == 0x72);
    // one actuator for two motors: each band from the louder motor
    dm_vibration m = sr_mix(vib(0.2f, 100, 0.9f, 300), vib(0.6f, 180, 0.1f, 900));
    assert(m.amplitude_low == 0.6f && m.frequency_low == 180 && m.amplitude_high == 0.9f && m.frequency_high == 300);
    // the report: ID, a packet number counting 0 to 15, the eight bytes, the transport's length
    uint8_t packet = 15, out[64], eight[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    assert(sr_report(&packet, eight, 1, out) == 49 && out[0] == 0x10 && out[1] == 15 && packet == 0 && !memcmp(out + 2, eight, 8) && out[10] == 0);
    assert(sr_report(&packet, eight, 0, out) == 64 && out[1] == 0 && packet == 1);

    // pacing
    const uint64_t ms = 1000000;
    sr_pace s = {0}; uint8_t sent[8]; dm_vibration v[2];
    assert(sr_pace_busy(&s) && sr_pace_next(&s, 1000 * ms, sent) && sr_silent(sent));   // the first report: neutral
    uint64_t t = 1000 * ms; int n = 1;
    while (sr_pace_busy(&s)) { t += 10 * ms; if (sr_pace_next(&s, t, sent)) { assert(sr_silent(sent)); n++; } }
    assert(n == SR_ZEROS && t <= 1000 * ms + SR_ZEROS * 30 * ms);   // five neutral reports, 30 ms apart, then nothing
    assert(!sr_pace_next(&s, t + 1000 * ms, sent));
    t += 1000 * ms;
    v[0] = vib(0.5f, 160, 0.3f, 320); v[1] = vib(0, 160, 0, 320);
    sr_pace_set(&s, v); assert(sr_pace_busy(&s) && sr_pace_next(&s, t, sent));   // a change goes out at once
    uint8_t l[4]; encode(v[0], l); assert(!memcmp(sent, l, 4) && !memcmp(sent + 4, sr_neutral, 4));
    v[0].amplitude_low = 0.6f; sr_pace_set(&s, v);
    assert(!sr_pace_next(&s, t + 10 * ms, sent) && !sr_pace_next(&s, t + 29 * ms, sent) && sr_pace_next(&s, t + 30 * ms, sent));   // not sooner than 30 ms
    encode(v[0], l); assert(!memcmp(sent, l, 4));
    t += 30 * ms;
    assert(!sr_pace_next(&s, t + 49 * ms, sent) && sr_pace_next(&s, t + 50 * ms, sent) && !memcmp(sent, l, 4));   // unchanged: again after 50 ms
    t += 50 * ms;
    // a short impact between two reports, then back to quiet: the impact first, the quiet value after
    dm_vibration hit = vib(1, 160, 1, 320), quiet = vib(0.1f, 160, 0, 320);
    v[0] = hit; sr_pace_set(&s, v); v[0] = quiet; sr_pace_set(&s, v);
    assert(sr_pace_next(&s, t + 30 * ms, sent)); encode(hit, l); assert(!memcmp(sent, l, 4));
    assert(sr_pace_next(&s, t + 60 * ms, sent)); encode(quiet, l); assert(!memcmp(sent, l, 4));
    t += 60 * ms;
    // the end: neutral, then four more, then quiet
    v[0] = vib(0, 160, 0, 320); sr_pace_set(&s, v);
    n = 0; for (uint64_t u = t + 30 * ms; u < t + 1000 * ms; u += 5 * ms) if (sr_pace_next(&s, u, sent)) { assert(sr_silent(sent)); n++; }
    assert(n == SR_ZEROS && !sr_pace_busy(&s));
    puts("t_switch_rumble: HD Rumble bytes, safe limit, mixing, report and pacing ok");
    return 0;
}
