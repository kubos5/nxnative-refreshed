// nxnative refreshed: the launcher's input.json (dm/mac/InputModel.swift InputConfig.hostJSON) into input_map.h's im_config. Objective-C (Foundation's JSON), no host state, so
// tests/t_input_json.m checks it against the file the window writes for the defaults (tests/input_default.json): what Swift calls the defaults is im_default here.
// Fields a file leaves out keep their defaults; a player's "binds" is its whole mapping (an input it leaves out is unbound), and "hotkeys" all the hotkeys
#pragma once
#import <Foundation/Foundation.h>
#include <stdio.h>
#include "input_map.h"

// The defaults with the hotkey the host has without a file: Escape lets a captured pointer go
static inline void im_config_default(im_config *c) {
    im_default(c);
    im_bind_set(&c->hotkey[IM_HK_CAPTURE][0], IM_SRC_KEY, 53);
}
static inline NSString *json_str(id v) { return [v isKindOfClass:NSString.class] ? v : [v isKindOfClass:NSNumber.class] ? [v stringValue] : nil; }
static inline float json_float(NSDictionary *d, NSString *k, float def) { id v = d[k]; return [v isKindOfClass:NSNumber.class] && isfinite([v doubleValue]) ? [v floatValue] : def; }
static inline int json_bool(NSDictionary *d, NSString *k, int def) { id v = d[k]; return [v isKindOfClass:NSNumber.class] ? [v boolValue] : def; }
static inline int json_bind(id v, im_bind *b) {   // {"src": "key" | "mouse" | "pad", "code": <key code> | <name>}
    if (![v isKindOfClass:NSDictionary.class]) return 0;
    NSString *src = json_str(v[@"src"]), *code = json_str(v[@"code"]); if (!src || !code) return 0;
    if ([src isEqualToString:@"key"]) { int k = code.intValue; if (k < 0 || k >= IM_KEY_CODES) return 0; im_bind_set(b, IM_SRC_KEY, k); return 1; }
    if ([src isEqualToString:@"mouse"]) { int m = im_lookup(im_mouse_names, IM_MOUSE_CODES, code.UTF8String); if (m < 0) return 0; im_bind_set(b, IM_SRC_MOUSE, m); return 1; }
    if ([src isEqualToString:@"pad"]) { int p = im_lookup(im_pad_names, IM_PAD_CODES, code.UTF8String); if (p < 0) return 0; im_bind_set(b, IM_SRC_PAD, p); return 1; }
    return 0;
}
static inline void json_player(NSDictionary *d, im_player *c) {
    if (![d isKindOfClass:NSDictionary.class]) return;
    NSDictionary *binds = d[@"binds"];
    if ([binds isKindOfClass:NSDictionary.class]) {   // the list is the whole mapping: a target it leaves out is unbound
        memset(c->bind, 0, sizeof c->bind);
        for (int t = 0; t < IM_TARGETS; t++) {
            NSArray *list = binds[@(im_target_names[t])]; if (![list isKindOfClass:NSArray.class]) continue;
            int n = 0; for (id v in list) { im_bind b = {0}; if (n < IM_BINDS && json_bind(v, &b)) c->bind[t][n++] = b; }
        }
    }
    NSDictionary *modes = d[@"modes"];
    if ([modes isKindOfClass:NSDictionary.class]) for (int t = 0; t < IM_TARGETS; t++) {
        NSString *m = json_str(modes[@(im_target_names[t])]);
        c->mode[t] = [m isEqualToString:@"toggle"] ? IM_MODE_TOGGLE : [m isEqualToString:@"turbo"] ? IM_MODE_TURBO : IM_MODE_HOLD;
    }
    c->turbo_hz = json_float(d, @"turbo_hz", c->turbo_hz); c->key_stick = json_float(d, @"key_stick", c->key_stick); c->walk = json_float(d, @"walk", c->walk);
    NSArray *sticks = d[@"sticks"];
    for (int s = 0; s < 2 && [sticks isKindOfClass:NSArray.class] && s < (int)sticks.count; s++) {
        NSDictionary *k = sticks[s]; if (![k isKindOfClass:NSDictionary.class]) continue;
        im_stick_cfg *x = &c->stick[s];
        x->deadzone = json_float(k, @"deadzone", x->deadzone); x->outer = json_float(k, @"outer", x->outer); x->curve = json_float(k, @"curve", x->curve);
        x->sens = json_float(k, @"sens", x->sens); x->anti = json_float(k, @"anti", x->anti); x->inv_x = json_bool(k, @"inv_x", x->inv_x); x->inv_y = json_bool(k, @"inv_y", x->inv_y);
    }
    c->trigger_press = json_float(d, @"trigger_press", c->trigger_press); c->stick_press = json_float(d, @"stick_press", c->stick_press);
    c->keyboard = json_bool(d, @"keyboard", c->keyboard); c->mouse = json_bool(d, @"mouse", c->mouse);
    NSString *pad = json_str(d[@"controller"]);
    if ([pad isEqualToString:@"none"]) c->pad_kind = IM_PAD_NONE;
    else if ([pad hasPrefix:@"index:"]) { c->pad_kind = IM_PAD_INDEX; c->pad_index = [pad substringFromIndex:6].intValue; }
    else if ([pad hasPrefix:@"name:"]) { c->pad_kind = IM_PAD_NAME; snprintf(c->pad_name, sizeof c->pad_name, "%s", [pad substringFromIndex:5].UTF8String ?: ""); }
    else if (pad) c->pad_kind = IM_PAD_AUTO;
    NSString *mm = json_str(d[@"mouse_mode"]);
    if (mm) c->mouse_mode = [mm isEqualToString:@"off"] ? IM_MOUSE_OFF : [mm isEqualToString:@"right_stick"] ? IM_MOUSE_RSTICK : [mm isEqualToString:@"left_stick"] ? IM_MOUSE_LSTICK
                           : [mm isEqualToString:@"gyro"] ? IM_MOUSE_GYRO : IM_MOUSE_TOUCH;
    c->mouse_sens_x = json_float(d, @"mouse_sens_x", c->mouse_sens_x); c->mouse_sens_y = json_float(d, @"mouse_sens_y", c->mouse_sens_y);
    c->mouse_smooth = json_float(d, @"mouse_smooth", c->mouse_smooth); c->mouse_inv_x = json_bool(d, @"mouse_inv_x", c->mouse_inv_x); c->mouse_inv_y = json_bool(d, @"mouse_inv_y", c->mouse_inv_y);
    NSString *ms = json_str(d[@"motion_source"]);
    if (ms) c->motion_source = [ms isEqualToString:@"off"] ? IM_MOTION_OFF : [ms isEqualToString:@"mouse"] ? IM_MOTION_MOUSE : [ms isEqualToString:@"keys"] ? IM_MOTION_KEYS : IM_MOTION_CONTROLLER;
    c->gyro_sens = json_float(d, @"gyro_sens", c->gyro_sens);
    c->inv_pitch = json_bool(d, @"inv_pitch", c->inv_pitch); c->inv_roll = json_bool(d, @"inv_roll", c->inv_roll); c->inv_yaw = json_bool(d, @"inv_yaw", c->inv_yaw);
    c->mouse_gyro_sens = json_float(d, @"mouse_gyro_sens", c->mouse_gyro_sens); c->tilt_angle = json_float(d, @"tilt_angle", c->tilt_angle);
    c->tilt_speed = json_float(d, @"tilt_speed", c->tilt_speed); c->twist_speed = json_float(d, @"twist_speed", c->twist_speed); c->auto_center = json_float(d, @"auto_center", c->auto_center);
    NSDictionary *r = d[@"rumble"];
    if ([r isKindOfClass:NSDictionary.class]) {
        c->rumble_on = json_bool(r, @"on", c->rumble_on); c->rumble_gain = json_float(r, @"gain", c->rumble_gain); c->rumble_low = json_float(r, @"low", c->rumble_low);
        c->rumble_high = json_float(r, @"high", c->rumble_high); c->rumble_min = json_float(r, @"min", c->rumble_min); c->rumble_swap = json_bool(r, @"swap", c->rumble_swap);
    }
}
// 1 when root is an input.json (over the defaults already in c)
static inline int im_config_from_json(NSDictionary *root, im_config *c) {
    if (![root isKindOfClass:NSDictionary.class]) return 0;
    c->loaded = 1;
    c->merge = json_bool(root, @"merge", c->merge);
    NSArray *players = root[@"players"];
    for (int p = 0; [players isKindOfClass:NSArray.class] && p < DM_PLAYERS && p < (int)players.count; p++) json_player(players[p], &c->player[p]);
    NSDictionary *hot = root[@"hotkeys"];
    if ([hot isKindOfClass:NSDictionary.class]) {
        memset(c->hotkey, 0, sizeof c->hotkey);
        for (int h = 0; h < IM_HOTKEYS; h++) {
            NSArray *list = hot[@(im_hotkey_names[h])]; int n = 0;
            if ([list isKindOfClass:NSArray.class]) for (id v in list) { im_bind b = {0}; if (n < IM_HK_BINDS && json_bind(v, &b)) c->hotkey[h][n++] = b; }
        }
    }
    return 1;
}
