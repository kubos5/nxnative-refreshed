// nxnative refreshed: the Test page: what a player's controls give the game, each controller's motion sensors, and rumble, all through the host's own code (launcher_bridge.h):
// the buttons and sticks come from input_map.h with this window's mapping, a Pro Controller's sensors from its own reports (GameController gives zeroes for them on macOS),
// and a Nintendo controller's rumble is HD Rumble as the game sends it (switch_rumble.h). Keys typed while the page is open go to the test, not to the window.
import AppKit
import GameController
import SwiftUI

// The page's live state, polled 60 times a second while the page is open. The window starts and stops it (LauncherView), not the page's sections: a form makes its
// sections only as they scroll into view, and drops them as they leave it
final class TestState: ObservableObject {
    static let shared = TestState()
    @Published var out = dm_test_output()
    @Published var sensors: [Sensor] = []
    @Published var rumbleDevices: [RumbleDevice] = []
    struct Sensor: Identifiable, Equatable { let id: String; let name: String; let acc: SIMD3<Float>; let rot: SIMD3<Float>; let live: Bool }
    struct RumbleDevice: Identifiable, Hashable { let id: String; let name: String; let hd: Int?; let controller: ObjectIdentifier? }   // hd: the Nintendo device's index
    var keys = [UInt8](repeating: 0, count: 128)
    var mouse = [UInt8](repeating: 0, count: 12)
    private var wheelUntil = [Double](repeating: 0, count: 4)
    private var timer: Timer?, monitor: Any?, resign: NSObjectProtocol?
    private var activated: [GCMotion] = []
    private var config: InputConfig?

    func start(input: InputStore, player: @escaping () -> Int) {
        guard timer == nil else { return }
        release()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in self?.key(e) ?? e }
        resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in self?.release() }
        // motion on, as the game turns it on (motion_apple.h): GameController switches a controller's sensors on for a listener, a Pro Controller's too (its reports carry them)
        for c in GCController.controllers() {
            guard let m = c.motion else { continue }
            if m.sensorsRequireManualActivation && !m.sensorsActive { m.sensorsActive = true }
            if m.valueChangedHandler == nil { m.valueChangedHandler = { _ in }; activated.append(m) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.poll(input: input, player: player()) }
        RunLoop.main.add(timer!, forMode: .common)   // also while a slider is dragged
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil
        if let r = resign { NotificationCenter.default.removeObserver(r) }; resign = nil
        for m in activated { m.valueChangedHandler = nil; if m.sensorsRequireManualActivation { m.sensorsActive = false } }; activated = []
        release()
        RumblePlayer.shared.stop()
        dm_test_switch_stop()
    }
    func release() { keys = [UInt8](repeating: 0, count: 128); mouse = [UInt8](repeating: 0, count: 12) }

    // Keys reach the test only in the settings window, and never with ⌘ (⌘Q, ⌘W still work); a modifier key on its own counts, as in the game (front_mac.m)
    private func key(_ e: NSEvent) -> NSEvent? {
        guard e.window?.identifier?.rawValue == "launcher", !e.modifierFlags.contains(.command) || e.type == .flagsChanged else { return e }
        if let t = e.window?.firstResponder as? NSTextView, t.isFieldEditor { return e }
        let code = Int(e.keyCode)
        guard code < 128 else { return nil }
        switch e.type {
        case .keyDown: keys[code] = 1
        case .keyUp: keys[code] = 0
        default: if (54...63).contains(code) { keys[code] = KeyNames.modifierDown(e) ? 1 : 0 }; if e.modifierFlags.contains(.command) { return e }
        }
        return nil
    }
    func mouseButton(_ code: Int, _ down: Bool) { if code >= 0 && code < 8 { mouse[code] = down ? 1 : 0 } }
    func wheel(_ dir: Int) { mouse[8 + dir] = 1; wheelUntil[dir] = ProcessInfo.processInfo.systemUptime + 0.12 }   // a notch holds its code for a moment, as in the game

    private func poll(input: InputStore, player: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        for d in 0..<4 where mouse[8 + d] != 0 && now >= wheelUntil[d] { mouse[8 + d] = 0 }
        if input.config != config, let data = try? JSONSerialization.data(withJSONObject: input.config.hostJSON()) { _ = dm_test_config(data); config = input.config }
        var o = dm_test_output()
        let pads = ControllerMonitor.shared.controllers(of: player, input.config)
        keys.withUnsafeBufferPointer { k in mouse.withUnsafeBufferPointer { m in dm_test_eval(Int32(player), k.baseAddress, m.baseAddress, pads, &o) } }
        if !TestState.same(o, out) { out = o }
        let s = readSensors()
        if s != sensors { sensors = s }
        let devices = readRumbleDevices()
        if devices != rumbleDevices { rumbleDevices = devices }
    }
    private static func same(_ a: dm_test_output, _ b: dm_test_output) -> Bool {
        withUnsafeBytes(of: a) { x in withUnsafeBytes(of: b) { y in x.elementsEqual(y) } }
    }
    private func readSensors() -> [Sensor] {
        var list: [Sensor] = []
        let hd = (0..<Int(dm_test_switch_count())).map { i -> (Int, String, Int32) in var name = [CChar](repeating: 0, count: 128); let pid = dm_test_switch_info(Int32(i), &name, 128); return (i, String(cString: name), pid) }
        for (i, name, pid) in hd where pid == 0x2009 {
            var acc = [Float](repeating: 0, count: 3), rot = [Float](repeating: 0, count: 3)
            let live = dm_test_switch_motion(Int32(i), &acc, &rot) != 0
            list.append(Sensor(id: "hid\(i)", name: name, acc: SIMD3(acc[0], acc[1], acc[2]), rot: SIMD3(rot[0], rot[1], rot[2]), live: live))
        }
        for c in GCController.controllers() where c.extendedGamepad != nil && c.productCategory != "Switch Pro Controller" {
            guard let m = c.motion, m.hasRotationRate else { continue }
            let a = m.hasGravityAndUserAcceleration ? SIMD3(Float(m.gravity.x + m.userAcceleration.x), Float(m.gravity.y + m.userAcceleration.y), Float(m.gravity.z + m.userAcceleration.z))
                                                    : SIMD3(Float(m.acceleration.x), Float(m.acceleration.y), Float(m.acceleration.z))
            let r = SIMD3(Float(m.rotationRate.x), Float(m.rotationRate.y), Float(m.rotationRate.z))
            list.append(Sensor(id: "gc\(ObjectIdentifier(c).hashValue)", name: c.vendorName ?? "Controller", acc: a, rot: r, live: a != .zero || r != .zero))
        }
        return list
    }
    private func readRumbleDevices() -> [RumbleDevice] {
        var list: [RumbleDevice] = []
        for i in 0..<Int(dm_test_switch_count()) {
            var name = [CChar](repeating: 0, count: 128); _ = dm_test_switch_info(Int32(i), &name, 128)
            list.append(RumbleDevice(id: "hid\(i)", name: String(cString: name), hd: i, controller: nil))
        }
        for c in GCController.controllers() where c.extendedGamepad != nil && !dm_pad_is_nintendo(c) && !(c.haptics?.supportedLocalities.isEmpty ?? true) {
            list.append(RumbleDevice(id: "gc\(ObjectIdentifier(c).hashValue)", name: c.vendorName ?? "Controller", hd: nil, controller: ObjectIdentifier(c)))
        }
        return list
    }
}
// A Nintendo controller plays HD Rumble through its own reports; GameController drives the others
func dm_pad_is_nintendo(_ c: GCController) -> Bool { c.productCategory == "Switch Pro Controller" || c.productCategory.contains("Joy-Con") }

// HD Rumble patterns: each motor's (amplitude low, frequency low, amplitude high, frequency high) at a time since the start, for `length` seconds
struct RumblePattern: Identifiable {
    let id: String, title: String, note: String
    let length: Double
    let at: (Double) -> ([Float], [Float])
    static let idle: [Float] = [0, 160, 0, 320]
    static let all: [RumblePattern] = [
        RumblePattern(id: "low", title: "Low band", note: "160 Hz, the deep part of HD Rumble", length: 1) { _ in ([0.6, 160, 0, 320], [0.6, 160, 0, 320]) },
        RumblePattern(id: "high", title: "High band", note: "320 Hz, the sharp part", length: 1) { _ in ([0, 160, 0.6, 320], [0, 160, 0.6, 320]) },
        RumblePattern(id: "left", title: "Left motor", note: "Both bands on the left actuator only", length: 0.8) { _ in ([0.5, 160, 0.5, 320], idle) },
        RumblePattern(id: "right", title: "Right motor", note: "Both bands on the right actuator only", length: 0.8) { _ in (idle, [0.5, 160, 0.5, 320]) },
        RumblePattern(id: "sweep", title: "Frequency sweep", note: "Low band 41 to 626 Hz, then high band 82 to 1252 Hz", length: 4) { t in
            let lo = t < 2 ? Float(41 * pow(626.0 / 41, t / 2)) : 160, hi = t >= 2 ? Float(82 * pow(1252.0 / 82, (t - 2) / 2)) : 320
            let v: [Float] = t < 2 ? [0.5, lo, 0, 320] : [0, 160, 0.5, hi]
            return (v, v)
        },
        RumblePattern(id: "impacts", title: "Impacts", note: "Four short, strong hits", length: 1.1) { t in
            let hit = t.truncatingRemainder(dividingBy: 0.25) < 0.05
            let v: [Float] = hit ? [1, 110, 0.8, 260] : idle
            return (v, v)
        },
        RumblePattern(id: "engine", title: "Engine", note: "A low throb with a rough edge, rising", length: 2.5) { t in
            let wobble = Float(0.5 + 0.5 * sin(t * 2 * .pi * 9))
            let v: [Float] = [Float(0.2 + 0.25 * t / 2.5) * (0.7 + 0.3 * wobble), Float(55 + 30 * t / 2.5), 0.12 * wobble, 240]
            return (v, v)
        },
        RumblePattern(id: "heartbeat", title: "Heartbeat", note: "Two soft beats, twice", length: 1.8) { t in
            let p = t.truncatingRemainder(dividingBy: 0.9), beat = p < 0.08 || (p > 0.2 && p < 0.27)
            let v: [Float] = beat ? [0.55, 80, 0.1, 200] : idle
            return (v, v)
        },
    ]
}

// Plays a pattern or the manual values on one Nintendo controller, at 100 steps a second (the reports themselves go out at most every 30 ms, as in the game)
final class RumblePlayer: ObservableObject {
    static let shared = RumblePlayer()
    @Published var playing: String?   // the pattern's id, "manual", or nil
    private var timer: Timer?
    private var started = 0.0
    var shape: (([Float], [Float])) -> ([Float], [Float]) = { $0 }   // the player's rumble settings
    func play(_ p: RumblePattern, on device: Int) {
        stop(); playing = p.id; started = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = ProcessInfo.processInfo.systemUptime - self.started
            if t >= p.length { self.stop(); return }
            let (l, r) = self.shape(p.at(t))
            dm_test_switch_rumble(Int32(device), l, r)
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func hold(_ l: [Float], _ r: [Float], on device: Int) {
        if playing != "manual" { stop(); playing = "manual" }
        let (sl, sr) = shape((l, r))
        dm_test_switch_rumble(Int32(device), sl, sr)
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if playing != nil { dm_test_switch_stop() }
        playing = nil
    }
    // A player's rumble settings as the game's rumble gets them (haptics_apple.m sw_apply): off, swapped, each band's share and the strength, the cutoff
    static func shaping(_ p: PlayerConfig, gain globalGain: Double, min globalMin: Double) -> (([Float], [Float])) -> ([Float], [Float]) {
        let gain = Float(globalGain * p.rumbleGain), cut = Float(max(globalMin, p.rumbleMin)), low = Float(p.rumbleLow), high = Float(p.rumbleHigh), on = p.rumbleOn, swap = p.rumbleSwap
        return { lr in
            func level(_ x: Float) -> Float { let v = Swift.min(1, Swift.max(0, x)); return v <= cut ? 0 : (v - cut) / (1 - cut) }
            func one(_ v: [Float]) -> [Float] { [on ? level(Swift.min(1, v[0] * low) * gain) : 0, v[1], on ? level(Swift.min(1, v[2] * high) * gain) : 0, v[3]] }
            return swap ? (one(lr.1), one(lr.0)) : (one(lr.0), one(lr.1))
        }
    }
    // The Nintendo HID device a GameController controller is most likely made of: the first one of its kind (the Test page lists every device on its own)
    static func device(for c: GCController) -> Int? {
        let want: Int32 = c.productCategory == "Switch Pro Controller" ? 0x2009 : c.productCategory.contains("(R)") ? 0x2007 : 0x2006
        var name = [CChar](repeating: 0, count: 128)
        return (0..<Int(dm_test_switch_count())).first { dm_test_switch_info(Int32($0), &name, 128) == want }
    }
}

struct TestPage: View {
    @ObservedObject var input: InputStore
    @Binding var player: Int
    let rumbleOn: Bool, globalGain: Double, globalMin: Double
    @ObservedObject private var state = TestState.shared
    @ObservedObject private var rumble = RumblePlayer.shared
    @ObservedObject private var monitor = ControllerMonitor.shared
    @State private var device: String?
    @State private var lowFreq = 160.0
    @State private var lowAmp = 0.5
    @State private var highFreq = 320.0
    @State private var highAmp = 0.5
    @State private var motor = 0   // 0 both, 1 left, 2 right
    @State private var settings = true   // with the player's rumble settings

    var body: some View {
        Section {
            PlayerPicker(player: $player)
        } footer: {
            Text("While this page is open, keys go to the test (⌘ shortcuts still work). The buttons and sticks below are what Player \(player + 1)'s controls give the game, through the same code the game runs.")
        }
        inputsSection
        motionSection
        rumbleSection
    }

    // ---------- Inputs ----------
    private var inputsSection: some View {
        let p = input.config.players[player], pads = monitor.controllers(of: player, input.config)
        return Section {
            SwitchDiagram(out: state.out).frame(height: 230).frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                ForEach(motionChips, id: \.0) { chip in
                    Text(chip.0).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(chip.1 ? Color.accentColor : Color.secondary.opacity(0.15)))
                        .foregroundStyle(chip.1 ? Color.white : Color.secondary)
                }
            }
            if p.mouse {
                MouseTestArea(state: state).frame(height: 54)
            }
            LabeledContent("Player \(player + 1) reads") {
                Text([p.keyboard ? "the keyboard" : nil, p.mouse ? "the mouse" : nil, pads.isEmpty ? nil : pads.map { $0.vendorName ?? "a controller" }.joined(separator: ", ")]
                        .compactMap { $0 }.joined(separator: ", ").nonEmpty ?? "nothing: turn on a device on the Players page")
                    .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        } header: { Text("Buttons and sticks") } footer: {
            Text("Press keys, mouse buttons (in the box) or the player's controllers. Toggle and Turbo modes behave as in the game; a key or button taken by a hotkey stays dark.")
        }
    }
    private var motionChips: [(String, Bool)] {
        let o = state.out
        return [("Shake", o.shake != 0), ("Tilt ↑", o.tilt_up != 0), ("Tilt ↓", o.tilt_down != 0), ("Tilt ←", o.tilt_left != 0), ("Tilt →", o.tilt_right != 0),
                ("Turn left", o.twist_left != 0), ("Turn right", o.twist_right != 0), ("Walk", o.walk != 0), ("Recenter", o.recenter != 0)]
    }

    // ---------- Motion ----------
    private var motionSection: some View {
        Section {
            if state.sensors.isEmpty {
                Text("No controller with motion sensors is connected. A Pro Controller, Joy-Con, DualSense or DualShock 4 shows its gyroscope and accelerometer here.").foregroundStyle(.secondary)
            }
            ForEach(state.sensors) { s in SensorRow(sensor: s) }
        } header: { Text("Motion sensors") } footer: {
            Text("Turn and tilt the controller: the bars follow its gyroscope (degrees per second) and accelerometer (G), as the game reads them before Player \(player + 1)'s motion settings (Motion page). Lying flat, face up, it reads about −1 G on Z.")
        }
    }

    // ---------- Rumble ----------
    private var rumbleSection: some View {
        let devices = state.rumbleDevices
        let chosen = devices.first { $0.id == device } ?? devices.first
        return Section {
            if devices.isEmpty {
                Text("No controller that can rumble is connected.").foregroundStyle(.secondary)
            } else {
                Picker("Controller", selection: Binding(get: { chosen?.id ?? "" }, set: { rumble.stop(); device = $0 })) {
                    ForEach(devices) { d in Text(d.name).tag(d.id) }
                }
                if let d = chosen, let hd = d.hd {
                    Toggle("With Player \(player + 1)'s rumble settings", isOn: $settings)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(RumblePattern.all) { pattern in
                            Button { prepare(); if rumble.playing == pattern.id { rumble.stop() } else { rumble.play(pattern, on: hd) } } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack { Image(systemName: rumble.playing == pattern.id ? "stop.fill" : "play.fill").font(.caption); Text(pattern.title).fontWeight(.medium) }
                                    Text(pattern.note).font(.caption2).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                                }.frame(maxWidth: .infinity, alignment: .topLeading)   // every button as tall as a two-line note
                            }
                            .help(pattern.note)
                        }
                    }
                    manual(hd)
                } else if let d = chosen, let id = d.controller {
                    HStack {
                        Text("This controller rumbles through macOS (Core Haptics), which approximates the game's two bands with one strength.").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Rumble") {
                            if let info = monitor.controllers.first(where: { $0.id == id }) { monitor.test(info, player: input.config.players[player], globalGain: globalGain) }
                        }
                    }
                }
            }
        } header: { Text("Rumble") } footer: {
            Text(rumbleOn ? "A Nintendo controller plays HD Rumble as on a Switch: each motor's two bands at the game's frequencies and amplitudes. Compare a pattern with the same controller on a Switch."
                          : "Rumble is off for every player (Rumble page): the game will not rumble. The test still plays.")
        }
    }
    private func manual(_ hd: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your own values").fontWeight(.medium)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Low band").foregroundStyle(.secondary)
                    Slider(value: $lowFreq, in: 41...626); Text("\(Int(lowFreq)) Hz").monospacedDigit().frame(width: 64, alignment: .trailing)
                    Slider(value: $lowAmp, in: 0...1); Text("\(Int(lowAmp * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                GridRow {
                    Text("High band").foregroundStyle(.secondary)
                    Slider(value: $highFreq, in: 82...1252); Text("\(Int(highFreq)) Hz").monospacedDigit().frame(width: 64, alignment: .trailing)
                    Slider(value: $highAmp, in: 0...1); Text("\(Int(highAmp * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            HStack {
                Picker("Motor", selection: $motor) { Text("Both").tag(0); Text("Left").tag(1); Text("Right").tag(2) }.pickerStyle(.segmented).frame(maxWidth: 240)
                Spacer()
                Button(rumble.playing == "manual" ? "Stop" : "Play") { prepare(); if rumble.playing == "manual" { rumble.stop() } else { playManual(hd) } }
            }
        }
        .onChange(of: lowFreq) { _, _ in if rumble.playing == "manual" { playManual(hd) } }
        .onChange(of: lowAmp) { _, _ in if rumble.playing == "manual" { playManual(hd) } }
        .onChange(of: highFreq) { _, _ in if rumble.playing == "manual" { playManual(hd) } }
        .onChange(of: highAmp) { _, _ in if rumble.playing == "manual" { playManual(hd) } }
        .onChange(of: motor) { _, _ in if rumble.playing == "manual" { playManual(hd) } }
    }
    private func playManual(_ hd: Int) {
        let v: [Float] = [Float(lowAmp), Float(lowFreq), Float(highAmp), Float(highFreq)]
        rumble.hold(motor == 2 ? RumblePattern.idle : v, motor == 1 ? RumblePattern.idle : v, on: hd)
    }
    private func prepare() {   // with the player's settings, or the values as they are
        rumble.shape = settings ? RumblePlayer.shaping(input.config.players[player], gain: globalGain, min: globalMin) : { $0 }
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

// A Switch controller drawn with what is pressed and where the sticks are
struct SwitchDiagram: View {
    let out: dm_test_output
    private func on(_ bit: Int) -> Bool { out.buttons >> UInt64(bit) & 1 != 0 }
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / 520, size.height / 230), ox = (size.width - 520 * s) / 2
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * s, y: y * s) }
            let accent = Color.accentColor, idle = Color.secondary.opacity(0.18), edge = Color.secondary.opacity(0.5)
            func button(_ rect: CGRect, _ label: String, _ lit: Bool, round: Bool = true) {
                let path = round ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 6 * s)
                ctx.fill(path, with: .color(lit ? accent : idle)); ctx.stroke(path, with: .color(lit ? accent : edge), lineWidth: 1)
                ctx.draw(Text(label).font(.system(size: 12 * s, weight: .semibold)).foregroundColor(lit ? .white : .primary), at: CGPoint(x: rect.midX, y: rect.midY))
            }
            func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(origin: p(x, y), size: CGSize(width: w * s, height: h * s)) }
            // body
            ctx.stroke(Path(roundedRect: rect(40, 50, 440, 170), cornerRadius: 60 * s), with: .color(edge.opacity(0.6)), lineWidth: 1.5)
            // shoulders and triggers
            button(rect(52, 4, 96, 20), "ZL", on(8), round: false); button(rect(62, 28, 86, 18), "L", on(6), round: false)
            button(rect(372, 4, 96, 20), "ZR", on(9), round: false); button(rect(372, 28, 86, 18), "R", on(7), round: false)
            // − and +
            button(rect(196, 72, 26, 26), "−", on(11)); button(rect(298, 72, 26, 26), "+", on(10))
            // sticks
            func stick(_ cx: Double, _ cy: Double, _ x: Int32, _ y: Int32, _ pressed: Bool, _ label: String) {
                let well = Path(ellipseIn: rect(cx - 36, cy - 36, 72, 72))
                ctx.fill(well, with: .color(pressed ? accent.opacity(0.35) : idle)); ctx.stroke(well, with: .color(pressed ? accent : edge), lineWidth: 1)
                let dx = Double(x) / 32767 * 26, dy = -Double(y) / 32767 * 26
                let moved = x != 0 || y != 0
                let knob = Path(ellipseIn: rect(cx + dx - 12, cy + dy - 12, 24, 24))
                ctx.fill(knob, with: .color(moved || pressed ? accent : Color.secondary.opacity(0.6)))
                ctx.draw(Text(label).font(.system(size: 10 * s)).foregroundColor(.secondary), at: p(cx, cy + 48))
            }
            stick(130, 110, out.lx, out.ly, on(4), String(format: "%.2f, %.2f", Double(out.lx) / 32767, Double(out.ly) / 32767))
            stick(330, 175, out.rx, out.ry, on(5), String(format: "%.2f, %.2f", Double(out.rx) / 32767, Double(out.ry) / 32767))
            // D-pad
            let dc = (x: 190.0, y: 175.0)
            button(rect(dc.x - 11, dc.y - 37, 22, 24), "▲", on(13), round: false); button(rect(dc.x - 11, dc.y + 13, 22, 24), "▼", on(15), round: false)
            button(rect(dc.x - 37, dc.y - 11, 24, 22), "◀", on(12), round: false); button(rect(dc.x + 13, dc.y - 11, 24, 22), "▶", on(14), round: false)
            // A B X Y, as on a Switch: A right, B bottom, X top, Y left
            let fc = (x: 405.0, y: 110.0)
            button(rect(fc.x + 18, fc.y - 15, 30, 30), "A", on(0)); button(rect(fc.x - 15, fc.y + 18, 30, 30), "B", on(1))
            button(rect(fc.x - 15, fc.y - 48, 30, 30), "X", on(2)); button(rect(fc.x - 48, fc.y - 15, 30, 30), "Y", on(3))
        }
        .accessibilityElement()
        .accessibilityLabel("Switch controller")
        .accessibilityValue(pressedNames.isEmpty ? "nothing pressed" : pressedNames.joined(separator: ", "))
    }
    var pressedNames: [String] {
        ["A", "B", "X", "Y", "Left stick press", "Right stick press", "L", "R", "ZL", "ZR", "Plus", "Minus", "Left", "Up", "Right", "Down"].enumerated().compactMap { on($0.offset) ? $0.element : nil }
    }
}

struct SensorRow: View {
    let sensor: TestState.Sensor
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Image(systemName: "gyroscope").foregroundStyle(.tint); Text(sensor.name).fontWeight(.medium); if !sensor.live { Text("no data yet: move it").font(.caption).foregroundStyle(.secondary) } }
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        GridRow {
                            Text(["Gyro X", "Gyro Y", "Gyro Z"][i]).font(.caption).foregroundStyle(.secondary)
                            Bar(value: Double(sensor.rot[i]) * 180 / .pi, range: 720)
                            Text(String(format: "%+5.0f °/s", Double(sensor.rot[i]) * 180 / .pi)).font(.caption.monospacedDigit()).frame(width: 74, alignment: .trailing)
                            Text(["Accel X", "Accel Y", "Accel Z"][i]).font(.caption).foregroundStyle(.secondary)
                            Bar(value: Double(sensor.acc[i]), range: 2)
                            Text(String(format: "%+.2f G", Double(sensor.acc[i]))).font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
                        }
                    }
                }
            }
            Tilt(acc: sensor.acc).frame(width: 90, height: 70)
        }
        .padding(.vertical, 2)
    }
}
struct Bar: View {   // a value from -range to range, from the middle
    let value: Double, range: Double
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, f = max(-1, min(1, value / range))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Rectangle().fill(Color.accentColor).frame(width: abs(f) * w / 2, height: g.size.height).offset(x: f < 0 ? w / 2 + f * w / 2 : w / 2)
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 1).offset(x: w / 2)
            }
        }
        .frame(minWidth: 90, maxWidth: 160).frame(height: 6)
    }
}
struct Tilt: View {   // the controller seen from behind: rolled by its left-right tilt, foreshortened by its forward-back tilt (from gravity)
    let acc: SIMD3<Float>
    var body: some View {
        let roll = atan2(Double(acc.x), Double(-acc.z)), pitch = atan2(Double(acc.y), Double(-acc.z))
        RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.25)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 1.5))
            .frame(width: 76, height: 30 * max(0.15, abs(cos(pitch))))
            .rotationEffect(.radians(acc == .zero ? 0 : roll))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

// Mouse buttons and the wheel over this box reach the test
struct MouseTestArea: NSViewRepresentable {
    let state: TestState
    final class V: NSView {
        weak var state: TestState?
        override func mouseDown(with e: NSEvent) { state?.mouseButton(0, true) }
        override func mouseUp(with e: NSEvent) { state?.mouseButton(0, false) }
        override func rightMouseDown(with e: NSEvent) { state?.mouseButton(1, true) }
        override func rightMouseUp(with e: NSEvent) { state?.mouseButton(1, false) }
        override func otherMouseDown(with e: NSEvent) { state?.mouseButton(e.buttonNumber == 2 ? 2 : e.buttonNumber, true) }
        override func otherMouseUp(with e: NSEvent) { state?.mouseButton(e.buttonNumber == 2 ? 2 : e.buttonNumber, false) }
        override func scrollWheel(with e: NSEvent) {
            let s: CGFloat = e.isDirectionInvertedFromDevice ? -1 : 1, dy = e.scrollingDeltaY * s, dx = e.scrollingDeltaX * s
            if abs(dy) > 0.5 { state?.wheel(dy > 0 ? 0 : 1) } else if abs(dx) > 0.5 { state?.wheel(dx > 0 ? 2 : 3) }
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func draw(_ r: NSRect) {
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
            let text = "Click or scroll here to test the mouse" as NSString
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
            let sz = text.size(withAttributes: a); text.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2), withAttributes: a)
        }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.state = state; return v }
    func updateNSView(_ v: V, context: Context) { v.state = state }
}
