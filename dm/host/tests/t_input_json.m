// input_json.h (nxnative refreshed): the input.json the settings window writes for its defaults (input_default.json, from dm/mac/InputModel.swift; test_launcher_storage.py checks
// the window still writes the same) reads as the host's own defaults, so an app plays the same with or without the window; and a changed file reads as written
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
#include "../input_json.h"

static int same_binds(const im_bind *a, const im_bind *b) {   // the same bindings, in any slots
    for (int pass = 0; pass < 2; pass++) {
        const im_bind *x = pass ? b : a, *y = pass ? a : b;
        for (int i = 0; i < IM_BINDS; i++) {
            if (x[i].src == IM_SRC_NONE) continue;
            int found = 0; for (int j = 0; j < IM_BINDS; j++) found |= y[j].src == x[i].src && y[j].code == x[i].code;
            if (!found) return 0;
        }
    }
    return 1;
}
static int same_player(const im_player *a, const im_player *b) {
    for (int t = 0; t < IM_TARGETS; t++) if (!same_binds(a->bind[t], b->bind[t]) || a->mode[t] != b->mode[t]) { fprintf(stderr, "target %s differs\n", im_target_names[t]); return 0; }
    im_player x = *a, y = *b; memset(x.bind, 0, sizeof x.bind); memset(y.bind, 0, sizeof y.bind);
    if (memcmp(&x, &y, sizeof x)) { fprintf(stderr, "settings differ\n"); return 0; }
    return 1;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *path = argc > 1 ? argv[1] : "input_default.json";
        NSData *d = [NSData dataWithContentsOfFile:@(path)];
        assert(d && "input_default.json");
        im_config want, got; im_config_default(&want); im_config_default(&got);
        assert(im_config_from_json([NSJSONSerialization JSONObjectWithData:d options:0 error:nil], &got) && got.loaded);
        for (int p = 0; p < DM_PLAYERS; p++) { if (!same_player(&want.player[p], &got.player[p])) { fprintf(stderr, "player %d\n", p + 1); return 1; } }
        assert(got.merge == want.merge);
        for (int h = 0; h < IM_HOTKEYS; h++) for (int i = 0; i < IM_HK_BINDS; i++) assert(got.hotkey[h][i].src == want.hotkey[h][i].src && got.hotkey[h][i].code == want.hotkey[h][i].code);

        // a changed file: player 2 on the keyboard's left half with turbo A, the second controller, the mouse as the right stick, motion from tilt keys, rumble swapped
        NSDictionary *root = @{@"merge": @NO, @"hotkeys": @{@"mute": @[@{@"src": @"key", @"code": @"46"}], @"recenter": @[@{@"src": @"pad", @"code": @"home"}]},
                               @"players": @[@{}, @{@"keyboard": @YES, @"mouse": @YES, @"controller": @"index:2",
                                                    @"binds": @{@"A": @[@{@"src": @"key", @"code": @"3"}, @{@"src": @"mouse", @"code": @"left"}, @{@"src": @"pad", @"code": @"south"}],
                                                                @"TiltUp": @[@{@"src": @"key", @"code": @"126"}], @"Bogus": @[@{@"src": @"key", @"code": @"1"}],
                                                                @"B": @[@{@"src": @"key", @"code": @"999"}, @{@"src": @"pad", @"code": @"nope"}]},
                                                    @"modes": @{@"A": @"turbo"}, @"turbo_hz": @15, @"mouse_mode": @"right_stick", @"mouse_sens_x": @2.5, @"motion_source": @"keys",
                                                    @"sticks": @[@{@"deadzone": @0.1, @"inv_y": @YES}], @"rumble": @{@"swap": @YES, @"gain": @0.5}},
                                             @{@"controller": @"name:Xbox Wireless Controller"}]};
        im_config c; im_config_default(&c);
        assert(im_config_from_json(root, &c));
        const im_player *p2 = &c.player[1];
        assert(p2->keyboard && p2->mouse && p2->pad_kind == IM_PAD_INDEX && p2->pad_index == 2);
        assert(p2->bind[IM_A][0].src == IM_SRC_KEY && p2->bind[IM_A][0].code == 3 && p2->bind[IM_A][1].src == IM_SRC_MOUSE && p2->bind[IM_A][1].code == IM_MB_LEFT);
        assert(p2->bind[IM_A][2].src == IM_SRC_PAD && p2->bind[IM_A][2].code == IM_P_SOUTH && p2->bind[IM_TILT_UP][0].code == 126);
        assert(p2->bind[IM_B][0].src == IM_SRC_NONE && p2->bind[IM_X][0].src == IM_SRC_NONE);   // invalid codes dropped; the list is the whole mapping
        assert(p2->mode[IM_A] == IM_MODE_TURBO && p2->turbo_hz == 15 && p2->mouse_mode == IM_MOUSE_RSTICK && fabsf(p2->mouse_sens_x - 2.5f) < 1e-6f);
        assert(p2->motion_source == IM_MOTION_KEYS && fabsf(p2->stick[0].deadzone - 0.1f) < 1e-6f && p2->stick[0].inv_y && p2->stick[1].deadzone == 0);
        assert(p2->rumble_swap && fabsf(p2->rumble_gain - 0.5f) < 1e-6f && p2->rumble_on);
        assert(c.player[2].pad_kind == IM_PAD_NAME && !strcmp(c.player[2].pad_name, "Xbox Wireless Controller"));
        assert(same_player(&c.player[0], &want.player[0]));   // an empty player keeps its defaults
        assert(im_hotkey_of(&c, IM_SRC_KEY, 46) == IM_HK_MUTE && im_hotkey_of(&c, IM_SRC_PAD, IM_P_HOME) == IM_HK_RECENTER && im_hotkey_of(&c, IM_SRC_KEY, 53) < 0);   // the file's hotkeys replace them
        assert(!im_config_from_json((NSDictionary *)@[], &c));
        puts("t_input_json: ok");
    }
    return 0;
}
