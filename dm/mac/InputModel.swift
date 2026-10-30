// nxnative refreshed: the input mapping the settings window edits, kept in the app's preferences (refreshed.input, JSON) and written for the host as input.json
// (DM_INPUT_CONFIG; dm/host/input_map.h and front_mac.m read it). Its defaults are input_map.h's im_default, nxnative's own controls, so an app started with or without
// the window plays the same until the player changes something.
// Bindings are stored in the window's columns: two keys, a mouse button, two controller elements for each Switch input; the host takes them as one list.
import AppKit
import Foundation
import GameController

enum BindSource: String, Codable { case key, mouse, pad }
struct InputBind: Codable, Hashable {
    var src: BindSource
    var code: String   // a macOS key code (decimal), a mouse code name or a controller element name (input_map.h's tables)
    static func key(_ k: Int) -> InputBind { InputBind(src: .key, code: String(k)) }
    static func pad(_ p: String) -> InputBind { InputBind(src: .pad, code: p) }
    static func mouse(_ m: String) -> InputBind { InputBind(src: .mouse, code: m) }
    var label: String {
        switch src {
        case .key: return KeyNames.name(Int(code) ?? -1)
        case .mouse: return MouseNames.name(code)
        case .pad: return PadNames.short(code)
        }
    }
}

// The window's columns for a binding row
enum BindColumn: Int, CaseIterable, Identifiable {
    case key1, key2, mouse, pad1, pad2
    var id: Int { rawValue }
    var source: BindSource { self == .mouse ? .mouse : self == .key1 || self == .key2 ? .key : .pad }
    var title: String { ["Keyboard", "Keyboard (2nd)", "Mouse", "Controller", "Controller (2nd)"][rawValue] }
}

// The Switch's inputs, in input_map.h's target order, with the window's groups
struct SwitchInput: Identifiable, Hashable {
    let id: String, label: String, group: String
    var isStickDirection: Bool { id.hasPrefix("LS") && id.count > 2 || id.hasPrefix("RS") && id.count > 2 }
}
enum SwitchInputs {
    static let all: [SwitchInput] = [
        .init(id: "A", label: "A", group: "Buttons"), .init(id: "B", label: "B", group: "Buttons"), .init(id: "X", label: "X", group: "Buttons"), .init(id: "Y", label: "Y", group: "Buttons"),
        .init(id: "L", label: "L", group: "Shoulders and triggers"), .init(id: "R", label: "R", group: "Shoulders and triggers"),
        .init(id: "ZL", label: "ZL", group: "Shoulders and triggers"), .init(id: "ZR", label: "ZR", group: "Shoulders and triggers"),
        .init(id: "Plus", label: "+ (Plus)", group: "System and stick presses"), .init(id: "Minus", label: "− (Minus)", group: "System and stick presses"),
        .init(id: "LS", label: "Left stick press", group: "System and stick presses"), .init(id: "RS", label: "Right stick press", group: "System and stick presses"),
        .init(id: "DUp", label: "D-pad up", group: "D-pad"), .init(id: "DDown", label: "D-pad down", group: "D-pad"),
        .init(id: "DLeft", label: "D-pad left", group: "D-pad"), .init(id: "DRight", label: "D-pad right", group: "D-pad"),
        .init(id: "LSUp", label: "Left stick up", group: "Left stick"), .init(id: "LSDown", label: "Left stick down", group: "Left stick"),
        .init(id: "LSLeft", label: "Left stick left", group: "Left stick"), .init(id: "LSRight", label: "Left stick right", group: "Left stick"),
        .init(id: "Walk", label: "Walk (slow left stick)", group: "Left stick"),
        .init(id: "RSUp", label: "Right stick up", group: "Right stick"), .init(id: "RSDown", label: "Right stick down", group: "Right stick"),
        .init(id: "RSLeft", label: "Right stick left", group: "Right stick"), .init(id: "RSRight", label: "Right stick right", group: "Right stick"),
        .init(id: "Shake", label: "Shake", group: "Motion"),
        .init(id: "TiltUp", label: "Tilt forward", group: "Motion"), .init(id: "TiltDown", label: "Tilt back", group: "Motion"),
        .init(id: "TiltLeft", label: "Tilt left", group: "Motion"), .init(id: "TiltRight", label: "Tilt right", group: "Motion"),
        .init(id: "TwistLeft", label: "Turn left", group: "Motion"), .init(id: "TwistRight", label: "Turn right", group: "Motion"),
        .init(id: "Recenter", label: "Recenter motion", group: "Motion"),
    ]
    static var groups: [String] { all.reduce(into: []) { if !$0.contains($1.group) { $0.append($1.group) } } }
    static func label(_ id: String) -> String { all.first { $0.id == id }?.label ?? id }
}

struct StickConfig: Codable, Equatable {
    var deadzone = 0.0, outer = 1.0, curve = 1.0, sens = 1.0, anti = 0.0
    var invX = false, invY = false
}
typealias BindSlots = [InputBind?]   // one per BindColumn

struct PlayerConfig: Codable, Equatable {
    var keyboard = false, mouse = false
    var controller = "auto"   // auto, none, index:<n>, name:<vendor name>
    var binds: [String: BindSlots] = [:]
    var modes: [String: String] = [:]   // hold (absent), toggle, turbo
    var turboHz = 10.0, keyStick = 1.0, walk = 0.5
    var sticks = [StickConfig(), StickConfig()]
    var triggerPress = 0.0, stickPress = 0.5
    var mouseMode = "touch", mouseSensX = 1.0, mouseSensY = 1.0, mouseSmooth = 0.5
    var mouseInvX = false, mouseInvY = false
    var motionSource = "controller", gyroSens = 1.0
    var invPitch = false, invRoll = false, invYaw = false
    var mouseGyroSens = 1.0, tiltAngle = 35.0, tiltSpeed = 240.0, twistSpeed = 180.0, autoCenter = 0.0
    var rumbleOn = true, rumbleGain = 1.0, rumbleLow = 1.0, rumbleHigh = 1.0, rumbleMin = 0.0, rumbleSwap = false

    func slots(_ t: String) -> BindSlots { let s = binds[t] ?? []; return (0..<BindColumn.allCases.count).map { $0 < s.count ? s[$0] : nil } }
    mutating func set(_ t: String, _ col: BindColumn, _ b: InputBind?) { var s = slots(t); s[col.rawValue] = b; setSlots(t, s) }
    mutating func setSlots(_ t: String, _ s: BindSlots) { binds[t] = s.allSatisfy { $0 == nil } ? nil : s }   // an unbound input is left out, so equal mappings compare equal
    func sameBinds(_ o: PlayerConfig) -> Bool { SwitchInputs.all.allSatisfy { slots($0.id) == o.slots($0.id) } && modes.filter { $0.value != "hold" } == o.modes.filter { $0.value != "hold" } }
    func mode(_ t: String) -> String { modes[t] ?? "hold" }

    // input_map.h im_player_default
    static func defaults(_ index: Int) -> PlayerConfig {
        var p = PlayerConfig()
        p.keyboard = index == 0; p.mouse = index == 0
        let keys: [(String, Int)] = [("LSUp", 13), ("LSLeft", 0), ("LSDown", 1), ("LSRight", 2), ("DLeft", 123), ("DUp", 126), ("DRight", 124), ("DDown", 125),
                                     ("A", 38), ("B", 40), ("X", 32), ("Y", 34), ("LS", 3), ("RS", 5), ("L", 12), ("R", 14), ("ZL", 6), ("ZR", 8), ("Plus", 36), ("Minus", 48), ("Shake", 49)]
        if index == 0 { for (t, k) in keys { p.set(t, .key1, .key(k)) } }
        for (t, e) in Self.padDefaults { p.set(t, .pad1, .pad(e)) }
        return p
    }
    static let padDefaults: [(String, String)] = [("A", "east"), ("B", "south"), ("X", "north"), ("Y", "west"), ("L", "lb"), ("R", "rb"), ("ZL", "lt"), ("ZR", "rt"), ("Plus", "menu"), ("Minus", "options"),
                                                  ("LS", "lsb"), ("RS", "rsb"), ("DLeft", "dleft"), ("DUp", "dup"), ("DRight", "dright"), ("DDown", "ddown"),
                                                  ("LSLeft", "ls_left"), ("LSUp", "ls_up"), ("LSRight", "ls_right"), ("LSDown", "ls_down"),
                                                  ("RSLeft", "rs_left"), ("RSUp", "rs_up"), ("RSRight", "rs_right"), ("RSDown", "rs_down")]
}

enum Hotkeys {
    static let all: [(id: String, label: String, note: String)] = [
        ("fullscreen", "Toggle fullscreen", "The style chosen under Display. ⌃⌘F always works too."),
        ("capture", "Capture or release the mouse", "Only while a player's mouse is a stick or a gyro. A click in the game captures it too."),
        ("mute", "Mute or unmute", ""),
        ("volume_up", "Volume up", "In steps of 10 %, up to 200 %."),
        ("volume_down", "Volume down", ""),
        ("recenter", "Recenter every player's motion", "Levels the controllers and takes away gyro drift."),
        ("hud", "Show or hide the performance HUD", "Apple's Metal overlay. If it does not appear, turn on Performance HUD under Display."),
        ("quit", "Quit the game", "Quits at once, as ⌘Q does: the game's last save is kept, anything unsaved is lost."),
    ]
    static let columns = ["Keyboard", "Keyboard (2nd)", "Controller"]
    static func source(_ col: Int) -> BindSource { col == 2 ? .pad : .key }
}

struct InputConfig: Codable, Equatable {
    var version = 1
    var merge = false
    var players: [PlayerConfig] = (0..<8).map { PlayerConfig.defaults($0) }
    var hotkeys: [String: BindSlots] = ["capture": [.key(53), nil, nil]]

    static let defaults = InputConfig()
    func hotkey(_ id: String) -> BindSlots { let s = hotkeys[id] ?? []; return (0..<3).map { $0 < s.count ? s[$0] : nil } }
    mutating func setHotkey(_ id: String, _ col: Int, _ b: InputBind?) { var s = hotkey(id); s[col] = b; hotkeys[id] = s.allSatisfy { $0 == nil } ? nil : s }
    func sameHotkeys(_ o: InputConfig) -> Bool { Hotkeys.all.allSatisfy { hotkey($0.id) == o.hotkey($0.id) } }

    // What the host reads (front_mac.m input_config_load): every binding of a target as one list, the players' settings by input_map.h's names
    func hostJSON() -> [String: Any] {
        func list(_ s: BindSlots) -> [[String: String]] { s.compactMap { $0 }.map { ["src": $0.src.rawValue, "code": $0.code] } }
        var hot: [String: Any] = [:]
        for h in Hotkeys.all { hot[h.id] = list(hotkey(h.id)) }
        return ["version": version, "merge": merge, "hotkeys": hot, "players": players.map { p -> [String: Any] in
            var binds: [String: Any] = [:]
            for t in SwitchInputs.all { let l = list(p.slots(t.id)); if !l.isEmpty { binds[t.id] = l } }
            return ["keyboard": p.keyboard, "mouse": p.mouse, "controller": p.controller, "binds": binds, "modes": p.modes.filter { $0.value != "hold" },
                    "turbo_hz": p.turboHz, "key_stick": p.keyStick, "walk": p.walk,
                    "sticks": p.sticks.map { ["deadzone": $0.deadzone, "outer": $0.outer, "curve": $0.curve, "sens": $0.sens, "anti": $0.anti, "inv_x": $0.invX, "inv_y": $0.invY] as [String: Any] },
                    "trigger_press": p.triggerPress, "stick_press": p.stickPress,
                    "mouse_mode": p.mouseMode, "mouse_sens_x": p.mouseSensX, "mouse_sens_y": p.mouseSensY, "mouse_smooth": p.mouseSmooth, "mouse_inv_x": p.mouseInvX, "mouse_inv_y": p.mouseInvY,
                    "motion_source": p.motionSource, "gyro_sens": p.gyroSens, "inv_pitch": p.invPitch, "inv_roll": p.invRoll, "inv_yaw": p.invYaw,
                    "mouse_gyro_sens": p.mouseGyroSens, "tilt_angle": p.tiltAngle, "tilt_speed": p.tiltSpeed, "twist_speed": p.twistSpeed, "auto_center": p.autoCenter,
                    "rumble": ["on": p.rumbleOn, "gain": p.rumbleGain, "low": p.rumbleLow, "high": p.rumbleHigh, "min": p.rumbleMin, "swap": p.rumbleSwap] as [String: Any]]
        }]
    }

    // Stored JSON onto the defaults, field by field: a setting a later build adds keeps its default, one it drops is ignored
    static func decode(_ data: Data) -> InputConfig? {
        guard let stored = try? JSONSerialization.jsonObject(with: data), let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(InputConfig.defaults)) else { return nil }
        let merged = merge(base, stored)
        guard let d = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(InputConfig.self, from: d)
    }
    private static func merge(_ base: Any, _ over: Any) -> Any {
        if let b = base as? [String: Any], let o = over as? [String: Any] {
            var r = b
            for (k, v) in o {
                if k == "binds" || k == "modes" || k == "hotkeys" { r[k] = v; continue }   // a mapping is whole: an input it leaves out is unbound
                r[k] = b[k].map { merge($0, v) } ?? v
            }
            return r
        }
        if let b = base as? [Any], let o = over as? [Any], b.count == o.count, b.first is [String: Any] { return zip(b, o).map { merge($0, $1) } }
        if let b = base as? [Any], let o = over as? [Any], b.first is [String: Any], o.count < b.count { return o.enumerated().map { merge(b[$0.offset], $0.element) } + b[o.count...] }
        if type(of: base) != type(of: over), !(base is NSNumber && over is NSNumber) { return base }   // a stored value of another type: the default
        return over
    }
}

// Presets for one player's mapping
enum MappingPreset: String, CaseIterable, Identifiable {
    case defaults = "nxnative's default controls"
    case switchFace = "Face buttons by position (Switch layout)"
    case xboxFace = "Face buttons by label (Xbox layout: A at the bottom)"
    case mouseCamera = "Keyboard and mouse: mouse camera, clicks for ZR / ZL"
    case leftKeyboard = "Left half of the keyboard (for a second player on one keyboard)"
    case rightKeyboard = "Right half of the keyboard (for a second player on one keyboard)"
    case clearKeyboard = "Clear the keyboard and mouse"
    case clearController = "Clear the controller"
    var id: String { rawValue }

    func apply(to p: inout PlayerConfig, index: Int) {
        switch self {
        case .defaults:
            let keep = (p.keyboard, p.mouse, p.controller)
            var d = PlayerConfig.defaults(index)
            if index != 0 { let zero = PlayerConfig.defaults(0); for t in SwitchInputs.all { d.set(t.id, .key1, zero.slots(t.id)[0]) } }   // another player gets the keyboard map too
            d.keyboard = keep.0; d.mouse = keep.1; d.controller = keep.2
            p.binds = d.binds; p.modes = [:]
        case .switchFace:
            for (t, e) in [("A", "east"), ("B", "south"), ("X", "north"), ("Y", "west")] { p.set(t, .pad1, .pad(e)) }
        case .xboxFace:
            for (t, e) in [("A", "south"), ("B", "east"), ("X", "west"), ("Y", "north")] { p.set(t, .pad1, .pad(e)) }
        case .mouseCamera:
            p.mouseMode = "right_stick"; p.mouse = true; p.keyboard = true
            p.set("ZR", .mouse, .mouse("left")); p.set("ZL", .mouse, .mouse("right")); p.set("RS", .mouse, .mouse("middle"))
            p.set("L", .mouse, .mouse("wheel_up")); p.set("R", .mouse, .mouse("wheel_down"))
            p.set("Walk", .key1, .key(56))   // left Shift
        case .leftKeyboard:
            p.keyboard = true; clearKeys(&p)
            for (t, k) in Self.leftKeys { p.set(t, .key1, .key(k)) }
        case .rightKeyboard:
            p.keyboard = true; clearKeys(&p)
            for (t, k) in Self.rightKeys { p.set(t, .key1, .key(k)) }
        case .clearKeyboard:
            clearKeys(&p)
            for t in SwitchInputs.all { p.set(t.id, .mouse, nil) }
        case .clearController:
            for t in SwitchInputs.all { p.set(t.id, .pad1, nil); p.set(t.id, .pad2, nil) }
        }
    }
    private func clearKeys(_ p: inout PlayerConfig) { for t in SwitchInputs.all { p.set(t.id, .key1, nil); p.set(t.id, .key2, nil) } }
    // Two players on one keyboard, no key shared and no keypad needed: WASD and the keys around it, and IJKL with the keys around it
    static let leftKeys: [(String, Int)] = [("LSUp", 13), ("LSLeft", 0), ("LSDown", 1), ("LSRight", 2),            // W A S D
                                            ("A", 3), ("B", 5), ("X", 15), ("Y", 17),                               // F G R T
                                            ("L", 12), ("R", 14), ("ZL", 6), ("ZR", 7),                             // Q E Z X
                                            ("Plus", 19), ("Minus", 18), ("LS", 56), ("RS", 9),                     // 2 1, left Shift, V
                                            ("DUp", 21), ("DLeft", 20), ("DRight", 23), ("DDown", 11), ("Shake", 49)]   // 4 3 5 B, Space
    static let rightKeys: [(String, Int)] = [("LSUp", 34), ("LSLeft", 38), ("LSDown", 40), ("LSRight", 37),       // I J K L
                                             ("A", 39), ("B", 44), ("X", 35), ("Y", 41),                            // ' / P ;
                                             ("L", 32), ("R", 31), ("ZL", 16), ("ZR", 33),                          // U O Y [
                                             ("Plus", 36), ("Minus", 30), ("LS", 4), ("RS", 47),                    // Return ], H .
                                             ("DUp", 126), ("DDown", 125), ("DLeft", 123), ("DRight", 124), ("Shake", 60)]   // arrow keys, right Shift
}

// The players' setups the Players page offers in one click
enum PlayerSetup: String, CaseIterable, Identifiable {
    case automatic = "Each controller is a player; the keyboard plays with Player 1"
    case keyboardOwn = "The keyboard is Player 1; controllers from Player 2"
    case merged = "Every controller and the keyboard play Player 1"
    case sharedKeyboard = "Two players on one keyboard, controllers from Player 3"
    var id: String { rawValue }
    func apply(to c: inout InputConfig) {
        c.merge = self == .merged
        for i in 0..<8 { c.players[i].keyboard = i == 0; c.players[i].mouse = i == 0; c.players[i].controller = "auto" }
        switch self {
        case .automatic, .merged: break
        case .keyboardOwn: c.players[0].controller = "none"
        case .sharedKeyboard:
            c.players[0].controller = "none"; c.players[1].controller = "none"; c.players[1].keyboard = true
            MappingPreset.leftKeyboard.apply(to: &c.players[0], index: 0)
            MappingPreset.rightKeyboard.apply(to: &c.players[1], index: 1)
        }
    }
}

// macOS virtual key codes (kVK_*), named as on a US keyboard
enum KeyNames {
    static let table: [(Int, String, String)] = {   // code, name, group
        var t: [(Int, String, String)] = []
        let letters: [(Int, String)] = [(0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"), (38, "J"), (40, "K"), (37, "L"), (46, "M"),
                                        (45, "N"), (31, "O"), (35, "P"), (12, "Q"), (15, "R"), (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z")]
        t += letters.map { ($0.0, $0.1, "Letters") }
        let digits: [(Int, String)] = [(29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9")]
        t += digits.map { ($0.0, $0.1, "Numbers") }
        let symbols: [(Int, String)] = [(50, "` (Grave)"), (27, "- (Minus)"), (24, "= (Equals)"), (33, "["), (30, "]"), (42, "\\"), (41, ";"), (39, "'"), (43, ","), (47, "."), (44, "/"), (10, "§ (ISO)"),
                                        (93, "¥ (JIS)"), (94, "_ (JIS)")]
        t += symbols.map { ($0.0, $0.1, "Symbols") }
        let edit: [(Int, String)] = [(49, "Space"), (36, "Return"), (48, "Tab"), (51, "Delete"), (117, "Forward Delete"), (53, "Escape"), (123, "←"), (124, "→"), (126, "↑"), (125, "↓"),
                                     (115, "Home"), (119, "End"), (116, "Page Up"), (121, "Page Down"), (114, "Help / Insert"), (110, "Menu (PC)")]
        t += edit.map { ($0.0, $0.1, "Navigation and editing") }
        let mods: [(Int, String)] = [(56, "Left ⇧ Shift"), (60, "Right ⇧ Shift"), (59, "Left ⌃ Control"), (62, "Right ⌃ Control"), (58, "Left ⌥ Option"), (61, "Right ⌥ Option"),
                                     (55, "Left ⌘ Command"), (54, "Right ⌘ Command"), (57, "⇪ Caps Lock"), (63, "fn"), (102, "英数 (JIS)"), (104, "かな (JIS)")]
        t += mods.map { ($0.0, $0.1, "Modifiers") }
        let f: [(Int, String)] = [(122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"), (98, "F7"), (100, "F8"), (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12"),
                                  (105, "F13"), (107, "F14"), (113, "F15"), (106, "F16"), (64, "F17"), (79, "F18"), (80, "F19"), (90, "F20")]
        t += f.map { ($0.0, $0.1, "Function keys") }
        let pad: [(Int, String)] = [(82, "Keypad 0"), (83, "Keypad 1"), (84, "Keypad 2"), (85, "Keypad 3"), (86, "Keypad 4"), (87, "Keypad 5"), (88, "Keypad 6"), (89, "Keypad 7"),
                                    (91, "Keypad 8"), (92, "Keypad 9"), (65, "Keypad ."), (67, "Keypad *"), (69, "Keypad +"), (78, "Keypad -"), (75, "Keypad /"), (81, "Keypad ="),
                                    (76, "Keypad Enter"), (71, "Keypad Clear"), (95, "Keypad , (JIS)")]
        t += pad.map { ($0.0, $0.1, "Keypad") }
        t += [(72, "Volume Up", "Other"), (73, "Volume Down", "Other"), (74, "Mute", "Other")]
        return t
    }()
    static let byCode: [Int: String] = Dictionary(table.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
    static func name(_ code: Int) -> String { byCode[code] ?? "Key \(code)" }
    static var groups: [String] { table.reduce(into: []) { if !$0.contains($1.2) { $0.append($1.2) } } }
    static let modifierCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    // Whether a flags-changed event is its key going down (the device-dependent bits, as front_mac.m on_flags reads them)
    static func modifierDown(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags.rawValue
        switch Int(e.keyCode) {
        case 56: return f & 0x02 != 0
        case 60: return f & 0x04 != 0
        case 59: return f & 0x01 != 0
        case 62: return f & 0x2000 != 0
        case 58: return f & 0x20 != 0
        case 61: return f & 0x40 != 0
        case 55: return f & 0x08 != 0
        case 54: return f & 0x10 != 0
        case 57: return e.modifierFlags.contains(.capsLock)
        case 63: return e.modifierFlags.contains(.function)
        default: return false
        }
    }
}
enum MouseNames {
    static let table: [(String, String)] = [("left", "Left button"), ("right", "Right button"), ("middle", "Middle button"), ("button4", "Button 4 (back)"), ("button5", "Button 5 (forward)"),
                                            ("button6", "Button 6"), ("button7", "Button 7"), ("button8", "Button 8"), ("wheel_up", "Wheel up"), ("wheel_down", "Wheel down"),
                                            ("wheel_left", "Wheel left"), ("wheel_right", "Wheel right")]
    static func name(_ c: String) -> String { table.first { $0.0 == c }?.1 ?? c }
}
// A controller's elements by position (input_map.h im_pad_names); on a Nintendo controller east is the button marked A
enum PadNames {
    static let table: [(code: String, short: String, long: String, group: String)] = [
        ("south", "South (A / ✕)", "South face button: Xbox A, PlayStation ✕, Switch B", "Face buttons"),
        ("east", "East (B / ○)", "East face button: Xbox B, PlayStation ○, Switch A", "Face buttons"),
        ("west", "West (X / □)", "West face button: Xbox X, PlayStation □, Switch Y", "Face buttons"),
        ("north", "North (Y / △)", "North face button: Xbox Y, PlayStation △, Switch X", "Face buttons"),
        ("lb", "LB / L1", "Left bumper (LB, L1, L)", "Shoulders and triggers"), ("rb", "RB / R1", "Right bumper (RB, R1, R)", "Shoulders and triggers"),
        ("lt", "LT / L2", "Left trigger (LT, L2, ZL)", "Shoulders and triggers"), ("rt", "RT / R2", "Right trigger (RT, R2, ZR)", "Shoulders and triggers"),
        ("lsb", "L3", "Left stick press (L3)", "Stick presses"), ("rsb", "R3", "Right stick press (R3)", "Stick presses"),
        ("menu", "Menu ≡", "Menu / Options / + button", "System buttons"), ("options", "View ⧉", "View / Create / − button", "System buttons"),
        ("home", "Home", "Home / PS / Xbox button", "System buttons"), ("share", "Share", "Share / Capture button", "System buttons"),
        ("dup", "D-pad ↑", "D-pad up", "D-pad"), ("ddown", "D-pad ↓", "D-pad down", "D-pad"), ("dleft", "D-pad ←", "D-pad left", "D-pad"), ("dright", "D-pad →", "D-pad right", "D-pad"),
        ("ls_up", "L stick ↑", "Left stick up", "Left stick"), ("ls_down", "L stick ↓", "Left stick down", "Left stick"),
        ("ls_left", "L stick ←", "Left stick left", "Left stick"), ("ls_right", "L stick →", "Left stick right", "Left stick"),
        ("rs_up", "R stick ↑", "Right stick up", "Right stick"), ("rs_down", "R stick ↓", "Right stick down", "Right stick"),
        ("rs_left", "R stick ←", "Right stick left", "Right stick"), ("rs_right", "R stick →", "Right stick right", "Right stick"),
        ("paddle1", "Paddle 1", "Paddle 1 (Xbox Elite P1, DualSense Edge left)", "Paddles and extras"), ("paddle2", "Paddle 2", "Paddle 2 (Xbox Elite P2, DualSense Edge right)", "Paddles and extras"),
        ("paddle3", "Paddle 3", "Paddle 3 (Xbox Elite P3)", "Paddles and extras"), ("paddle4", "Paddle 4", "Paddle 4 (Xbox Elite P4)", "Paddles and extras"),
        ("touchpad", "Touchpad", "Touchpad press (DualSense, DualShock 4)", "Paddles and extras"),
    ]
    static func short(_ c: String) -> String { table.first { $0.code == c }?.short ?? c }
    static func long(_ c: String) -> String { table.first { $0.code == c }?.long ?? c }
    static var groups: [String] { table.reduce(into: []) { if !$0.contains($1.group) { $0.append($1.group) } } }

    // Every element of a controller, 0..1, as front_mac.m pad_sample reads it (sticks split in directions, unprocessed)
    static func sample(_ c: GCController) -> [String: Float] {
        guard let g = c.extendedGamepad else { return [:] }
        let labelled = c.productCategory == "Switch Pro Controller" || c.productCategory.contains("Joy-Con")
        let (south, east, west, north) = labelled ? (g.buttonB, g.buttonA, g.buttonY, g.buttonX) : (g.buttonA, g.buttonB, g.buttonX, g.buttonY)
        let all = c.physicalInputProfile.buttons
        var v: [String: Float] = ["south": south.value, "east": east.value, "west": west.value, "north": north.value,
                                  "lb": g.leftShoulder.value, "rb": g.rightShoulder.value, "lt": g.leftTrigger.value, "rt": g.rightTrigger.value,
                                  "menu": g.buttonMenu.value, "dup": g.dpad.up.value, "ddown": g.dpad.down.value, "dleft": g.dpad.left.value, "dright": g.dpad.right.value]
        v["options"] = g.buttonOptions?.value; v["home"] = g.buttonHome?.value; v["lsb"] = g.leftThumbstickButton?.value; v["rsb"] = g.rightThumbstickButton?.value
        v["share"] = all[GCInputButtonShare]?.value
        v["paddle1"] = (all[GCInputXboxPaddleOne] ?? all[GCInputLeftPaddle])?.value; v["paddle2"] = (all[GCInputXboxPaddleTwo] ?? all[GCInputRightPaddle])?.value
        v["paddle3"] = all[GCInputXboxPaddleThree]?.value; v["paddle4"] = all[GCInputXboxPaddleFour]?.value; v["touchpad"] = all[GCInputDualShockTouchpadButton]?.value
        let l = g.leftThumbstick, r = g.rightThumbstick
        v["ls_left"] = max(0, -l.xAxis.value); v["ls_right"] = max(0, l.xAxis.value); v["ls_up"] = max(0, l.yAxis.value); v["ls_down"] = max(0, -l.yAxis.value)
        v["rs_left"] = max(0, -r.xAxis.value); v["rs_right"] = max(0, r.xAxis.value); v["rs_up"] = max(0, r.yAxis.value); v["rs_down"] = max(0, -r.yAxis.value)
        return v
    }
}

// The store: the mapping in the app's preferences, written for the host at Play (and at a start without the window, dm_mac_apply_extras)
final class InputStore: ObservableObject {
    @Published var config: InputConfig { didSet { if config != oldValue { save() } } }
    private let defaults: UserDefaults
    static let key = "refreshed.input"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        config = (defaults.data(forKey: Self.key)).flatMap(InputConfig.decode) ?? .defaults
    }
    func save() {
        if config == .defaults { defaults.removeObject(forKey: Self.key); return }
        if let d = try? JSONEncoder().encode(config) { defaults.set(d, forKey: Self.key) }
    }
    func reset() { config = .defaults }
    var changed: Bool { config != .defaults }

    // input.json beside the save (~/Library/Application Support/nxnative/<title ID>/input.json), handed to the host as DM_INPUT_CONFIG unless an env file or the launch set it
    static func write(_ config: InputConfig, into folder: URL) -> URL? {
        let url = folder.appendingPathComponent("input.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: config.hostJSON(), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            return url
        } catch { fputs("[RED] launcher: cannot write \(url.path): \(error.localizedDescription)\n", stderr); return nil }
    }
}
