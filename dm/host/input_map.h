// nxnative refreshed: the player's input mapping, from the physical keyboard, mouse and controllers to each player's Switch controller. Pure C, no host state, so tests/t_input_map.c
// checks it on any machine; the Mac front end (front_mac.m) reads the launcher's input.json (DM_INPUT_CONFIG, dm/mac/InputModel.swift) into im_config and calls im_eval for each player.
// Targets: the Switch's inputs. 0..15 are the NpadButton bits (dm_input.h DM_BTN_*), 16..23 the sticks' directions in NpadButton 16..23's order, then motion and modifiers.
// Each target has up to IM_BINDS bindings (a key, a mouse button or a controller element); a target is pressed when any of them is, and a stick direction takes the largest
// deflection any of them gives (a key or a button gives key_stick, a controller stick its own analog value after its dead zone and curve).
// Defaults (im_default) are nxnative's own hard-coded map, so a host without input.json plays exactly as before:
//   keyboard: WASD left stick, arrow keys D-pad, J=A K=B U=X I=Y, Q=L E=R, Z=ZL C=ZR, F=press left stick G=press right stick, Return=+ Tab=-, Space=shake
//   controller: face buttons by position (east A, south B, north X, west Y; a Nintendo pad by its labels), shoulders L R, triggers ZL ZR, Menu +, Options -, sticks and their presses, D-pad
#pragma once
#include <math.h>
#include <stdint.h>
#include <string.h>
#include "dm_input.h"

enum {
    IM_A, IM_B, IM_X, IM_Y, IM_LSTICK, IM_RSTICK, IM_L, IM_R, IM_ZL, IM_ZR, IM_PLUS, IM_MINUS, IM_DLEFT, IM_DUP, IM_DRIGHT, IM_DDOWN,   // = DM_BTN_* bit numbers
    IM_LS_LEFT, IM_LS_UP, IM_LS_RIGHT, IM_LS_DOWN, IM_RS_LEFT, IM_RS_UP, IM_RS_RIGHT, IM_RS_DOWN,                                          // = NpadButton 16..23
    IM_SHAKE, IM_TILT_UP, IM_TILT_DOWN, IM_TILT_LEFT, IM_TILT_RIGHT, IM_TWIST_LEFT, IM_TWIST_RIGHT, IM_WALK, IM_RECENTER,
    IM_TARGETS
};
// Names in input.json, in target order
static const char *const im_target_names[IM_TARGETS] = {
    "A", "B", "X", "Y", "LS", "RS", "L", "R", "ZL", "ZR", "Plus", "Minus", "DLeft", "DUp", "DRight", "DDown",
    "LSLeft", "LSUp", "LSRight", "LSDown", "RSLeft", "RSUp", "RSRight", "RSDown",
    "Shake", "TiltUp", "TiltDown", "TiltLeft", "TiltRight", "TwistLeft", "TwistRight", "Walk", "Recenter",
};
enum { IM_SRC_NONE, IM_SRC_KEY, IM_SRC_MOUSE, IM_SRC_PAD };
#define IM_KEY_CODES 128   // macOS virtual key codes (kVK_*); the modifier keys are keys of their own (54..63)
enum { IM_MB_LEFT, IM_MB_RIGHT, IM_MB_MIDDLE, IM_MB_4, IM_MB_5, IM_MB_6, IM_MB_7, IM_MB_8, IM_WHEEL_UP, IM_WHEEL_DOWN, IM_WHEEL_LEFT, IM_WHEEL_RIGHT, IM_MOUSE_CODES };
static const char *const im_mouse_names[IM_MOUSE_CODES] = {"left", "right", "middle", "button4", "button5", "button6", "button7", "button8", "wheel_up", "wheel_down", "wheel_left", "wheel_right"};
// A controller's elements by position (south = Xbox A / PlayStation cross; on a Nintendo pad east is the button marked A, as pad_apple.h reads it)
enum {
    IM_P_SOUTH, IM_P_EAST, IM_P_WEST, IM_P_NORTH, IM_P_LB, IM_P_RB, IM_P_LT, IM_P_RT, IM_P_LSB, IM_P_RSB, IM_P_MENU, IM_P_OPTIONS, IM_P_HOME, IM_P_SHARE,
    IM_P_DLEFT, IM_P_DUP, IM_P_DRIGHT, IM_P_DDOWN, IM_P_LS_LEFT, IM_P_LS_UP, IM_P_LS_RIGHT, IM_P_LS_DOWN, IM_P_RS_LEFT, IM_P_RS_UP, IM_P_RS_RIGHT, IM_P_RS_DOWN,
    IM_P_PADDLE1, IM_P_PADDLE2, IM_P_PADDLE3, IM_P_PADDLE4, IM_P_TOUCHPAD, IM_PAD_CODES
};
static const char *const im_pad_names[IM_PAD_CODES] = {
    "south", "east", "west", "north", "lb", "rb", "lt", "rt", "lsb", "rsb", "menu", "options", "home", "share",
    "dleft", "dup", "dright", "ddown", "ls_left", "ls_up", "ls_right", "ls_down", "rs_left", "rs_up", "rs_right", "rs_down",
    "paddle1", "paddle2", "paddle3", "paddle4", "touchpad",
};
static inline int im_pad_is_stick(int code) { return code >= IM_P_LS_LEFT && code <= IM_P_RS_DOWN; }
static inline int im_pad_is_trigger(int code) { return code == IM_P_LT || code == IM_P_RT; }
static inline int im_lookup(const char *const *names, int n, const char *s) { for (int i = 0; s && i < n; i++) if (!strcmp(names[i], s)) return i; return -1; }

#define IM_BINDS 6
typedef struct { uint8_t src; uint8_t code; } im_bind;
enum { IM_MODE_HOLD, IM_MODE_TOGGLE, IM_MODE_TURBO };
enum { IM_MOUSE_OFF, IM_MOUSE_TOUCH, IM_MOUSE_RSTICK, IM_MOUSE_LSTICK, IM_MOUSE_GYRO };
enum { IM_MOTION_CONTROLLER, IM_MOTION_OFF, IM_MOTION_MOUSE, IM_MOTION_KEYS };
enum { IM_PAD_AUTO, IM_PAD_NONE, IM_PAD_INDEX, IM_PAD_NAME };
typedef struct { float deadzone, outer, curve, sens, anti; int inv_x, inv_y; } im_stick_cfg;
typedef struct {
    im_bind bind[IM_TARGETS][IM_BINDS];
    uint8_t mode[IM_TARGETS];
    float turbo_hz;
    float key_stick, walk;        // a key's or button's stick deflection; the left stick's scale while Walk is held
    im_stick_cfg stick[2];        // the controller's left and right sticks
    float trigger_press;          // a trigger bound to a button presses it from this value; 0: the controller's own threshold (GameController isPressed)
    float stick_press;            // a stick direction bound to a button presses it from this deflection
    int keyboard, mouse;          // this player reads the keyboard / the mouse
    int pad_kind, pad_index; char pad_name[96];   // which controllers this player takes (IM_PAD_*): automatic, none, the n-th connected (1-based), or by name
    int mouse_mode; float mouse_sens_x, mouse_sens_y, mouse_smooth; int mouse_inv_x, mouse_inv_y;
    int motion_source; float gyro_sens; int inv_pitch, inv_roll, inv_yaw;
    float mouse_gyro_sens, tilt_angle, tilt_speed, twist_speed, auto_center;   // emulated motion: degrees, degrees per second; auto_center: degrees per second back to flat (0: stays)
    int rumble_on; float rumble_gain, rumble_low, rumble_high, rumble_min; int rumble_swap;
} im_player;
enum { IM_HK_FULLSCREEN, IM_HK_CAPTURE, IM_HK_MUTE, IM_HK_VOL_UP, IM_HK_VOL_DOWN, IM_HK_RECENTER, IM_HK_HUD, IM_HK_QUIT, IM_HOTKEYS };
static const char *const im_hotkey_names[IM_HOTKEYS] = {"fullscreen", "capture", "mute", "volume_up", "volume_down", "recenter", "hud", "quit"};
#define IM_HK_BINDS 3
typedef struct {
    int merge;                    // every controller is player 1 (DM_PAD_MERGE=1)
    im_player player[DM_PLAYERS];
    im_bind hotkey[IM_HOTKEYS][IM_HK_BINDS];
    int loaded;                   // read from input.json (0: the built-in defaults)
} im_config;

// What one player's devices hold now
typedef struct {
    uint8_t key[IM_KEY_CODES];       // held
    uint8_t mouse[IM_MOUSE_CODES];   // held (a wheel notch holds its code for a moment)
    float pad[IM_PAD_CODES];         // 0..1; stick directions after im_stick
    uint8_t pad_pressed[IM_PAD_CODES];   // the controller's own pressed state (buttons, triggers)
    float mouse_stick[2];            // the mouse as a stick (-1..1, y up), for IM_MOUSE_RSTICK / LSTICK
} im_inputs;
typedef struct { uint8_t was[IM_TARGETS], latched[IM_TARGETS]; double since[IM_TARGETS]; } im_runtime;
typedef struct { uint64_t buttons; int32_t lx, ly, rx, ry; float target[IM_TARGETS]; uint8_t pressed[IM_TARGETS]; } im_output;

static inline void im_bind_set(im_bind *b, int src, int code) { b->src = (uint8_t)src; b->code = (uint8_t)code; }
static inline int im_bind_add(im_bind *list, int n, int src, int code) {   // into the first free slot; 0 when full
    for (int i = 0; i < n; i++) if (list[i].src == IM_SRC_NONE) { im_bind_set(&list[i], src, code); return 1; }
    return 0;
}

static inline void im_player_default(im_player *p, int index) {
    memset(p, 0, sizeof *p);
    static const struct { uint8_t t, key; } keys[] = {
        {IM_LS_UP, 13}, {IM_LS_LEFT, 0}, {IM_LS_DOWN, 1}, {IM_LS_RIGHT, 2},                 // W A S D
        {IM_DLEFT, 123}, {IM_DUP, 126}, {IM_DRIGHT, 124}, {IM_DDOWN, 125},                   // arrow keys
        {IM_A, 38}, {IM_B, 40}, {IM_X, 32}, {IM_Y, 34},                                      // J K U I
        {IM_LSTICK, 3}, {IM_RSTICK, 5},                                                      // F G
        {IM_L, 12}, {IM_R, 14}, {IM_ZL, 6}, {IM_ZR, 8},                                      // Q E Z C
        {IM_PLUS, 36}, {IM_MINUS, 48}, {IM_SHAKE, 49},                                       // Return Tab Space
    };
    static const struct { uint8_t t, pad; } pads[] = {
        {IM_A, IM_P_EAST}, {IM_B, IM_P_SOUTH}, {IM_X, IM_P_NORTH}, {IM_Y, IM_P_WEST},
        {IM_L, IM_P_LB}, {IM_R, IM_P_RB}, {IM_ZL, IM_P_LT}, {IM_ZR, IM_P_RT}, {IM_PLUS, IM_P_MENU}, {IM_MINUS, IM_P_OPTIONS},
        {IM_LSTICK, IM_P_LSB}, {IM_RSTICK, IM_P_RSB},
        {IM_DLEFT, IM_P_DLEFT}, {IM_DUP, IM_P_DUP}, {IM_DRIGHT, IM_P_DRIGHT}, {IM_DDOWN, IM_P_DDOWN},
        {IM_LS_LEFT, IM_P_LS_LEFT}, {IM_LS_UP, IM_P_LS_UP}, {IM_LS_RIGHT, IM_P_LS_RIGHT}, {IM_LS_DOWN, IM_P_LS_DOWN},
        {IM_RS_LEFT, IM_P_RS_LEFT}, {IM_RS_UP, IM_P_RS_UP}, {IM_RS_RIGHT, IM_P_RS_RIGHT}, {IM_RS_DOWN, IM_P_RS_DOWN},
    };
    // Keyboard columns 0-1, mouse 2, controller 3-4 (the launcher's columns; the host only ORs them)
    if (index == 0) for (size_t i = 0; i < sizeof keys / sizeof *keys; i++) im_bind_set(&p->bind[keys[i].t][0], IM_SRC_KEY, keys[i].key);
    for (size_t i = 0; i < sizeof pads / sizeof *pads; i++) im_bind_set(&p->bind[pads[i].t][3], IM_SRC_PAD, pads[i].pad);
    p->turbo_hz = 10; p->key_stick = 1; p->walk = 0.5f;
    for (int s = 0; s < 2; s++) p->stick[s] = (im_stick_cfg){0, 1, 1, 1, 0, 0, 0};
    p->trigger_press = 0; p->stick_press = 0.5f;
    p->keyboard = p->mouse = index == 0;
    p->pad_kind = IM_PAD_AUTO;
    p->mouse_mode = IM_MOUSE_TOUCH; p->mouse_sens_x = p->mouse_sens_y = 1; p->mouse_smooth = 0.5f;
    p->motion_source = IM_MOTION_CONTROLLER; p->gyro_sens = 1;
    p->mouse_gyro_sens = 1; p->tilt_angle = 35; p->tilt_speed = 240; p->twist_speed = 180; p->auto_center = 0;
    p->rumble_on = 1; p->rumble_gain = p->rumble_low = p->rumble_high = 1; p->rumble_min = 0;
}
static inline void im_default(im_config *c) {
    memset(c, 0, sizeof *c);
    for (int p = 0; p < DM_PLAYERS; p++) im_player_default(&c->player[p], p);
}

// A physical stick through its dead zone, outer edge, response curve, sensitivity and minimum output: out = its left, up, right, down deflections (0..1). y up.
static inline void im_stick(const im_stick_cfg *s, float x, float y, float out[4]) {
    out[0] = out[1] = out[2] = out[3] = 0;
    if (!isfinite(x) || !isfinite(y)) return;
    if (s->inv_x) x = -x;
    if (s->inv_y) y = -y;
    float m = sqrtf(x * x + y * y), dz = fmaxf(0, fminf(0.95f, s->deadzone));
    if (m <= dz || m <= 0) return;
    float outer = fmaxf(dz + 0.01f, fminf(1, s->outer > 0 ? s->outer : 1));
    float n = (fminf(m, outer) - dz) / (outer - dz);
    if (s->curve > 0 && s->curve != 1) n = powf(n, s->curve);
    float anti = fmaxf(0, fminf(0.9f, s->anti));
    n = anti + (1 - anti) * n;
    n = fminf(1, n * (s->sens > 0 ? s->sens : 1));
    float k = n / m; x *= k; y *= k;
    float l = sqrtf(x * x + y * y); if (l > 1) { x /= l; y /= l; }
    out[0] = fmaxf(0, -x); out[1] = fmaxf(0, y); out[2] = fmaxf(0, x); out[3] = fmaxf(0, -y);
}

static inline float im_digital_threshold(const im_player *c, const im_bind *b) {
    if (b->src != IM_SRC_PAD) return 0.5f;
    if (im_pad_is_stick(b->code)) return c->stick_press > 0 ? c->stick_press : 0.5f;
    return -1;   // a button or a trigger: the controller's pressed state, or trigger_press
}
static inline int im_bind_pressed(const im_player *c, const im_inputs *in, const im_bind *b) {
    switch (b->src) {
    case IM_SRC_KEY: return b->code < IM_KEY_CODES && in->key[b->code];
    case IM_SRC_MOUSE: return b->code < IM_MOUSE_CODES && in->mouse[b->code];
    case IM_SRC_PAD:
        if (b->code >= IM_PAD_CODES) return 0;
        if (im_pad_is_trigger(b->code) && c->trigger_press > 0) return in->pad[b->code] >= c->trigger_press;
        if (im_pad_is_stick(b->code)) return in->pad[b->code] >= im_digital_threshold(c, b);
        return in->pad_pressed[b->code];
    }
    return 0;
}
static inline float im_bind_value(const im_player *c, const im_inputs *in, const im_bind *b) {   // a stick direction's deflection from this binding
    if (b->src == IM_SRC_PAD && b->code < IM_PAD_CODES && (im_pad_is_stick(b->code) || im_pad_is_trigger(b->code))) return in->pad[b->code];
    if (!im_bind_pressed(c, in, b)) return 0;
    return b->src == IM_SRC_PAD ? 1 : c->key_stick;
}
static inline int32_t im_axis(float v) { v = fmaxf(-1, fminf(1, v)); return (int32_t)lrintf(v * DM_STICK_MAX); }
static inline float im_pick(float a, float b) { return fabsf(a) >= fabsf(b) ? a : b; }   // as hle_hid.c: whichever is deflected more

// One player's Switch state from what its devices hold. now in seconds (any monotonic clock), for turbo
static inline void im_eval(const im_player *c, const im_inputs *in, im_runtime *rt, double now, im_output *out) {
    memset(out, 0, sizeof *out);
    for (int t = 0; t < IM_TARGETS; t++) {
        int pressed = 0; float v = 0;
        for (int i = 0; i < IM_BINDS; i++) {
            const im_bind *b = &c->bind[t][i];
            if (b->src == IM_SRC_NONE) continue;
            pressed |= im_bind_pressed(c, in, b);
            v = fmaxf(v, im_bind_value(c, in, b));
        }
        int edge = pressed && !rt->was[t];
        rt->was[t] = (uint8_t)pressed;
        switch (c->mode[t]) {
        case IM_MODE_TOGGLE:
            if (edge) rt->latched[t] = !rt->latched[t];
            pressed = rt->latched[t]; if (pressed) v = fmaxf(v, c->key_stick); else v = 0;
            break;
        case IM_MODE_TURBO:
            if (edge) rt->since[t] = now;
            if (pressed) {
                double period = 1.0 / (c->turbo_hz > 0.5f ? c->turbo_hz : 0.5f);
                int on = fmod(now - rt->since[t], period) < period / 2;
                if (!on) { pressed = 0; v = 0; }
            }
            break;
        }
        out->pressed[t] = (uint8_t)pressed; out->target[t] = pressed && v <= 0 ? 1 : v;
    }
    for (int t = 0; t < 16; t++) if (out->pressed[t]) out->buttons |= 1ull << t;
    if (out->pressed[IM_SHAKE]) out->buttons |= DM_BTN_SHAKE;
    float s[2][2];
    for (int k = 0; k < 2; k++) {
        const float *d = &out->target[IM_LS_LEFT + 4 * k];
        float x = fminf(1, d[2]) - fminf(1, d[0]), y = fminf(1, d[1]) - fminf(1, d[3]);
        float m = sqrtf(x * x + y * y); if (m > 1) { x /= m; y /= m; }
        s[k][0] = x; s[k][1] = y;
    }
    if (out->pressed[IM_WALK]) { float w = fmaxf(0, fminf(1, c->walk)); s[0][0] *= w; s[0][1] *= w; }
    if (c->mouse && (c->mouse_mode == IM_MOUSE_RSTICK || c->mouse_mode == IM_MOUSE_LSTICK)) {
        int k = c->mouse_mode == IM_MOUSE_LSTICK ? 0 : 1;
        s[k][0] = im_pick(s[k][0], in->mouse_stick[0]); s[k][1] = im_pick(s[k][1], in->mouse_stick[1]);
    }
    out->lx = im_axis(s[0][0]); out->ly = im_axis(s[0][1]); out->rx = im_axis(s[1][0]); out->ry = im_axis(s[1][1]);
}

// The hotkey bound to a key, a mouse button or a controller element (-1: none)
static inline int im_hotkey_of(const im_config *c, int src, int code) {
    for (int h = 0; h < IM_HOTKEYS; h++) for (int i = 0; i < IM_HK_BINDS; i++) if (c->hotkey[h][i].src == src && c->hotkey[h][i].code == code) return h;
    return -1;
}

// Emulated motion (keyboard tilt, the mouse as a gyro): the controller's tilt and twist in degrees, and what the six-axis sensor reads from them.
// Switch frame (motion_fusion.h): x right, y forward, z up; at rest acc = (0, 0, -1). Pitch turns about x (forward edge up), roll about y (right edge down), yaw about z
typedef struct { float pitch, roll, yaw, pp, pr, py; double shake_t0, shake_end; int primed; } im_emu;
static inline void im_emu_reset(im_emu *e) { memset(e, 0, sizeof *e); }
// dt seconds since the last step; tilt[4]: up, down, left, right (0..1); twist: right - left (-1..1); mouse_dx/dy: pointer movement in points since the last step (y down)
static inline void im_emu_step(const im_player *c, im_emu *e, float dt, const float tilt[4], float twist, float mouse_dx, float mouse_dy, int mouse_on) {
    if (dt <= 0) dt = 1e-3f;
    if (!e->primed) { e->pp = e->pitch; e->pr = e->roll; e->py = e->yaw; e->primed = 1; }
    else { e->pp = e->pitch; e->pr = e->roll; e->py = e->yaw; }
    float max = fmaxf(1, fminf(90, c->tilt_angle)), speed = fmaxf(1, c->tilt_speed) * dt;
    float tp = (tilt[0] - tilt[1]) * max, tr = (tilt[3] - tilt[2]) * max;
    int keys = tilt[0] > 0 || tilt[1] > 0 || tilt[2] > 0 || tilt[3] > 0;
    if (keys || c->motion_source == IM_MOTION_KEYS) {
        e->pitch += fmaxf(-speed, fminf(speed, tp - e->pitch));
        e->roll += fmaxf(-speed, fminf(speed, tr - e->roll));
    }
    e->yaw += twist * fmaxf(1, c->twist_speed) * dt;
    if (mouse_on) {   // 0.12 degrees of turn per point at sensitivity 1: a 750-point sweep turns the controller a quarter
        float k = 0.12f * (c->mouse_gyro_sens > 0 ? c->mouse_gyro_sens : 1);
        e->pitch += (c->mouse_inv_y ? mouse_dy : -mouse_dy) * k;
        e->yaw += (c->mouse_inv_x ? mouse_dx : -mouse_dx) * k;
        e->pitch = fmaxf(-89, fminf(89, e->pitch));
    }
    if (!keys && !mouse_on && c->auto_center > 0) {   // back toward flat when nothing tilts it
        float a = c->auto_center * dt;
        e->pitch -= fmaxf(-a, fminf(a, e->pitch)); e->roll -= fmaxf(-a, fminf(a, e->roll));
    } else if (!keys && mouse_on && c->auto_center > 0 && fabsf(mouse_dx) + fabsf(mouse_dy) < 0.01f) {
        float a = c->auto_center * dt;
        e->pitch -= fmaxf(-a, fminf(a, e->pitch));
    }
}
// The six-axis reading of the emulated controller: acc in G, rot in rad/s (Switch frame). shaking: add the side-to-side shake (6 Hz, 3 G) at time now (seconds)
static inline void im_emu_sample(const im_player *c, const im_emu *e, float dt, int shaking, double now, float acc[3], float rot[3]) {
    const float d2r = (float)M_PI / 180.f;
    float p = e->pitch * d2r, r = e->roll * d2r;
    acc[0] = sinf(r) * cosf(p); acc[1] = -sinf(p); acc[2] = -cosf(r) * cosf(p);
    if (dt <= 0) dt = 1e-3f;
    rot[0] = (e->pitch - e->pp) * d2r / dt; rot[1] = (e->roll - e->pr) * d2r / dt; rot[2] = (e->yaw - e->py) * d2r / dt;
    if (c->inv_pitch) rot[0] = -rot[0];
    if (c->inv_roll) rot[1] = -rot[1];
    if (c->inv_yaw) rot[2] = -rot[2];
    if (shaking) acc[0] += (float)(3.0 * sin(2 * M_PI * 6.0 * (now - e->shake_t0)));
}
// A controller's own gyro, through the player's sensitivity and axis inversions (rad/s; the acceleration stays as measured)
static inline void im_gyro_xform(const im_player *c, float rot[3]) {
    float k = c->gyro_sens > 0 ? c->gyro_sens : 1;
    rot[0] *= c->inv_pitch ? -k : k; rot[1] *= c->inv_roll ? -k : k; rot[2] *= c->inv_yaw ? -k : k;
}
