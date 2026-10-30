// nxnative refreshed: what the settings window's Test page (dm/mac/TestPage.swift) reads and drives with the host's own code, so it shows what the game will get:
// input_map.h and input_pad_apple.h (a player's controls as Switch buttons and sticks), motion_pro.h (a Pro Controller's sensors, which GameController reports as zeroes
// on macOS) and switch_rumble.h (HD Rumble on a Nintendo controller, as the host sends it). pack_app.py gives this header to swiftc as the launcher's bridging header
// and links launcher_bridge.m; test_launcher_storage.py does the same.
#pragma once
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include <stdint.h>

// One player's Switch controller as the game would read it: NpadButton bits (dm_input.h DM_BTN_*) and sticks (-32767..32767, y up), and the motion inputs held
typedef struct { uint64_t buttons; int32_t lx, ly, rx, ry; uint8_t shake, tilt_up, tilt_down, tilt_left, tilt_right, twist_left, twist_right, walk, recenter; } dm_test_output;
// The mapping: the input.json the window writes (InputConfig.hostJSON()); 0 when it cannot be read (the defaults stay)
int dm_test_config(NSData *json);
// keys: 128 macOS key codes held; mouse: 12 input_map.h mouse codes held; controllers: the ones this player plays. Toggles and turbo keep their state per player
void dm_test_eval(int player, const uint8_t *keys, const uint8_t *mouse, NSArray<GCController *> *controllers, dm_test_output *out);

// Nintendo controllers' HID devices (Pro Controller, Joy-Con), listed in the order they were found
int dm_test_switch_count(void);
int dm_test_switch_info(int index, char *name, int cap);   // the product ID (0x2009 Pro Controller, 0x2006 / 0x2007 Joy-Con L / R), 0 for none; name: "Pro Controller · Bluetooth"
int dm_test_switch_motion(int index, float acc[3], float rot[3]);   // a Pro Controller's latest sample (G, gravity's direction; rad/s), 1 while it reports
// HD Rumble: each motor's amplitude_low, frequency_low, amplitude_high, frequency_high; paced as the host paces it (at most every 30 ms, refreshed every 50 ms)
void dm_test_switch_rumble(int index, const float left[4], const float right[4]);
void dm_test_switch_stop(void);   // every Nintendo controller still
