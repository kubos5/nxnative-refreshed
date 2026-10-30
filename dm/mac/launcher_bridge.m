// nxnative refreshed: the Test page's side of the host's code (launcher_bridge.h). Everything runs on the main thread except the HD Rumble reports, which go out from one
// serial queue as haptics_apple.m sends them. The Nintendo controllers' HID devices are opened nonexclusive (GameController keeps reading them) and only while the page asks
#import "launcher_bridge.h"
#import <IOKit/hid/IOHIDManager.h>
#import <GameController/GCSyntheticDeviceKeys.h>
#include <mach/mach_time.h>
#include "input_json.h"
#include "input_pad_apple.h"
#include "motion_pro.h"
#include "switch_rumble.h"

static uint64_t now_ns(void) {
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / tb.denom;
}

// ---------- Inputs: im_eval with the window's mapping ----------
static im_config cfg;
static im_runtime rt[DM_PLAYERS];
static int cfg_ready;
int dm_test_config(NSData *json) {
    if (!cfg_ready) { im_config_default(&cfg); cfg_ready = 1; }
    id root = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    im_config c; im_config_default(&c);
    if (![root isKindOfClass:NSDictionary.class] || !im_config_from_json(root, &c)) return 0;
    if (memcmp(&c, &cfg, sizeof c)) { cfg = c; memset(rt, 0, sizeof rt); }   // a changed mapping starts its toggles over
    return 1;
}
void dm_test_eval(int player, const uint8_t *keys, const uint8_t *mouse, NSArray<GCController *> *controllers, dm_test_output *out) {
    memset(out, 0, sizeof *out);
    if (player < 0 || player >= DM_PLAYERS) return;
    if (!cfg_ready) { im_config_default(&cfg); cfg_ready = 1; }
    const im_player *c = &cfg.player[player];
    im_inputs in; memset(&in, 0, sizeof in);
    if (c->keyboard && keys) memcpy(in.key, keys, IM_KEY_CODES);
    if (c->mouse && mouse) memcpy(in.mouse, mouse, IM_MOUSE_CODES);
    for (GCController *g in controllers) im_pad_sample(g, c, &in);
    // a key or button bound to a hotkey does not reach the game (front_mac.m): the same here
    for (int k = 0; k < IM_KEY_CODES; k++) if (in.key[k] && im_hotkey_of(&cfg, IM_SRC_KEY, k) >= 0) in.key[k] = 0;
    for (int m = 0; m < IM_MOUSE_CODES; m++) if (in.mouse[m] && im_hotkey_of(&cfg, IM_SRC_MOUSE, m) >= 0) in.mouse[m] = 0;
    for (int p = 0; p < IM_PAD_CODES; p++) if (im_hotkey_of(&cfg, IM_SRC_PAD, p) >= 0) { in.pad[p] = 0; in.pad_pressed[p] = 0; }
    im_output o;
    im_eval(c, &in, &rt[player], (double)now_ns() / 1e9, &o);
    out->buttons = o.buttons; out->lx = o.lx; out->ly = o.ly; out->rx = o.rx; out->ry = o.ry;
    out->shake = o.pressed[IM_SHAKE]; out->walk = o.pressed[IM_WALK]; out->recenter = o.pressed[IM_RECENTER];
    out->tilt_up = o.pressed[IM_TILT_UP]; out->tilt_down = o.pressed[IM_TILT_DOWN]; out->tilt_left = o.pressed[IM_TILT_LEFT]; out->tilt_right = o.pressed[IM_TILT_RIGHT];
    out->twist_left = o.pressed[IM_TWIST_LEFT]; out->twist_right = o.pressed[IM_TWIST_RIGHT];
}

// ---------- Nintendo controllers: HID devices, a Pro Controller's sensors, HD Rumble ----------
typedef struct { IOHIDDeviceRef dev; int pid, bluetooth; uint8_t report[64]; pro_motion motion; pro_motion_sample last; uint64_t last_ns; uint8_t packet; sr_pace pace; int ticking; } sw_device;
#define SW_MAX 8
static sw_device devices[SW_MAX];
static int ndevices;
static IOHIDManagerRef manager;
static dispatch_queue_t rumble_queue;   // the reports and the pacing; the device list changes on the main thread, and the rumble state is read under it with dispatch_sync

static void input(void *ctx, IOReturn result, void *sender, IOHIDReportType type, uint32_t id, uint8_t *r, CFIndex len) {
    (void)sender;
    sw_device *d = ctx;
    if (result != kIOReturnSuccess || type != kIOHIDReportTypeInput || id != 0x30 || d->pid != 0x2009) return;
    pro_motion_sample s[3];
    int n = pro_motion_decode(&d->motion, r, (size_t)len, now_ns(), s);
    if (n) { d->last = s[n - 1]; d->last_ns = now_ns(); }
}
static void found(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)sender;
    if (result != kIOReturnSuccess || IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDGCSyntheticDeviceKey)) == kCFBooleanTrue) return;
    for (int i = 0; i < ndevices; i++) if (devices[i].dev == dev) return;
    if (ndevices == SW_MAX) return;
    dispatch_sync(rumble_queue, ^{
        sw_device *d = &devices[ndevices];
        memset(d, 0, sizeof *d);
        d->dev = (IOHIDDeviceRef)CFRetain(dev);
        d->pid = [(__bridge NSNumber *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductIDKey)) intValue];
        d->bluetooth = [(__bridge NSString *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDTransportKey)) isEqualToString:@"Bluetooth"];
        IOHIDDeviceRegisterInputReportCallback(dev, d->report, sizeof d->report, input, d);
        ndevices++;
    });
    // a Pro Controller's IMU is off on macOS 27 until the Switch's "enable IMU" subcommand arrives (motion_pro_mac.h pro_enable_imu, which the game sends too)
    if ([(__bridge NSNumber *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductIDKey)) intValue] == 0x2009) {
        uint8_t r[64] = {0x01, 0x00, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x40, 0x01};
        BOOL bt = [(__bridge NSString *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDTransportKey)) isEqualToString:@"Bluetooth"];
        IOReturn e = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, r[0], r, bt ? 49 : 64);
        if (e != kIOReturnSuccess) fprintf(stderr, "[RED] launcher: cannot switch the Pro Controller's IMU on (IOReturn 0x%x)\n", e);
    }
}
static void removed(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)result; (void)sender;
    dispatch_sync(rumble_queue, ^{
        for (int i = 0; i < ndevices; i++) if (devices[i].dev == dev) {
            IOHIDDeviceRegisterInputReportCallback(dev, devices[i].report, sizeof devices[i].report, NULL, NULL);
            CFRelease(devices[i].dev);
            // the later devices move down: their input callbacks are registered with their own slot, so they are registered again at theirs
            for (int j = i + 1; j < ndevices; j++) IOHIDDeviceRegisterInputReportCallback(devices[j].dev, devices[j].report, sizeof devices[j].report, NULL, NULL);
            memmove(&devices[i], &devices[i + 1], sizeof devices[0] * (size_t)(ndevices - i - 1));
            ndevices--;
            for (int j = i; j < ndevices; j++) { devices[j].ticking = 0; IOHIDDeviceRegisterInputReportCallback(devices[j].dev, devices[j].report, sizeof devices[j].report, input, &devices[j]); }
            return;
        }
    });
}
static void start(void) {
    if (manager) return;
    rumble_queue = dispatch_queue_create("dm.test.rumble", DISPATCH_QUEUE_SERIAL);
    manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSArray *match = @[@{@kIOHIDVendorIDKey: @0x057E, @kIOHIDProductIDKey: @0x2009}, @{@kIOHIDVendorIDKey: @0x057E, @kIOHIDProductIDKey: @0x2006},
                       @{@kIOHIDVendorIDKey: @0x057E, @kIOHIDProductIDKey: @0x2007}];
    IOHIDManagerSetDeviceMatchingMultiple(manager, (__bridge CFArrayRef)match);
    IOHIDManagerRegisterDeviceMatchingCallback(manager, found, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(manager, removed, NULL);
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOReturn e = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    if (e != kIOReturnSuccess) fprintf(stderr, "[RED] launcher: cannot open the Nintendo controllers' HID devices (IOReturn 0x%x)\n", e);
}
int dm_test_switch_count(void) { start(); return ndevices; }
int dm_test_switch_info(int index, char *name, int cap) {
    start();
    if (index < 0 || index >= ndevices) { if (cap) name[0] = 0; return 0; }
    sw_device *d = &devices[index];
    NSString *product = (__bridge NSString *)IOHIDDeviceGetProperty(d->dev, CFSTR(kIOHIDProductKey)) ?: @"Nintendo controller";
    snprintf(name, (size_t)cap, "%s · %s", product.UTF8String, d->bluetooth ? "Bluetooth" : "USB");
    return d->pid;
}
int dm_test_switch_motion(int index, float acc[3], float rot[3]) {
    start();
    if (index < 0 || index >= ndevices || !devices[index].last_ns || now_ns() - devices[index].last_ns > 300000000ull) return 0;
    memcpy(acc, devices[index].last.acc, sizeof(float) * 3); memcpy(rot, devices[index].last.rot, sizeof(float) * 3);
    return 1;
}
// As haptics_apple.m sw_tick: the report due now, another look in 10 ms while one is still to come
static void tick(int index) {
    if (index >= ndevices) return;
    sw_device *d = &devices[index];
    uint8_t r[8], report[64];
    if (sr_pace_next(&d->pace, now_ns(), r)) {
        size_t n = sr_report(&d->packet, r, d->bluetooth, report);
        IOReturn e = IOHIDDeviceSetReport(d->dev, kIOHIDReportTypeOutput, report[0], report, (CFIndex)n);
        if (e != kIOReturnSuccess) fprintf(stderr, "[RED] launcher: HD Rumble report: IOReturn 0x%x\n", e);
    }
    if (!d->ticking && sr_pace_busy(&d->pace)) {
        d->ticking = 1; IOHIDDeviceRef dev = d->dev;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), rumble_queue, ^{
            if (index >= ndevices || devices[index].dev != dev) return;
            devices[index].ticking = 0; tick(index);
        });
    }
}
void dm_test_switch_rumble(int index, const float left[4], const float right[4]) {
    start();
    struct { dm_vibration v[2]; } pair = {{{left[0], left[1], left[2], left[3]}, {right[0], right[1], right[2], right[3]}}};   // a block takes a struct by value, not an array
    dispatch_async(rumble_queue, ^{
        if (index < 0 || index >= ndevices) return;
        sr_pace_set(&devices[index].pace, pair.v); tick(index);
    });
}
void dm_test_switch_stop(void) {
    if (!manager) return;
    dispatch_async(rumble_queue, ^{
        const dm_vibration idle[2] = {{0, 160, 0, 320}, {0, 160, 0, 320}};
        for (int i = 0; i < ndevices; i++) { sr_pace_set(&devices[i].pace, idle); tick(i); }
    });
}
