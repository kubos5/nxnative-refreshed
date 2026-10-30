// Mac front end: with DM_WINDOW=1 open a window (CAMetalLayer, for the graphics backend to present frames) + keyboard, mouse and controllers → dm_input; the guest runs on a large-stack thread instead and the main thread belongs to AppKit.
// Without DM_WINDOW: the guest runs directly on the current thread, behaving the same as with no front end (windowless tests use this).
// The window is fullscreen-capable (the green button and ⌃⌘F); DM_FULLSCREEN=1 starts it that way, DM_FULLSCREEN_STYLE=borderless makes fullscreen a borderless window on the screen
// instead of a Space of its own. ⌘Q quits. DM_WINDOW_SIZE (WxH, fit, remember), DM_WINDOW_ASPECT=1 (resizes keep 16:9), DM_CURSOR (show, auto, hide), DM_BG_INPUT=1 (controllers play
// while another app is in front), DM_BG_MUTE=1 (silent then), DM_FOCUS_EVENTS=0 (the game is not told it lost focus): nxnative refreshed's window settings (dm/games/settings.tsv).
// Input (nxnative refreshed): every player's mapping comes from the launcher's input.json (DM_INPUT_CONFIG; input_map.h, dm/mac/InputModel.swift): any key, mouse button or wheel
// and any controller element can drive any Switch button, stick direction, shake or emulated tilt, per player, with hold / toggle / turbo, stick dead zones and curves, the mouse
// as the touchscreen, a stick or a gyro, emulated motion, per-player gyro and rumble tuning and hotkeys. Without input.json the defaults are nxnative's own map:
// Key map (Nintendo layout): WASD left stick, arrow keys D-pad, J=A K=B U=X I=Y, Q=L E=R, Z=ZL C=ZR, F=press left stick G=press right stick, Return=+ Tab=−, Space=shake the controller; the left mouse button is the touchscreen.
// Controllers: face buttons as on the iPhone, by position (right A, bottom B, top X, left Y) or on a Nintendo pad by its labels (pad_apple.h), shoulders L R, triggers ZL ZR, Menu + Options −, both sticks and their presses.
// Players: each controller is a player of its own (local co-op): the first one connected is player 1, together with the keyboard, the next player 2, and so on up to 8 (pad_slots.h).
// input.json can give any player the keyboard and the mouse, no controller, the n-th controller connected or a controller by name, and the others keep the automatic order;
// DM_PAD_MERGE=1 (or "merge" in input.json) merges every controller into player 1 instead, DM_KBD_PLAYER=own makes the keyboard player 1 on its own, with the controllers from player 2 on.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <GameController/GameController.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "hle.h"
#include "pad_slots.h"
#include "haptics_apple.h"
#include "motion_apple.h"
#include "motion_pro_mac.h"
#include "pad_apple.h"
#include "input_map.h"
#include "input_json.h"
#include "input_pad_apple.h"
#include <signal.h>
#include <math.h>

static CAMetalLayer *g_layer;
static int g_input_on = 1;   // main thread: the game window is key, so its keyboard, mouse and controllers reach the game (input_release / input_resume)
static int g_bg_input;       // DM_BG_INPUT=1: controllers keep playing while the window is not key
static int g_borderless;     // main thread: the window is in borderless fullscreen (DM_FULLSCREEN_STYLE=borderless)

void *front_metal_layer(void) { return (__bridge void *)g_layer; }
static _Atomic int g_screen_fps;   // the window's screen's maximumFramesPerSecond, kept up to date when the window moves to another screen
int front_screen_max_fps(void) { return g_screen_fps; }
static _Atomic int g_fullscreen;   // the window is in fullscreen (set when it has entered and when it has left)
int front_fullscreen(void) { return g_fullscreen; }   // nvn_mtl.m link_latency: frame latency 2 in fullscreen
// The screen's refresh rate matched to the game's frame rate in fullscreen (front_screen_match, from PR #79; DM_SCREEN_MATCH=0 turns it off). 60 fps on a 144 Hz screen cannot be paced
// evenly: the display link counts a tick on the refresh nearest each 1/60 s slot (nvn_mtl.m link_range), so frames stay up 2 and 3 refreshes in turn (13.9 / 20.8 ms) and Apple's HUD shows
// the frame interval jumping between them. In fullscreen, a screen whose rate is not a multiple of the game's switches to the mode of the same size with the highest rate that is (144 → 120 Hz
// for 60 and 30 fps), for this app only: macOS switches it back when the host quits, crashes included, and leaving fullscreen or that screen switches it back at once. A window keeps the
// screen's rate, because the switch changes the whole screen for every app and most external screens go black for a second or more. A screen with no such mode keeps the virtual ticks
static NSWindow *g_win; static _Atomic int g_match_want;   // the game's window; the frame rate to match (0 = not known yet), written by the present thread only
static CGDirectDisplayID g_match_id; static CGDisplayModeRef g_match_orig;   // main thread: the screen this host switched and its own mode (NULL = none switched)
static double mode_hz(CGDisplayModeRef m) { double hz = CGDisplayModeGetRefreshRate(m); return hz > 0 ? hz : 0; }   // 0 = not known (older built-in screens report none)
static int hz_multiple(double hz, int fps) { double k = round(hz / fps); return k >= 1 && fabs(hz / fps - k) < 0.01; }   // 59.94 Hz counts as 60
static CGError screen_set_mode(CGDirectDisplayID id, CGDisplayModeRef m) {   // for this app only (kCGConfigureForAppOnly)
    CGDisplayConfigRef cfg; CGError r = CGBeginDisplayConfiguration(&cfg);
    if (r != kCGErrorSuccess) return r;
    r = CGConfigureDisplayWithDisplayMode(cfg, id, m, NULL);
    if (r != kCGErrorSuccess) { CGCancelDisplayConfiguration(cfg); return r; }
    return CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
}
static void screen_match_restore(int on_it) {   // main thread: the screen this host switched gets its own mode again; on_it: the window is on that screen
    double hz = mode_hz(g_match_orig); CGError r = screen_set_mode(g_match_id, g_match_orig);
    LOG("front end: screen %s %.0f Hz", r == kCGErrorSuccess ? "back at" : "could not be switched back to", hz);
    if (r == kCGErrorSuccess && on_it && hz > 0) g_screen_fps = (int)round(hz);
    CGDisplayModeRelease(g_match_orig); g_match_orig = NULL;
}
static void screen_match_apply(void) {   // main thread: on a new frame rate, on entering and leaving fullscreen and on a move to another screen
    static int off = -1; if (off < 0) { const char *e = getenv("DM_SCREEN_MATCH"); off = e && !strcmp(e, "0"); if (off) LOG("front end: the screen keeps its refresh rate in fullscreen too (DM_SCREEN_MATCH=0)"); }
    NSScreen *scr = g_win.screen; int want = g_match_want, full = (g_win.styleMask & NSWindowStyleMaskFullScreen) != 0 || g_borderless;
    CGDirectDisplayID id = scr ? [scr.deviceDescription[@"NSScreenNumber"] unsignedIntValue] : kCGNullDirectDisplay;
    if (g_match_orig && (!full || id != g_match_id)) screen_match_restore(id == g_match_id);
    if (off || !full || want <= 0 || !scr) return;
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(id);
    if (!cur) return;
    double hz = mode_hz(cur);
    if (hz <= 0 || hz_multiple(hz, want)) {   // already a multiple, or not known
        if (g_match_orig && hz > 0) g_screen_fps = (int)round(hz);   // the screen this host switched: its rate from the mode, which maximumFramesPerSecond (the screen observer) may not show yet
        CGDisplayModeRelease(cur); return;
    }
    size_t w = CGDisplayModeGetWidth(cur), h = CGDisplayModeGetHeight(cur), pw = CGDisplayModeGetPixelWidth(cur), ph = CGDisplayModeGetPixelHeight(cur);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(id, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES});
    CGDisplayModeRef pick = NULL; double pick_hz = 0;
    for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i); double r = mode_hz(m);
        if (CGDisplayModeGetWidth(m) != w || CGDisplayModeGetHeight(m) != h || CGDisplayModeGetPixelWidth(m) != pw || CGDisplayModeGetPixelHeight(m) != ph || !CGDisplayModeIsUsableForDesktopGUI(m)) continue;
        if (hz_multiple(r, want) && r > pick_hz) { pick = m; pick_hz = r; }
    }
    if (!pick) LOG("front end: screen at %.0f Hz has no mode of this size at a multiple of %d Hz: frames are paced on the nearest refreshes", hz, want);
    else {
        CGError r = screen_set_mode(id, pick);
        LOG("front end: screen at %.0f Hz %s %.0f Hz for %d fps in fullscreen (DM_SCREEN_MATCH=0 keeps it)", hz, r == kCGErrorSuccess ? "switched to" : "could not be switched to", pick_hz, want);
        if (r == kCGErrorSuccess) { if (!g_match_orig) { g_match_orig = CGDisplayModeRetain(cur); g_match_id = id; } g_screen_fps = (int)round(pick_hz); }
    }
    if (modes) CFRelease(modes);
    CGDisplayModeRelease(cur);
}
void front_screen_match(int fps) {
    if (!g_layer || g_match_want == fps) return;   // no window (a windowless run's main thread runs the guest), or the rate as before
    g_match_want = fps; dispatch_async(dispatch_get_main_queue(), ^{ screen_match_apply(); });
}
// ---------- Input mapping (nxnative refreshed; input_map.h) ----------
// Every source is kept as it is held (g_keys, g_mbtn, each controller's elements), and each player's Switch controller is worked out from them with that player's bindings (im_eval)
// whenever one of its sources changes and on the input tick (200 Hz: turbo, the mouse as a stick, emulated motion, wheel notches). All of it runs on the main thread: AppKit's events,
// GameController's handlers (their default queue) and the tick. Each player goes to the host on its own path (dm_pad_set_player): the keyboard's player 1 is no longer dm_input_set's,
// so a keyboard can be any player's, or two players' with different keys
static im_config g_cfg;
static im_runtime g_rt[DM_PLAYERS];
static im_output g_out[DM_PLAYERS];
static im_emu g_emu[DM_PLAYERS];
static float g_mstick[DM_PLAYERS][2];   // the mouse as a stick, smoothed (y up)
static uint8_t g_keys[IM_KEY_CODES], g_hot_keys[IM_KEY_CODES];   // held keys; keys held for a hotkey (they do not reach the game)
static uint8_t g_mbtn[IM_MOUSE_CODES];
static double g_wheel_until[4];   // a wheel notch holds its code until then (seconds)
static float g_mdx, g_mdy;        // pointer movement since the last tick, points, y down
static int g_captured;            // the pointer is hidden and held still for the mouse as a stick or a gyro
static int g_motion_on = 1;       // DM_MOTION
static int g_pad_hotkeys;         // some hotkey is bound to a controller element
static double now_s(void) { return (double)now_ns() / 1e9; }

// The defaults, then input.json over them; the old switches when there is no input.json
static void input_config_load(void) {
    im_config_default(&g_cfg);
    const char *e = getenv("DM_MOTION"); g_motion_on = !(e && !atoi(e));
    const char *path = getenv("DM_INPUT_CONFIG");
    NSData *data = path && *path ? [NSData dataWithContentsOfFile:@(path)] : nil;
    NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (path && *path && ![root isKindOfClass:NSDictionary.class]) LOG("[RED] front end: input mapping %s cannot be read; using the default controls", path);
    if (im_config_from_json(root, &g_cfg)) LOG("front end: input mapping from %s", path);
    for (int h = 0; h < IM_HOTKEYS; h++) for (int i = 0; i < IM_HK_BINDS; i++) g_pad_hotkeys |= g_cfg.hotkey[h][i].src == IM_SRC_PAD;
    // The old switches, which a launch environment or env.txt may still set: they win over input.json
    if ((e = getenv("DM_PAD_MERGE")) && atoi(e)) g_cfg.merge = 1;
    if ((e = getenv("DM_KBD_PLAYER")) && !strcmp(e, "own") && !g_cfg.merge) g_cfg.player[0].pad_kind = IM_PAD_NONE;
    for (int p = 0; p < DM_PLAYERS; p++) {
        const im_player *c = &g_cfg.player[p];
        dm_haptics_apple_player(p, (dm_rumble_cfg){c->rumble_on, c->rumble_gain, c->rumble_low, c->rumble_high, c->rumble_min, c->rumble_swap});
    }
}
static int mouse_wants_capture(void) {   // a player reads the mouse as a stick or a gyro
    for (int p = 0; p < DM_PLAYERS; p++) { const im_player *c = &g_cfg.player[p]; if (c->mouse && (c->mouse_mode == IM_MOUSE_RSTICK || c->mouse_mode == IM_MOUSE_LSTICK || c->mouse_mode == IM_MOUSE_GYRO)) return 1; }
    return 0;
}
static int mouse_is_touch(void) {   // the left button touches the screen (a mouse player in touchscreen mode)
    for (int p = 0; p < DM_PLAYERS; p++) { const im_player *c = &g_cfg.player[p]; if (c->mouse && c->mouse_mode == IM_MOUSE_TOUCH) return 1; }
    return 0;
}

// Controllers: the ones with an extended gamepad profile, in the order they connected, each with the player it plays (-1: none)
#define MAX_PADS 16
static GCController *g_pads[MAX_PADS]; static int g_pad_player[MAX_PADS], g_npads;
static pad_slots g_slots;   // the automatic order (pad_slots.h): a reconnected controller gets its player back
static const char g_slot_block = 0;
static const char *pad_name(GCController *c) { return c.vendorName.UTF8String ?: "?"; }
static void npad_name(int p, char *out, size_t cap) { uint32_t id = dm_player_npad(p); if (id == 0x20) snprintf(out, cap, "handheld"); else snprintf(out, cap, "%u", id); }
static int pads_on(void) { return g_input_on || g_bg_input; }
static void hotkey(int h);
static uint8_t g_pad_hot[MAX_PADS][IM_PAD_CODES];   // a controller's elements held for a hotkey (they do not reach the game while held)
static void pad_hotkeys(int i) {   // a controller element bound to a hotkey runs it on its press
    if (!g_pad_hotkeys) return;
    GCController *c = g_pads[i]; im_inputs in = {0}; static im_player plain; static int ready; if (!ready) { im_player_default(&plain, 1); ready = 1; }
    im_pad_sample(c, &plain, &in);
    for (int code = 0; code < IM_PAD_CODES; code++) {
        int h = im_hotkey_of(&g_cfg, IM_SRC_PAD, code); if (h < 0) continue;
        int down = im_pad_is_stick(code) ? in.pad[code] >= 0.5f : in.pad_pressed[code];
        if (down && !g_pad_hot[i][code]) hotkey(h);
        g_pad_hot[i][code] = (uint8_t)down;
    }
}
static void gather(int p, im_inputs *in) {
    memset(in, 0, sizeof *in);
    const im_player *c = &g_cfg.player[p];
    if (g_input_on && c->keyboard) memcpy(in->key, g_keys, sizeof g_keys);
    if (g_input_on && c->mouse) { memcpy(in->mouse, g_mbtn, sizeof g_mbtn); in->mouse_stick[0] = g_mstick[p][0]; in->mouse_stick[1] = g_mstick[p][1]; }
    if (!pads_on()) return;
    for (int i = 0; i < g_npads; i++) if (g_pad_player[i] == p) {
        im_pad_sample(g_pads[i], c, in);
        for (int code = 0; code < IM_PAD_CODES; code++) if (g_pad_hot[i][code]) { in->pad[code] = 0; in->pad_pressed[code] = 0; }
    }
}
static void publish(int p) {
    im_inputs in; gather(p, &in);
    im_eval(&g_cfg.player[p], &in, &g_rt[p], now_s(), &g_out[p]);
    const im_output *o = &g_out[p];
    dm_pad_set_player(p, o->buttons, o->lx, o->ly, o->rx, o->ry);   // the shake bit counts on player 1's path; another player's shake is emulated motion (input_tick)
    if (o->pressed[IM_RECENTER] && !g_rt[p].latched[IM_RECENTER] && g_cfg.player[p].mode[IM_RECENTER] == IM_MODE_HOLD) { dm_motion_recenter(p); im_emu_reset(&g_emu[p]); }
    g_rt[p].latched[IM_RECENTER] = o->pressed[IM_RECENTER] && g_cfg.player[p].mode[IM_RECENTER] == IM_MODE_HOLD;
}
static void publish_all(void) { for (int p = 0; p < DM_PLAYERS; p++) publish(p); }
static void publish_keyboard(void) { for (int p = 0; p < DM_PLAYERS; p++) if (g_cfg.player[p].keyboard) publish(p); }
static void publish_mouse(void) { for (int p = 0; p < DM_PLAYERS; p++) if (g_cfg.player[p].mouse) publish(p); }

// Rumble and motion follow the controllers' players. A player with several controllers (merge, or a name two controllers share) rumbles the one moved last, as before
static void motion_xform(int p, float acc[3], float rot[3]) { (void)acc; if (p >= 0 && p < DM_PLAYERS) im_gyro_xform(&g_cfg.player[p], rot); }
static void pro_players_changed(GCController *gone) {
    int count = 0, player = -1;
    for (int i = 0; i < g_npads; i++) if (g_pads[i] != gone && [g_pads[i].productCategory isEqualToString:@"Switch Pro Controller"]) {
        count++; player = g_pad_player[i];
        if (player >= 0 && (g_cfg.player[player].motion_source != IM_MOTION_CONTROLLER || !g_motion_on)) player = -1;
    }
    dm_motion_pro_players(count, player);
}
static void pro_devices_changed(void) { pro_players_changed(nil); }
static void pad_changed(GCController *c) {
    if (!pads_on()) return;
    int i = 0; while (i < g_npads && g_pads[i] != c) i++;
    if (i == g_npads) return;
    pad_hotkeys(i);
    int p = g_pad_player[i]; if (p < 0) return;
    dm_haptics_apple_controller(p, c);
    publish(p);
}
// Home and Capture: without this macOS takes them as system gestures (Home opens the Games app); they reach the game only through a binding (or a hotkey)
static void pad_keep_system_buttons(GCController *c) { for (NSString *b in @[GCInputButtonHome, GCInputButtonShare]) c.physicalInputProfile.buttons[b].preferredSystemGestureState = GCSystemGestureStateDisabled; }
static int pad_matches(GCController *c, const char *name) {
    NSString *n = @(name);
    return n.length && ([c.vendorName caseInsensitiveCompare:n] == NSOrderedSame || [c.productCategory caseInsensitiveCompare:n] == NSOrderedSame);
}
// Who plays which controller: by name, then by connection order, then the automatic order among the players left on automatic (pad_slots.h, as before)
static void assign_pads(void) {
    for (int i = 0; i < g_npads; i++) g_pad_player[i] = -1;
    if (g_cfg.merge) { for (int i = 0; i < g_npads; i++) g_pad_player[i] = 0; return; }
    for (int p = 0; p < DM_PLAYERS; p++) if (g_cfg.player[p].pad_kind == IM_PAD_NAME)
        for (int i = 0; i < g_npads; i++) if (g_pad_player[i] < 0 && pad_matches(g_pads[i], g_cfg.player[p].pad_name)) { g_pad_player[i] = p; break; }
    for (int p = 0; p < DM_PLAYERS; p++) if (g_cfg.player[p].pad_kind == IM_PAD_INDEX) {
        int i = g_cfg.player[p].pad_index - 1;
        if (i >= 0 && i < g_npads && g_pad_player[i] < 0) g_pad_player[i] = p;
    }
    for (int p = 0; p < DM_PLAYERS; p++) {
        int keep = 0;
        for (int i = 0; i < g_npads; i++) keep |= (__bridge const void *)g_pads[i] == g_slots.owner[p] && g_pad_player[i] < 0 && g_cfg.player[p].pad_kind == IM_PAD_AUTO;
        if (g_slots.owner[p] && !keep) g_slots.owner[p] = NULL;   // its name stays: that controller gets this player back when it returns
        if (!g_slots.owner[p] && g_cfg.player[p].pad_kind != IM_PAD_AUTO) g_slots.owner[p] = &g_slot_block;   // not for the automatic order
    }
    for (int i = 0; i < g_npads; i++) if (g_pad_player[i] < 0) g_pad_player[i] = pad_slot_take(&g_slots, (__bridge const void *)g_pads[i], pad_name(g_pads[i]));
    for (int p = 0; p < DM_PLAYERS; p++) if (g_slots.owner[p] == &g_slot_block) g_slots.owner[p] = NULL;
}
// Called at start and on every connect / disconnect (gone: the controller that was just removed, nil on a connect)
static void pads_changed(GCController *gone) {
    int was[MAX_PADS]; GCController *before[MAX_PADS]; int n_before = g_npads;
    for (int i = 0; i < g_npads; i++) { before[i] = g_pads[i]; was[i] = g_pad_player[i]; }
    // the connected list, in connection order: the ones kept, then the new ones
    GCController *now[MAX_PADS]; int n = 0;
    for (int i = 0; i < g_npads; i++) if (g_pads[i] != gone && [GCController.controllers containsObject:g_pads[i]] && g_pads[i].extendedGamepad) now[n++] = g_pads[i];
    for (GCController *c in GCController.controllers) {
        if (c == gone || !c.extendedGamepad) continue;
        int seen = 0; for (int i = 0; i < n; i++) seen |= now[i] == c;
        if (!seen && n < MAX_PADS) now[n++] = c; else if (!seen) LOG("controller '%s' connected: %d controllers already, not used", pad_name(c), MAX_PADS);
    }
    for (int i = 0; i < MAX_PADS; i++) g_pads[i] = i < n ? now[i] : nil;
    g_npads = n;
    memset(g_pad_hot, 0, sizeof g_pad_hot);
    assign_pads();
    char nb[16];
    for (int j = 0; j < n_before; j++) {   // the ones that went away or changed player
        int k = 0; while (k < n && g_pads[k] != before[j]) k++;
        int now_p = k < n ? g_pad_player[k] : -2;
        if (now_p == was[j]) continue;
        if (was[j] >= 0) { dm_motion_detach(before[j], was[j]); }
        if (k == n) { before[j].extendedGamepad.valueChangedHandler = nil; if (was[j] >= 0) { npad_name(was[j], nb, sizeof nb); LOG("controller '%s' disconnected: player %d (npad %s) is free", pad_name(before[j]), was[j] + 1, nb); } }
    }
    for (int i = 0; i < n; i++) {
        GCController *c = g_pads[i]; int p = g_pad_player[i];
        int k = 0; while (k < n_before && before[k] != c) k++;
        int old_p = k < n_before ? was[k] : -2;
        if (old_p == -2) { pad_keep_system_buttons(c); c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; pad_changed(g.controller); }; }
        if (old_p == p) continue;
        npad_name(p < 0 ? 0 : p, nb, sizeof nb);
        if (p < 0) LOG("controller '%s' connected: no player takes it (all %d players are taken or set otherwise), not used", pad_name(c), DM_PLAYERS);
        else LOG("controller '%s' connected: player %d (npad %s)%s", pad_name(c), p + 1, nb, c.motion.hasRotationRate ? ", with motion (gyro)" : "");
        if (p >= 0 && g_motion_on && g_cfg.player[p].motion_source == IM_MOTION_CONTROLLER) dm_motion_attach(c, p);
    }
    uint32_t mask = 1;
    for (int p = 0; p < DM_PLAYERS; p++) {
        GCController *first = nil;
        for (int i = 0; i < n && !first; i++) if (g_pad_player[i] == p) first = g_pads[i];
        dm_haptics_apple_controller(p, first);
        if (first || g_cfg.player[p].keyboard || g_cfg.player[p].mouse) mask |= 1u << p;
    }
    dm_pad_players(mask);
    pro_players_changed(gone);
    publish_all();
}

// The mouse: as the touchscreen (front.h dm_touch_set), or captured (hidden and held still) to turn its movement into a stick or a gyro
static int g_mouse_down;   // the mouse holds the touch (DmGameView)
static void toast(NSString *msg);
static void capture_set(int on) {
    if (on == g_captured) return;
    g_captured = on;
    CGAssociateMouseAndMouseCursorPosition(!on);
    if (on) [NSCursor hide]; else [NSCursor unhide];
    g_mdx = g_mdy = 0;
    LOG("front end: pointer %s", on ? "captured (the mouse moves a stick or the gyro)" : "released");
    if (on) {
        NSString *key = nil;
        for (int i = 0; i < IM_HK_BINDS && !key; i++) if (g_cfg.hotkey[IM_HK_CAPTURE][i].src == IM_SRC_KEY) key = g_cfg.hotkey[IM_HK_CAPTURE][i].code == 53 ? @"Esc" : @"the capture hotkey";
        toast(key ? [NSString stringWithFormat:@"Mouse captured. Press %@ to release it", key] : @"Mouse captured");
    }
}
static void mouse_clear(void) {
    memset(g_mbtn, 0, sizeof g_mbtn); for (int i = 0; i < 4; i++) g_wheel_until[i] = 0;
    memset(g_mstick, 0, sizeof g_mstick); g_mdx = g_mdy = 0;
    if (g_mouse_down) { g_mouse_down = 0; dm_touch_set(NULL, 0); }
}

// The input tick: turbo, the mouse as a stick (its speed, smoothed), wheel notches, and emulated motion (tilt keys, the mouse as a gyro, another player's shake)
static NSTimer *g_tick;
static double g_tick_last;
static void input_tick(void) {
    double now = now_s(); float dt = g_tick_last > 0 ? (float)fmin(0.1, now - g_tick_last) : 0.005f; g_tick_last = now;
    if (dt <= 0) dt = 0.005f;
    for (int w = 0; w < 4; w++) if (g_mbtn[IM_WHEEL_UP + w] && now >= g_wheel_until[w]) g_mbtn[IM_WHEEL_UP + w] = 0;
    float mdx = g_mdx, mdy = g_mdy; g_mdx = g_mdy = 0;
    if (!g_input_on) mdx = mdy = 0;
    for (int p = 0; p < DM_PLAYERS; p++) {
        const im_player *c = &g_cfg.player[p];
        if (c->mouse && (c->mouse_mode == IM_MOUSE_RSTICK || c->mouse_mode == IM_MOUSE_LSTICK)) {
            // full tilt at 600 points per second at sensitivity 1
            float tx = mdx / dt / 600.f * (c->mouse_sens_x > 0 ? c->mouse_sens_x : 1), ty = -mdy / dt / 600.f * (c->mouse_sens_y > 0 ? c->mouse_sens_y : 1);
            if (c->mouse_inv_x) tx = -tx;
            if (c->mouse_inv_y) ty = -ty;
            tx = fmaxf(-1, fminf(1, tx)); ty = fmaxf(-1, fminf(1, ty));
            float a = fmaxf(0, fminf(0.95f, c->mouse_smooth));
            g_mstick[p][0] = g_mstick[p][0] * a + tx * (1 - a); g_mstick[p][1] = g_mstick[p][1] * a + ty * (1 - a);
            if (fabsf(g_mstick[p][0]) < 1e-3f) g_mstick[p][0] = 0;
            if (fabsf(g_mstick[p][1]) < 1e-3f) g_mstick[p][1] = 0;
        } else g_mstick[p][0] = g_mstick[p][1] = 0;
    }
    publish_all();
    if (!g_motion_on) return;
    for (int p = 0; p < DM_PLAYERS; p++) {
        const im_player *c = &g_cfg.player[p]; const im_output *o = &g_out[p]; im_emu *e = &g_emu[p];
        if (c->motion_source == IM_MOTION_OFF) continue;
        float tilt[4] = {o->target[IM_TILT_UP], o->target[IM_TILT_DOWN], o->target[IM_TILT_LEFT], o->target[IM_TILT_RIGHT]};
        float twist = fminf(1, o->target[IM_TWIST_RIGHT]) - fminf(1, o->target[IM_TWIST_LEFT]);
        int mouse_gyro = c->mouse && c->mouse_mode == IM_MOUSE_GYRO && g_input_on;
        int shake = p > 0 && o->pressed[IM_SHAKE];   // player 1 shakes through DM_BTN_SHAKE (hle_hid.c)
        const double cycle = 1.0 / 6.0;
        if (shake && !(now < e->shake_end)) { e->shake_t0 = now; e->shake_end = INFINITY; }
        else if (shake) e->shake_end = INFINITY;
        else if (e->shake_end == INFINITY) e->shake_end = e->shake_t0 + (floor((now - e->shake_t0) / cycle) + 1) * cycle;
        int shaking = now < e->shake_end;
        int keys = tilt[0] > 0 || tilt[1] > 0 || tilt[2] > 0 || tilt[3] > 0 || twist != 0;
        int emulated = c->motion_source == IM_MOTION_MOUSE || c->motion_source == IM_MOTION_KEYS || mouse_gyro;
        int returning = fabsf(e->pitch) > 0.01f || fabsf(e->roll) > 0.01f;
        if (!(emulated || keys || shaking || returning) || (!g_input_on && !emulated)) continue;
        if (!g_input_on) { keys = 0; tilt[0] = tilt[1] = tilt[2] = tilt[3] = 0; twist = 0; }
        im_player k = *c; if (!mouse_gyro && !keys) k.motion_source = IM_MOTION_KEYS;   // nothing holds it: back to flat at the tilt speed (or auto-center for the mouse)
        im_emu_step(&k, e, dt, tilt, twist, mouse_gyro ? mdx : 0, mouse_gyro ? mdy : 0, mouse_gyro);
        float acc[3], rot[3]; im_emu_sample(c, e, dt, shaking, now, acc, rot);
        dm_motion_set_emulated(p, acc, rot);
    }
}

// Keyboard: macOS key codes; the modifier keys come as flags changes, each side its own key (the device-dependent bits of NSEvent.modifierFlags, IOLLEvent.h NX_DEVICE*KEYMASK)
static void key_set(unsigned short c, int down) {
    if (c >= IM_KEY_CODES) return;
    int h = im_hotkey_of(&g_cfg, IM_SRC_KEY, c);
    if (h >= 0) {   // a hotkey's key runs it on its press and does not reach the game
        if (down && !g_hot_keys[c]) hotkey(h);
        g_hot_keys[c] = (uint8_t)down;
        return;
    }
    if (!g_input_on) return;
    if (g_keys[c] == down) return;
    g_keys[c] = (uint8_t)down;
    publish_keyboard();
}
static void on_flags(NSEvent *e) {
    NSUInteger f = e.modifierFlags; int down;
    switch (e.keyCode) {
        case 56: down = (f & 0x02) != 0; break;   case 60: down = (f & 0x04) != 0; break;     // left / right Shift
        case 59: down = (f & 0x01) != 0; break;   case 62: down = (f & 0x2000) != 0; break;   // left / right Control
        case 58: down = (f & 0x20) != 0; break;   case 61: down = (f & 0x40) != 0; break;     // left / right Option
        case 55: down = (f & 0x08) != 0; break;   case 54: down = (f & 0x10) != 0; break;     // left / right Command
        case 57: down = (f & NSEventModifierFlagCapsLock) != 0; break;
        case 63: down = (f & NSEventModifierFlagFunction) != 0; break;
        default: return;
    }
    key_set(e.keyCode, down);
}

// Focus: a window that is no longer key sees no key-up, mouse-up or controller release, so whatever is held when it loses focus (another app, the text box, minimized) would
// stay pressed in the game. The front end releases only what it pressed itself: scripted buttons and sticks have their own path, and the touch is also DM_KEYS / DM_CTL's (hle_hid.c).
// Out of focus a controller's changes are ignored (unless DM_BG_INPUT=1), so back in focus each controller is read as it is now (a button still held, a stick still deflected)
static void input_release(void) {
    g_input_on = 0;
    capture_set(0);
    if (!g_bg_input) dm_motion_pro_active(0);
    memset(g_keys, 0, sizeof g_keys); memset(g_hot_keys, 0, sizeof g_hot_keys);
    mouse_clear();
    publish_all();
}
static void input_resume(void) {
    g_input_on = 1;
    dm_motion_pro_active(1);
    publish_all();
}
static void pads_start(void) {
    LOG("front end: %s", g_cfg.merge ? "every controller is player 1" : g_cfg.player[0].pad_kind == IM_PAD_NONE ? "the keyboard is player 1, the controllers from player 2 on"
                                                                     : "each controller is a player of its own, the keyboard plays with player 1");
    for (int p = 0; p < DM_PLAYERS; p++) {
        const im_player *c = &g_cfg.player[p];
        if (!g_cfg.loaded || (p && !c->keyboard && !c->mouse && c->pad_kind == IM_PAD_AUTO && c->motion_source == IM_MOTION_CONTROLLER)) continue;
        static const char *pads[] = {"automatic", "none", "by connection order", "by name"}, *mice[] = {"off", "touchscreen", "right stick", "left stick", "gyro"},
                          *motion[] = {"controller gyro", "off", "mouse", "tilt keys"};
        LOG("front end: player %d: keyboard %s, mouse %s (%s), controller %s%s%s, motion %s", p + 1, c->keyboard ? "on" : "off", c->mouse ? "on" : "off", mice[c->mouse_mode],
            pads[c->pad_kind], c->pad_kind == IM_PAD_NAME ? " " : "", c->pad_kind == IM_PAD_NAME ? c->pad_name : "", motion[c->motion_source]);
    }
    dm_motion_xform = motion_xform;
    pads_changed(nil);
    dm_motion_pro_start(pro_devices_changed);
}

// Mouse as a single-point touchscreen (front.h dm_touch_set): left button down / drag = finger 0, release = lifted. The content view takes the clicks,
// not a window-wide event monitor, so clicks on the title bar, the window buttons and the resize edges still reach AppKit.
// Its other buttons and the wheel drive their bindings; with the mouse as a stick or a gyro, a click in the game captures the pointer first
static int g_cursor_mode;   // DM_CURSOR: 0 show, 1 hide when idle, 2 hide
static double g_cursor_moved;
static void mouse_button(int code, int down) {
    if (code < 0 || code >= IM_MOUSE_CODES) return;
    int h = im_hotkey_of(&g_cfg, IM_SRC_MOUSE, code);
    if (h >= 0) { if (down) hotkey(h); return; }
    if (!g_input_on || g_mbtn[code] == down) return;
    g_mbtn[code] = (uint8_t)down;
    publish_mouse();
}
static int other_button(NSInteger n) { return n == 2 ? IM_MB_MIDDLE : n >= 3 && n <= 7 ? IM_MB_4 + (int)n - 3 : -1; }   // buttons 3..7 are mouse buttons 4..8
@interface DmGameView : NSView @end
@implementation DmGameView
- (BOOL)acceptsFirstMouse:(NSEvent *)e { (void)e; return NO; }
- (void)mouseDown:(NSEvent *)e {
    if (!g_input_on) return;
    if (mouse_wants_capture() && !g_captured) { capture_set(1); return; }   // the click that captures does nothing else
    if (mouse_is_touch() && !g_captured) { [self touchAt:e]; return; }
    mouse_button(IM_MB_LEFT, 1);
}
- (void)mouseDragged:(NSEvent *)e {
    [self moved:e];
    if (g_mouse_down) [self touchAt:e];
}
- (void)touchAt:(NSEvent *)e {
    if (!g_input_on) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil]; NSSize b = self.bounds.size;
    double w = b.width, h = b.height;
    if (w <= 0 || h <= 0) return;
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;   // the centered 16:9 picture the present fits into the view, as on the iPhone (DmGamepad.m)
    double x0 = (b.width - w) / 2, y0 = (b.height - h) / 2;
    dm_touch t = {0, (float)fmin(fmax((p.x - x0) / w, 0), 0.999), (float)fmin(fmax(1 - (p.y - y0) / h, 0), 0.999)};   // The AppKit view origin is at bottom left, the touchscreen origin is at top left
    dm_touch_set(&t, 1); g_mouse_down = 1;
}
- (void)mouseUp:(NSEvent *)e { (void)e; if (g_mouse_down) { g_mouse_down = 0; dm_touch_set(NULL, 0); } else mouse_button(IM_MB_LEFT, 0); }
- (void)rightMouseDown:(NSEvent *)e { (void)e; if (mouse_wants_capture() && !g_captured && g_input_on) { capture_set(1); return; } mouse_button(IM_MB_RIGHT, 1); }
- (void)rightMouseUp:(NSEvent *)e { (void)e; mouse_button(IM_MB_RIGHT, 0); }
- (void)otherMouseDown:(NSEvent *)e { mouse_button(other_button(e.buttonNumber), 1); }
- (void)otherMouseUp:(NSEvent *)e { mouse_button(other_button(e.buttonNumber), 0); }
- (void)rightMouseDragged:(NSEvent *)e { [self moved:e]; }
- (void)otherMouseDragged:(NSEvent *)e { [self moved:e]; }
- (void)mouseMoved:(NSEvent *)e { [self moved:e]; }
- (void)moved:(NSEvent *)e {
    g_cursor_moved = now_s();
    if (g_input_on && g_captured) { g_mdx += (float)e.deltaX; g_mdy += (float)e.deltaY; }
}
- (void)scrollWheel:(NSEvent *)e {
    if (!g_input_on) return;
    double s = e.isDirectionInvertedFromDevice ? -1 : 1, dy = e.scrollingDeltaY * s, dx = e.scrollingDeltaX * s;
    double hold = 0.08, now = now_s();
    int codes[2] = {dy > 0.5 ? IM_WHEEL_UP : dy < -0.5 ? IM_WHEEL_DOWN : -1, dx > 0.5 ? IM_WHEEL_LEFT : dx < -0.5 ? IM_WHEEL_RIGHT : -1};
    for (int i = 0; i < 2; i++) if (codes[i] >= 0) {
        int h = im_hotkey_of(&g_cfg, IM_SRC_MOUSE, codes[i]);
        if (h >= 0) { if (now >= g_wheel_until[codes[i] - IM_WHEEL_UP]) hotkey(h); g_wheel_until[codes[i] - IM_WHEEL_UP] = now + hold; continue; }
        g_wheel_until[codes[i] - IM_WHEEL_UP] = now + hold;
        if (!g_mbtn[codes[i]]) { g_mbtn[codes[i]] = 1; publish_mouse(); }
    }
}
- (void)resetCursorRects {
    if (g_cursor_mode != 2) return;
    static NSCursor *blank; if (!blank) blank = [[NSCursor alloc] initWithImage:[[NSImage alloc] initWithSize:NSMakeSize(1, 1)] hotSpot:NSZeroPoint];
    [self addCursorRect:self.bounds cursor:blank];
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *t in self.trackingAreas) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
// The drawable follows the view in pixels: a layer assigned to a layer-backed view kept the drawable at the first window's 1280x720 in fullscreen too, so the game picture was
// scaled down to it and up again by the compositor
- (void)fitDrawable {
    CAMetalLayer *l = (CAMetalLayer *)self.layer; if (![l isKindOfClass:CAMetalLayer.class] || !self.window) return;
    l.contentsScale = self.window.backingScaleFactor;
    NSSize px = [self convertSizeToBacking:self.bounds.size]; if (px.width < 1 || px.height < 1 || CGSizeEqualToSize(l.drawableSize, px)) return;
    l.drawableSize = px; LOG("front end: drawable %.0fx%.0f", px.width, px.height);
}
- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self fitDrawable]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self fitDrawable]; }
@end
// A borderless window can take the keyboard (AppKit's default for one without a title bar is no)
@interface DmGameWindow : NSWindow @end
@implementation DmGameWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

// A short message over the game (hotkeys, the captured pointer), fading out after a moment
static NSTextField *g_toast; static uint64_t g_toast_gen;
static void toast(NSString *msg) {
    if (!g_win) return;
    NSView *cv = g_win.contentView;
    if (!g_toast) {
        g_toast = [NSTextField labelWithString:@""];
        g_toast.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold]; g_toast.textColor = NSColor.whiteColor; g_toast.alignment = NSTextAlignmentCenter;
        g_toast.wantsLayer = YES; g_toast.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.72].CGColor; g_toast.layer.cornerRadius = 9;
        g_toast.drawsBackground = NO; g_toast.bezeled = NO;
    }
    if (g_toast.superview != cv) [cv addSubview:g_toast];
    g_toast.stringValue = msg; [g_toast sizeToFit];
    NSSize s = g_toast.frame.size; s.width += 28; s.height += 12;
    g_toast.frame = NSMakeRect(floor((cv.bounds.size.width - s.width) / 2), cv.bounds.size.height - s.height - 24, s.width, s.height);
    g_toast.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
    g_toast.alphaValue = 1; g_toast.hidden = NO;
    uint64_t gen = ++g_toast_gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen != g_toast_gen) return;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) { ctx.duration = 0.35; g_toast.animator.alphaValue = 0; } completionHandler:nil];
    });
}

// Fullscreen: macOS's own (a Space of its own, the green button) or borderless (the window covers the screen at once, menu bar and Dock hidden), DM_FULLSCREEN_STYLE
static int g_fs_borderless; static NSRect g_bl_frame; static NSWindowStyleMask g_bl_style;
static void borderless_toggle(void) {
    if (!g_win) return;
    if (!g_borderless) {
        if (g_win.styleMask & NSWindowStyleMaskFullScreen) return;
        g_bl_frame = g_win.frame; g_bl_style = g_win.styleMask;
        NSScreen *scr = g_win.screen ?: NSScreen.mainScreen;
        g_win.styleMask = NSWindowStyleMaskBorderless;
        NSApp.presentationOptions = NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
        [g_win setFrame:scr.frame display:YES];
        g_borderless = 1; g_fullscreen = 1;
        LOG("front end: borderless fullscreen on %.0fx%.0f", scr.frame.size.width, scr.frame.size.height);
    } else {
        g_win.styleMask = g_bl_style; NSApp.presentationOptions = NSApplicationPresentationDefault;
        [g_win setFrame:g_bl_frame display:YES];
        g_borderless = 0; g_fullscreen = 0;
        LOG("front end: borderless fullscreen off");
    }
    [g_win makeKeyAndOrderFront:nil];
    g_layer.contentsScale = g_win.backingScaleFactor;
    screen_match_apply();
}
static void fullscreen_toggle(void) { if (g_fs_borderless) borderless_toggle(); else [g_win toggleFullScreen:nil]; }
@interface DmActions : NSObject @end
@implementation DmActions
- (void)toggleGameFullScreen:(id)sender { (void)sender; fullscreen_toggle(); }
@end

static void hotkey(int h) {
    switch (h) {
        case IM_HK_FULLSCREEN: fullscreen_toggle(); break;
        case IM_HK_CAPTURE:
            if (g_captured) capture_set(0);
            else if (mouse_wants_capture() && g_input_on) capture_set(1);
            break;
        case IM_HK_MUTE: { static int muted; muted = !muted; dm_audio_mute(1, muted); toast(muted ? @"Sound off" : @"Sound on"); break; }
        case IM_HK_VOL_UP: case IM_HK_VOL_DOWN: {
            float v = dm_audio_volume() + (h == IM_HK_VOL_UP ? 0.1f : -0.1f); v = fmaxf(0, fminf(2, roundf(v * 10) / 10));
            dm_audio_volume_set(v); toast([NSString stringWithFormat:@"Volume %.0f %%", v * 100]); break;
        }
        case IM_HK_RECENTER: for (int p = 0; p < DM_PLAYERS; p++) { dm_motion_recenter(p); im_emu_reset(&g_emu[p]); } toast(@"Motion recentered"); break;
        case IM_HK_HUD: {
            if (!g_layer) break;
            int on = g_layer.developerHUDProperties == nil;
            g_layer.developerHUDProperties = on ? @{@"mode": @"default"} : nil;
            toast(on ? @"Performance HUD on" : @"Performance HUD off"); break;
        }
        case IM_HK_QUIT: [NSApp terminate:nil]; break;
    }
}

typedef struct { void (*fn)(void); } guest_arg;
static void *guest_tramp(void *p) {
    static char alt[65536];                       // The signal alternate stack is per thread; crash printing must also work on the guest thread
    stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);
    ((guest_arg *)p)->fn(); LOG("guest thread finished"); exit(0);
}

// Metal reads MTL_HUD_ENABLED when the process makes its first device, which can be before the window: set from DM_METAL_HUD before main (set in front_run, the HUD did not show)
__attribute__((constructor)) static void hud_env(void) { front_hud_env(); }
static int env_on(const char *k, int def) { const char *e = getenv(k); return e && *e ? atoi(e) != 0 : def; }
// DM_WINDOW_SIZE: WxH (the content's size in points), fit (the largest 16:9 that fits 85 % of the screen) or remember (the last frame, saved by AppKit); 1280x720 by default
static NSRect window_rect(int *remember) {
    const char *e = getenv("DM_WINDOW_SIZE"); int w = 1280, h = 720; *remember = 0;
    NSRect vis = NSScreen.mainScreen.visibleFrame;
    if (e && !strcmp(e, "fit")) { double fw = vis.size.width * 0.85, fh = vis.size.height * 0.85; if (fw / fh > 16.0 / 9.0) fw = fh * 16 / 9; else fh = fw * 9 / 16; w = (int)fw; h = (int)fh; }
    else if (e && !strcmp(e, "remember")) *remember = 1;
    else if (e && sscanf(e, "%dx%d", &w, &h) == 2 && w >= 320 && h >= 180) {}
    else if (e && *e) LOG("[RED] front end: DM_WINDOW_SIZE=%s is not WxH, fit or remember: 1280x720", e);
    if (w < 320 || h < 180) { w = 1280; h = 720; }
    if (w > vis.size.width || h > vis.size.height) { double k = fmin(vis.size.width / w, vis.size.height / h); w = (int)(w * k); h = (int)(h * k); }
    return NSMakeRect(0, 0, w, h);
}
void front_run(void (*guest)(void)) {
    // A game: tell macOS its work is latency-critical, so the system does not trade its frame time for power while the frame rate is capped
    static id activity; activity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical reason:@"game"];
    if (!getenv("DM_WINDOW")) { guest(); return; }
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        input_config_load();
        g_bg_input = env_on("DM_BG_INPUT", 0);
        int bg_mute = env_on("DM_BG_MUTE", 0), focus_events = env_on("DM_FOCUS_EVENTS", 1);
        const char *fst = getenv("DM_FULLSCREEN_STYLE"); g_fs_borderless = fst && !strcmp(fst, "borderless");
        const char *cur = getenv("DM_CURSOR"); g_cursor_mode = cur && !strcmp(cur, "hide") ? 2 : cur && !strcmp(cur, "auto") ? 1 : 0;
        int remember; NSRect r = window_rect(&remember);
        NSWindow *win = [[DmGameWindow alloc] initWithContentRect:r
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.title = @DM_GAME_NAME;   // the game profile's name (game name label)
        // Fullscreen: without FullScreenPrimary the green button only zooms the window. The present path already scales
        // the game picture to fit the drawable with black bars around it, so fullscreen keeps the game's aspect ratio.
        win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
        win.acceptsMouseMovedEvents = YES;
        if (env_on("DM_WINDOW_ASPECT", 0)) { win.contentAspectRatio = NSMakeSize(16, 9); LOG("front end: the window keeps 16:9 when resized (DM_WINDOW_ASPECT)"); }
        win.contentMinSize = NSMakeSize(320, 180);
        NSView *v = win.contentView = [[DmGameView alloc] initWithFrame:r];
        v.wantsLayer = YES;
        g_layer = [CAMetalLayer layer];
        g_layer.device = MTLCreateSystemDefaultDevice();
        g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_layer.contentsScale = win.backingScaleFactor;
        if (getenv("DM_METAL_HUD") && atoi(getenv("DM_METAL_HUD"))) { g_layer.developerHUDProperties = @{@"mode": @"default"}; LOG("front end: Metal performance HUD on (DM_METAL_HUD)"); }   // Apple's HUD over the game: frame rate, frame and GPU time, memory
        v.layer = g_layer; [(DmGameView *)v fitDrawable];
        [win center];
        if (remember) { win.frameAutosaveName = @"nxnative game window"; LOG("front end: the window opens where it was last (DM_WINDOW_SIZE=remember)"); }
        else LOG("front end: window %.0fx%.0f", r.size.width, r.size.height);
        [win makeKeyAndOrderFront:nil];
        g_screen_fps = (int)(win.screen ?: NSScreen.mainScreen).maximumFramesPerSecond;
        g_win = win;
        [NSApp activateIgnoringOtherApps:YES];
        // A host another process starts (scripts/regress.py) is not activated (its focus state stays 2), so its window opened wherever it landed in the window order, and behind
        // another app's window macOS fires its display link about once a second: Breath of the Wild stepped up to 3 vsyncs at boot and never came back (20 fps runs).
        // DM_WINDOW_TOP=1 orders it in front without activation and keeps it above other apps' windows; the log names every change of the window's visibility either way
        if (getenv("DM_WINDOW_TOP") && atoi(getenv("DM_WINDOW_TOP"))) { win.level = NSFloatingWindowLevel; [win orderFrontRegardless]; LOG("front end: window kept in front (DM_WINDOW_TOP)"); }
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidChangeOcclusionStateNotification object:win queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            (void)n; static int vis = -1; int v = (win.occlusionState & NSWindowOcclusionStateVisible) != 0; if (v == vis) return; vis = v;
            if (v) LOG("front end: window visible"); else LOG("front end: window covered (its display link fires about once a second: frame times measure nothing)"); }];
        // Main menu: AppKit runs ⌘ shortcuts only through menu items, so ⌘Q quits and ⌃⌘F toggles fullscreen from here (AppKit shows the item as Globe-F and keeps ⌃⌘F as a hidden twin)
        static DmActions *actions; actions = [DmActions new];
        NSMenu *bar = [NSMenu new], *app = [NSMenu new], *wm = [[NSMenu alloc] initWithTitle:@"Window"];
        [[bar addItemWithTitle:@"" action:nil keyEquivalent:@""] setSubmenu:app];
        [app addItemWithTitle:@"Quit " DM_GAME_NAME action:@selector(terminate:) keyEquivalent:@"q"];
        [[bar addItemWithTitle:@"Window" action:nil keyEquivalent:@""] setSubmenu:wm];
        NSMenuItem *fs = [wm addItemWithTitle:@"Enter Full Screen" action:@selector(toggleGameFullScreen:) keyEquivalent:@"f"];
        fs.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand; fs.target = actions;
        [wm addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
        NSApp.mainMenu = bar;
        const char *fsenv = getenv("DM_FULLSCREEN");   // 1 (or any value but 0): start in fullscreen; 0, the settings window's Window, or unset: a window
        if (fsenv && strcmp(fsenv, "0")) dispatch_async(dispatch_get_main_queue(), ^{ fullscreen_toggle(); });
        if (g_bg_input) { GCController.shouldMonitorBackgroundEvents = YES; LOG("front end: controllers play while the window is in the background (DM_BG_INPUT)"); }
        for (NSNotificationName nm in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification])
            [NSNotificationCenter.defaultCenter addObserverForName:nm object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                GCController *c = n.object; int conn = n.name == GCControllerDidConnectNotification;
                if (!c.extendedGamepad || g_cfg.merge) LOG("controller %s: %s%s", conn ? "connected" : "disconnected", pad_name(c), c.extendedGamepad ? "" : " (no extended gamepad profile: not used)");
                pads_changed(conn ? nil : c); }];
        dm_haptics_apple_init();
        pads_start();
        g_tick = [NSTimer timerWithTimeInterval:0.005 repeats:YES block:^(NSTimer *t) { (void)t; input_tick(); }];
        g_tick.tolerance = 0.001;
        [NSRunLoop.mainRunLoop addTimer:g_tick forMode:NSRunLoopCommonModes];
        if (g_cursor_mode == 1) {   // hide the pointer after 2 s without moving over the game, until it moves again
            NSTimer *idle = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
                (void)t; static int hidden;
                NSPoint p = [g_win.contentView convertPoint:g_win.mouseLocationOutsideOfEventStream fromView:nil];
                int inside = g_win.isKeyWindow && NSPointInRect(p, g_win.contentView.bounds);
                if (inside && now_s() - g_cursor_moved > 2) { if (!hidden) { [NSCursor setHiddenUntilMouseMoves:YES]; hidden = 1; } } else hidden = 0;
            }];
            [NSRunLoop.mainRunLoop addTimer:idle forMode:NSRunLoopCommonModes];
        }
        if (g_cursor_mode) LOG("front end: the pointer %s over the game (DM_CURSOR)", g_cursor_mode == 2 ? "is hidden" : "hides when idle");
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *e) {
            if (e.window != win) return e;   // Only swallow keys for the game window; other windows such as the software keyboard input box receive typing as usual
            if (e.type == NSEventTypeFlagsChanged) { on_flags(e); return e; }
            if (e.type == NSEventTypeKeyDown && (e.modifierFlags & NSEventModifierFlagCommand)) return e;   // ⌘ shortcuts go to the menu; a key released while ⌘ is held still reaches the game, or it would stay pressed
            if (!e.isARepeat) key_set(e.keyCode, e.type == NSEventTypeKeyDown);
            return nil;   // Swallow it to avoid the system beep
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:win queue:nil
                                                      usingBlock:^(NSNotification *n) { (void)n; exit(0); }];
        // Lifecycle (hle.h / dm.h): focus lost → 2, focus regained → 1; minimized → 3 + audio paused + GPU suspended, restored → resume (followed by focus regained → 1).
        // Input is released when the window stops being key (and when it is minimized) and taken up again when it is key again
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:NSWindowDidChangeScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; if (win.screen) { g_screen_fps = (int)win.screen.maximumFramesPerSecond; g_layer.contentsScale = win.backingScaleFactor; } screen_match_apply(); }];
        // Entering and leaving fullscreen: the layer is layer-backed, so its frame (and with it the drawable) follows the
        // content view by itself; only the scale factor has to be carried over to the screen the window ended up on. The screen's rate is matched in fullscreen only (screen_match_apply)
        [nc addObserverForName:NSWindowDidEnterFullScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; g_fullscreen = 1; g_layer.contentsScale = win.backingScaleFactor; screen_match_apply(); }];
        [nc addObserverForName:NSWindowDidExitFullScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; g_fullscreen = 0; g_layer.contentsScale = win.backingScaleFactor; screen_match_apply(); }];
        [nc addObserverForName:NSWindowDidResignKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) {
            (void)n; input_release(); if (bg_mute) dm_audio_mute(2, 1);
            if (!win.miniaturized && focus_events) dm_focus_set(2); }];
        [nc addObserverForName:NSWindowDidBecomeKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; input_resume(); dm_audio_mute(2, 0); dm_focus_set(1); }];
        [nc addObserverForName:NSWindowDidMiniaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; input_release(); dm_focus_set(3); dm_audio_suspend(1); dm_gfx_suspend(1); }];
        [nc addObserverForName:NSWindowDidDeminiaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_gfx_suspend(0); dm_audio_suspend(0); dm_focus_set(focus_events ? 2 : 1); }];
        if (!focus_events) LOG("front end: the game is not told when the window loses focus (DM_FOCUS_EVENTS=0)");
        if (bg_mute) LOG("front end: silent while the window is in the background (DM_BG_MUTE)");
        // Guest thread: 64 MiB stack (the Switch main thread stack is specified by npdm; the host gives plenty)
        static guest_arg ga; ga.fn = guest;
        pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 64u << 20);
        pthread_t th; if (pthread_create(&th, &a, guest_tramp, &ga)) die("pthread_create guest");
        [NSApp run];
    }
}

// Progress screen of the prepare step (front.h front_progress): a dark view over the game's, the title, a bar and a count, centered; AppKit views, so it draws while the game's thread waits
static NSView *g_prog; static NSTextField *g_prog_title, *g_prog_count; static NSProgressIndicator *g_prog_bar;
static NSTextField *prog_label(NSRect r, CGFloat size, NSFontWeight w, NSColor *c) {
    NSTextField *t = [NSTextField labelWithString:@""]; t.frame = r; t.alignment = NSTextAlignmentCenter; t.textColor = c;
    t.font = [NSFont monospacedDigitSystemFontOfSize:size weight:w]; return t;
}
void front_progress(const char *title, long done, long total) {
    if (!g_layer) return;
    NSString *tt = title ? @(title) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!tt) { [g_prog removeFromSuperview]; g_prog = nil; return; }
        if (!g_prog) {
            NSView *cv = g_win.contentView;
            g_prog = [[NSView alloc] initWithFrame:cv.bounds]; g_prog.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            g_prog.wantsLayer = YES; g_prog.layer.backgroundColor = [NSColor colorWithWhite:0.06 alpha:0.94].CGColor;
            NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(floor((cv.bounds.size.width - 400) / 2), floor((cv.bounds.size.height - 96) / 2), 400, 96)];
            box.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
            g_prog_title = prog_label(NSMakeRect(0, 62, 400, 30), 20, NSFontWeightSemibold, NSColor.whiteColor);
            g_prog_bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 36, 360, 20)];
            g_prog_bar.style = NSProgressIndicatorStyleBar; g_prog_bar.indeterminate = NO; g_prog_bar.minValue = 0;
            g_prog_count = prog_label(NSMakeRect(0, 4, 400, 22), 13, NSFontWeightRegular, [NSColor colorWithWhite:0.72 alpha:1]);
            [box addSubview:g_prog_title]; [box addSubview:g_prog_bar]; [box addSubview:g_prog_count]; [g_prog addSubview:box];
            [cv addSubview:g_prog];
        }
        g_prog_title.stringValue = tt; g_prog_bar.maxValue = total > 0 ? (double)total : 1; g_prog_bar.doubleValue = (double)done;
        g_prog_count.stringValue = [NSString stringWithFormat:@"%@ of %@", [NSNumberFormatter localizedStringFromNumber:@(done) numberStyle:NSNumberFormatterDecimalStyle],
                                    [NSNumberFormatter localizedStringFromNumber:@(total) numberStyle:NSNumberFormatterDecimalStyle]];
    });
}

// Software keyboard input box (front.h): the main thread shows an NSAlert + text field and the guest thread waits synchronously for the result. Not shown in windowless mode (returns -1, the caller treats it as cancel)
extern int g_swkbd_min_chars;   // hle_swkbd.c: this input's minimum length from ShowKeyboardArg; the applet keeps OK disabled until the text is long enough
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    if (!g_layer) return -1;
    __block int r = 0;
    __block NSString *text = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        // The box takes the keyboard and the mouse, so the game window never sees the key-up of the button or the touch-up of the click that opened it: nothing may stay pressed
        // while it is up, or the game reads the stuck button / touch the moment the box closes (Stardew Valley's character creation re-opened the keyboard endlessly)
        memset(g_keys, 0, sizeof g_keys); memset(g_hot_keys, 0, sizeof g_hot_keys); mouse_clear(); capture_set(0); publish_all();
        dm_touch_set(NULL, 0);
        int min_chars = g_swkbd_min_chars > 0 ? g_swkbd_min_chars : 0;
        NSString *info = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
        for (;;) {
            NSAlert *a = [NSAlert new];
            a.messageText = title && *title ? @(title) : @"Input";
            a.informativeText = info;
            [a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Cancel"];
            NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
            f.stringValue = text ?: (initial ? @(initial) : @"");
            if (guide && *guide) f.placeholderString = @(guide);
            a.accessoryView = f; a.window.initialFirstResponder = f;
            r = [a runModal] == NSAlertFirstButtonReturn;
            text = f.stringValue;
            if (!r || (int)text.length >= min_chars) break;
            // On hardware the applet would not have accepted the shorter text (OK stayed disabled); a game that rejects it re-opens the keyboard for ever, so the box comes back with the rule instead
            info = [info stringByAppendingFormat:@"\nAt least %d characters are needed here.", min_chars];
        }
    });
    if (!r) return 0;
    (void)max_chars;                              // Truncation is done uniformly in hle_swkbd.c in UTF-16 units
    snprintf(out, out_cap, "%s", text.UTF8String);
    return 1;
}
