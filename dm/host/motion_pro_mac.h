// Mac-only Pro Controller motion transport: it reads the controller's reports, and sends it only the command that switches its IMU on (pro_enable_imu). All callbacks and routing run on the main run loop, alongside front_mac.m's player slots.
// Workaround for macOS's zero-only Pro GCMotion: the OS driver cannot be fixed here, but its underlying reports contain the IMU samples (#296).
// A separate buffer / decoder belongs to each retained IOHIDDevice. Disconnect or ambiguity clears only the raw source; GameController keeps its buttons and motion.
#pragma once
#import <IOKit/hid/IOHIDManager.h>
#import <GameController/GCSyntheticDeviceKeys.h>
#include "motion_pro.h"
#include "dm_input.h"
#include <stdlib.h>

static void (*dm_motion_xform)(int player, float acc[3], float rot[3]);   // motion_apple.h's (a tentative definition: the same variable when both are included)
typedef struct pro_device { IOHIDDeviceRef hid; uint8_t report[512]; pro_motion motion; int imu_on; struct pro_device *next; } pro_device;
static IOHIDManagerRef g_pro_manager;
static pro_device *g_pro_devices, *g_pro_bound;
static int g_pro_player = -1, g_pro_active = 1, g_pro_controllers, g_pro_slot = -1;
static int g_pro_seen_devices = -1, g_pro_seen_controllers = -1;
static void (*g_pro_changed)(void);

// nxnative refreshed: macOS 27 leaves the Pro Controller's IMU off, and its 0x30 reports carry zeroes for the samples until the Switch's own "enable IMU" subcommand
// (0x40, argument 1) arrives, which the controller acknowledges; then they carry the sensors, measured lying flat at +1.03 G on z. So the device bound to a player
// gets that command once, in a 0x01 report with neutral rumble, as SDL sends it. It changes nothing else of the driver's configuration
static void pro_enable_imu(pro_device *d) {
    if (d->imu_on) return;
    d->imu_on = 1;
    uint8_t r[64] = {0x01, 0x00, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x40, 0x01};   // packet 0, neutral rumble for both sides, subcommand 0x40 = 1
    CFTypeRef transport = IOHIDDeviceGetProperty(d->hid, CFSTR(kIOHIDTransportKey));
    int bluetooth = transport && CFGetTypeID(transport) == CFStringGetTypeID() && CFEqual(transport, CFSTR("Bluetooth"));
    IOReturn e = IOHIDDeviceSetReport(d->hid, kIOHIDReportTypeOutput, r[0], r, bluetooth ? 49 : 64);
    if (e != kIOReturnSuccess) LOG("[RED] [hid] Pro Controller raw motion: cannot switch its IMU on (IOReturn 0x%x): its reports may carry no samples", e);
    else LOG("[hid] Pro Controller raw motion: IMU switched on (subcommand 0x40)");
}
static void pro_route(void) {
    int n = 0; for (pro_device *d = g_pro_devices; d; d = d->next) n++;
    int p = pro_motion_player(n, g_pro_controllers, g_pro_slot);
    pro_device *d = p >= 0 ? g_pro_devices : NULL;
    if (p < 0 && n && g_pro_controllers && (n != g_pro_seen_devices || g_pro_controllers != g_pro_seen_controllers))
        LOG("[hid] Pro Controller raw motion: %d HID devices / %d controllers; cannot pair them uniquely, keeping GameController motion", n, g_pro_controllers);
    g_pro_seen_devices = n; g_pro_seen_controllers = g_pro_controllers;
    if (d == g_pro_bound && p == g_pro_player) return;
    if (g_pro_player >= 0) dm_motion_clear_hid(g_pro_player);
    g_pro_bound = d; g_pro_player = p;
    if (d) { d->motion = (pro_motion){0}; LOG("[hid] Pro Controller raw motion: player %d (HID 0x30)", p + 1); pro_enable_imu(d); }
}
static void dm_motion_pro_players(int controllers, int slot) { g_pro_controllers = controllers; g_pro_slot = slot; pro_route(); }
static void dm_motion_pro_active(int active) {
    g_pro_active = active;
    if (g_pro_bound) g_pro_bound->motion = (pro_motion){0};
    if (!active && g_pro_player >= 0) dm_motion_clear_hid(g_pro_player);
}
static void pro_report(void *ctx, IOReturn result, void *sender, IOHIDReportType type, uint32_t report_id, uint8_t *r, CFIndex len) {
    (void)sender;
    pro_device *d = ctx;
    if (result != kIOReturnSuccess || type != kIOHIDReportTypeInput || report_id != 0x30 || len < 0 || !g_pro_active || d != g_pro_bound) return;
    pro_motion_sample samples[3];
    int n = pro_motion_decode(&d->motion, r, (size_t)len, now_ns(), samples);
    for (int i = 0; i < n; i++) {
        if (dm_motion_xform) dm_motion_xform(g_pro_player, samples[i].acc, samples[i].rot);
        dm_motion_set_hid(g_pro_player, samples[i].acc, samples[i].rot, samples[i].ns);
    }
}
static void pro_found(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef hid) {
    (void)ctx; (void)sender;
    if (result != kIOReturnSuccess || IOHIDDeviceGetProperty(hid, CFSTR(kIOHIDGCSyntheticDeviceKey)) == kCFBooleanTrue) return;
    for (pro_device *d = g_pro_devices; d; d = d->next) if (d->hid == hid) return;
    pro_device *d = calloc(1, sizeof *d); if (!d) { LOG("[RED] Pro Controller raw motion: cannot allocate device state"); return; }
    d->hid = (IOHIDDeviceRef)CFRetain(hid); d->next = g_pro_devices; g_pro_devices = d;
    IOHIDDeviceRegisterInputReportCallback(hid, d->report, sizeof d->report, pro_report, d);
    if (g_pro_changed) g_pro_changed();
}
static void pro_removed(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef hid) {
    (void)ctx; (void)result; (void)sender;
    pro_device **link = &g_pro_devices;
    while (*link && (*link)->hid != hid) link = &(*link)->next;
    if (!*link) return;
    pro_device *d = *link; *link = d->next;
    // Unregister while its buffer / context still exist. The main run loop serializes removal with report callbacks.
    IOHIDDeviceRegisterInputReportCallback(hid, d->report, sizeof d->report, NULL, NULL);
    if (g_pro_changed) g_pro_changed(); else pro_route();
    CFRelease(d->hid); free(d);
}
static void dm_motion_pro_start(void (*changed)(void)) {
    const char *e = getenv("DM_MOTION"); if (e && !atoi(e)) return;
    e = getenv("DM_MOTION_HID"); if (e && !atoi(e)) return;
    g_pro_changed = changed;
    g_pro_manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone); if (!g_pro_manager) return;
    IOHIDManagerSetDeviceMatching(g_pro_manager, (__bridge CFDictionaryRef)@{@kIOHIDVendorIDKey: @0x057E, @kIOHIDProductIDKey: @0x2009});
    IOHIDManagerRegisterDeviceMatchingCallback(g_pro_manager, pro_found, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(g_pro_manager, pro_removed, NULL);
    IOHIDManagerScheduleWithRunLoop(g_pro_manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOReturn r = IOHIDManagerOpen(g_pro_manager, kIOHIDOptionsTypeNone);   // nonexclusive: GameController keeps the device; one output report, pro_enable_imu
    if (r != kIOReturnSuccess) {
        LOG("[RED] Pro Controller raw motion: cannot open HID (0x%x); keeping GameController motion", r);
        IOHIDManagerUnscheduleFromRunLoop(g_pro_manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFRelease(g_pro_manager); g_pro_manager = NULL;
    }
}
