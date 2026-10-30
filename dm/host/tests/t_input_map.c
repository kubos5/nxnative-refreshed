// input_map.h (nxnative refreshed): the defaults are nxnative's own map, bindings OR together, sticks combine and clamp, dead zones and curves, analog thresholds,
// toggle and turbo, Walk, the mouse as a stick, hotkey lookup and emulated motion
#include <assert.h>
#include <stdio.h>
#include "../input_map.h"

static int near(float a, float b) { return fabsf(a - b) < 1e-3f; }
static im_output run(const im_player *c, const im_inputs *in, im_runtime *rt, double t) { im_output o; im_eval(c, in, rt, t, &o); return o; }

int main(void) {
    im_config cfg; im_default(&cfg);
    const im_player *p1 = &cfg.player[0], *p2 = &cfg.player[1];
    // nxnative's keyboard map on player 1 only, the controller map on every player
    assert(p1->keyboard && p1->mouse && !p2->keyboard && !p2->mouse);
    assert(p1->bind[IM_A][0].src == IM_SRC_KEY && p1->bind[IM_A][0].code == 38);   // J
    assert(p1->bind[IM_SHAKE][0].code == 49 && p1->bind[IM_LS_UP][0].code == 13);    // Space, W
    assert(p2->bind[IM_A][0].src == IM_SRC_NONE && p2->bind[IM_A][3].src == IM_SRC_PAD && p2->bind[IM_A][3].code == IM_P_EAST);
    assert(p1->bind[IM_ZL][3].code == IM_P_LT && p1->mouse_mode == IM_MOUSE_TOUCH && p1->pad_kind == IM_PAD_AUTO);

    im_runtime rt = {0}; im_inputs in = {0};
    in.key[38] = 1; in.key[13] = 1; in.key[2] = 1;   // J, W, D
    im_output o = run(p1, &in, &rt, 0);
    assert(o.buttons == DM_BTN_A);
    assert(o.lx == o.ly && near(o.lx / 32767.f, sqrtf(0.5f)));   // a keyboard diagonal sits on the circle
    in.key[1] = 1; o = run(p1, &in, &rt, 0); assert(o.ly == 0 && o.lx == DM_STICK_MAX);   // W and S cancel
    memset(&in, 0, sizeof in);
    in.key[49] = 1; o = run(p1, &in, &rt, 0); assert(o.buttons == DM_BTN_SHAKE);

    // controller: the trigger's own pressed state by default, a threshold when set; the stick as it is
    memset(&in, 0, sizeof in);
    in.pad[IM_P_LT] = 0.3f; in.pad_pressed[IM_P_LT] = 1; o = run(p1, &in, &rt, 0); assert(o.buttons == DM_BTN_ZL);
    im_player c = *p1; c.trigger_press = 0.5f; o = run(&c, &in, &rt, 0); assert(o.buttons == 0);
    in.pad[IM_P_LT] = 0.6f; o = run(&c, &in, &rt, 0); assert(o.buttons == DM_BTN_ZL);
    memset(&in, 0, sizeof in);
    float d[4]; im_stick(&p1->stick[0], 0.3f, -0.4f, d);
    assert(near(d[2], 0.3f) && near(d[3], 0.4f) && d[0] == 0 && d[1] == 0);
    for (int i = 0; i < 4; i++) in.pad[IM_P_LS_LEFT + i] = d[i];
    o = run(p1, &in, &rt, 0); assert(near(o.lx / 32767.f, 0.3f) && near(o.ly / 32767.f, -0.4f) && o.buttons == 0);

    // dead zone, outer edge, curve, minimum output, inversion
    im_stick_cfg s = {0.2f, 0.9f, 2, 1, 0, 0, 0};
    im_stick(&s, 0.15f, 0, d); assert(d[2] == 0);
    im_stick(&s, 0.9f, 0, d); assert(near(d[2], 1));
    im_stick(&s, 0.55f, 0, d); assert(near(d[2], 0.25f));   // halfway past the dead zone, squared
    s = (im_stick_cfg){0.1f, 1, 1, 1, 0.3f, 1, 0};
    im_stick(&s, 0.11f, 0, d); assert(d[0] > 0.3f && d[2] == 0);   // inverted x, and the minimum output past the dead zone

    // a stick direction bound to a button presses it past stick_press; a key bound to a stick direction gives key_stick
    c = *p1; memset(c.bind, 0, sizeof c.bind);
    im_bind_set(&c.bind[IM_DUP][0], IM_SRC_PAD, IM_P_RS_UP); im_bind_set(&c.bind[IM_RS_LEFT][0], IM_SRC_KEY, 0);
    c.key_stick = 0.5f;
    memset(&in, 0, sizeof in); in.pad[IM_P_RS_UP] = 0.4f; o = run(&c, &in, &rt, 0); assert(o.buttons == 0);
    in.pad[IM_P_RS_UP] = 0.6f; o = run(&c, &in, &rt, 0); assert(o.buttons == DM_BTN_UP);
    in.key[0] = 1; o = run(&c, &in, &rt, 0); assert(near(o.rx / 32767.f, -0.5f));

    // toggle and turbo
    c = *p1; c.mode[IM_A] = IM_MODE_TOGGLE; memset(&rt, 0, sizeof rt); memset(&in, 0, sizeof in);
    in.key[38] = 1; assert(run(&c, &in, &rt, 0).buttons == DM_BTN_A);
    in.key[38] = 0; assert(run(&c, &in, &rt, 0).buttons == DM_BTN_A);   // stays on
    in.key[38] = 1; assert(run(&c, &in, &rt, 0).buttons == 0);          // second press turns it off
    c.mode[IM_A] = IM_MODE_TURBO; c.turbo_hz = 10; memset(&rt, 0, sizeof rt);
    in.key[38] = 1;
    assert(run(&c, &in, &rt, 1.00).buttons == DM_BTN_A);
    assert(run(&c, &in, &rt, 1.07).buttons == 0);
    assert(run(&c, &in, &rt, 1.11).buttons == DM_BTN_A);
    // an auto-run: Up on the left stick as a toggle
    c = *p1; c.mode[IM_LS_UP] = IM_MODE_TOGGLE; memset(&rt, 0, sizeof rt); memset(&in, 0, sizeof in);
    in.key[13] = 1; run(&c, &in, &rt, 0); in.key[13] = 0; o = run(&c, &in, &rt, 0); assert(o.ly == DM_STICK_MAX);

    // Walk scales the left stick; the mouse as the right stick
    c = *p1; im_bind_set(&c.bind[IM_WALK][0], IM_SRC_KEY, 56); memset(&rt, 0, sizeof rt); memset(&in, 0, sizeof in);
    in.key[13] = 1; in.key[56] = 1; o = run(&c, &in, &rt, 0); assert(near(o.ly / 32767.f, 0.5f));
    c.mouse_mode = IM_MOUSE_RSTICK; in.mouse_stick[0] = 0.75f; o = run(&c, &in, &rt, 0); assert(near(o.rx / 32767.f, 0.75f));
    c.mouse = 0; o = run(&c, &in, &rt, 0); assert(o.rx == 0);

    // mouse buttons and wheel
    c = *p1; im_bind_set(&c.bind[IM_ZR][2], IM_SRC_MOUSE, IM_MB_LEFT); im_bind_set(&c.bind[IM_R][2], IM_SRC_MOUSE, IM_WHEEL_UP);
    memset(&in, 0, sizeof in); in.mouse[IM_MB_LEFT] = 1; in.mouse[IM_WHEEL_UP] = 1;
    assert(run(&c, &in, &rt, 0).buttons == (DM_BTN_ZR | DM_BTN_R));

    // hotkeys
    im_bind_set(&cfg.hotkey[IM_HK_MUTE][0], IM_SRC_KEY, 46); im_bind_set(&cfg.hotkey[IM_HK_RECENTER][1], IM_SRC_PAD, IM_P_HOME);
    assert(im_hotkey_of(&cfg, IM_SRC_KEY, 46) == IM_HK_MUTE && im_hotkey_of(&cfg, IM_SRC_PAD, IM_P_HOME) == IM_HK_RECENTER && im_hotkey_of(&cfg, IM_SRC_KEY, 38) < 0);

    // names round trip
    assert(im_lookup(im_target_names, IM_TARGETS, "RSDown") == IM_RS_DOWN && im_lookup(im_pad_names, IM_PAD_CODES, "touchpad") == IM_P_TOUCHPAD);
    assert(im_lookup(im_mouse_names, IM_MOUSE_CODES, "wheel_right") == IM_WHEEL_RIGHT && im_lookup(im_pad_names, IM_PAD_CODES, "nope") < 0);

    // emulated motion: flat at rest, tilted toward the keys, back to flat, the mouse turns it, a sample's rotation is the turn per second
    im_emu e; im_emu_reset(&e); float acc[3], rot[3]; float none[4] = {0}, up[4] = {1, 0, 0, 0};
    c = *p1; c.motion_source = IM_MOTION_KEYS; c.tilt_angle = 30; c.tilt_speed = 300;
    im_emu_step(&c, &e, 0.01f, none, 0, 0, 0, 0); im_emu_sample(&c, &e, 0.01f, 0, 0, acc, rot);
    assert(near(acc[2], -1) && near(acc[0], 0) && near(acc[1], 0) && near(rot[0], 0));
    for (int i = 0; i < 20; i++) im_emu_step(&c, &e, 0.01f, up, 0, 0, 0, 0);
    assert(near(e.pitch, 30));
    im_emu_sample(&c, &e, 0.01f, 0, 0, acc, rot); assert(near(acc[1], -0.5f) && near(rot[0], 0));
    im_emu_step(&c, &e, 0.01f, none, 0, 0, 0, 0); assert(near(e.pitch, 27));
    im_emu_sample(&c, &e, 0.01f, 0, 0, acc, rot); assert(near(rot[0], -3 * (float)M_PI / 180 / 0.01f));
    im_emu_reset(&e); c.motion_source = IM_MOTION_MOUSE; c.mouse_gyro_sens = 1;
    im_emu_step(&c, &e, 0.01f, none, 0, 100, -50, 1); assert(near(e.yaw, -12) && near(e.pitch, 6));
    im_emu_sample(&c, &e, 0.01f, 1, 1.0 / 24, acc, rot); assert(near(acc[0], 3));   // a quarter into the shake cycle
    float g[3] = {1, 2, 3}; c.gyro_sens = 2; c.inv_yaw = 1; im_gyro_xform(&c, g); assert(near(g[0], 2) && near(g[1], 4) && near(g[2], -6));

    puts("t_input_map: ok");
    return 0;
}
