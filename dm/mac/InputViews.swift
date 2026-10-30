// nxnative refreshed: the settings window's input pages: players and their devices, the mapping of every Switch input, sticks and mouse, per-player motion and rumble, hotkeys.
// A binding is recorded by pressing it (a key, a mouse button or the wheel over the box, a controller element) or picked from the list, so a controller that is not connected
// can be mapped too. Conflicts (one key on two inputs of a player, or on a hotkey) are marked.
import AppKit
import CoreHaptics
import GameController
import SwiftUI

// The connected controllers, for the Players page and for recording
final class ControllerMonitor: ObservableObject {
    struct Info: Identifiable, Hashable { let id: ObjectIdentifier; let name, category: String; let motion, haptics: Bool; let battery: String }
    @Published var controllers: [Info] = []
    private var observers: [NSObjectProtocol] = []
    static let shared = ControllerMonitor()
    init() {
        GCController.shouldMonitorBackgroundEvents = false
        for n in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        GCController.startWirelessControllerDiscovery {}
        refresh()
    }
    func refresh() {
        controllers = GCController.controllers().filter { $0.extendedGamepad != nil }.map { c in
            let b = c.battery.map { $0.batteryState == .charging ? "charging, \(Int($0.batteryLevel * 100)) %" : "\(Int($0.batteryLevel * 100)) %" } ?? ""
            return Info(id: ObjectIdentifier(c), name: c.vendorName ?? "Controller", category: c.productCategory, motion: c.motion?.hasRotationRate ?? false,
                        haptics: !(c.haptics?.supportedLocalities.isEmpty ?? true), battery: b)
        }
    }
    func controller(_ info: Info) -> GCController? { GCController.controllers().first { ObjectIdentifier($0) == info.id } }
    // The player each connected controller is expected to get at the start, -1 for none (front_mac.m assign_pads, without the reconnect memory)
    func owners(_ config: InputConfig) -> [Int] {
        let cs = controllers, ps = config.players
        if config.merge { return cs.map { _ in 0 } }
        var owner = [Int](repeating: -1, count: cs.count)
        for (p, c) in ps.enumerated() where c.controller.hasPrefix("name:") {
            let name = String(c.controller.dropFirst(5))
            if let i = cs.indices.first(where: { owner[$0] < 0 && (cs[$0].name.caseInsensitiveCompare(name) == .orderedSame || cs[$0].category.caseInsensitiveCompare(name) == .orderedSame) }) { owner[i] = p }
        }
        for (p, c) in ps.enumerated() where c.controller.hasPrefix("index:") {
            if let n = Int(c.controller.dropFirst(6)), n >= 1, n <= cs.count, owner[n - 1] < 0 { owner[n - 1] = p }
        }
        var taken = Set(owner.filter { $0 >= 0 })
        for i in cs.indices where owner[i] < 0 {
            if let p = ps.indices.first(where: { ps[$0].controller == "auto" && !taken.contains($0) }) { owner[i] = p; taken.insert(p) }
        }
        return owner
    }
    func controllers(of player: Int, _ config: InputConfig) -> [GCController] {
        let owner = owners(config)
        return controllers.indices.compactMap { owner[$0] == player ? controller(controllers[$0]) : nil }
    }

    // A short rumble on one controller at a player's strength: two pulses, the low band's then the high band's feel
    private var engines: [ObjectIdentifier: CHHapticEngine] = [:]
    func test(_ info: Info, player: PlayerConfig? = nil, globalGain: Double = 1) {
        guard let c = controller(info), let h = c.haptics else { return }
        let gain = Float(min(1, (player?.rumbleGain ?? 1) * globalGain))
        guard gain > 0, player?.rumbleOn ?? true else { return }
        do {
            let engine = try engines[info.id] ?? { guard let e = h.createEngine(withLocality: .default) else { throw NSError(domain: "rumble", code: 1) }; return e }()
            engines[info.id] = engine
            try engine.start()
            let low = Float(min(1, player?.rumbleLow ?? 1)), high = Float(min(1, player?.rumbleHigh ?? 1))
            let events = [
                CHHapticEvent(eventType: .hapticContinuous, parameters: [.init(parameterID: .hapticIntensity, value: gain * low), .init(parameterID: .hapticSharpness, value: 0.2)], relativeTime: 0, duration: 0.35),
                CHHapticEvent(eventType: .hapticContinuous, parameters: [.init(parameterID: .hapticIntensity, value: gain * high), .init(parameterID: .hapticSharpness, value: 0.8)], relativeTime: 0.5, duration: 0.25),
            ]
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch { fputs("launcher: rumble test on \(info.name): \(error.localizedDescription)\n", stderr) }
    }
}

// The player picker the per-player pages share
struct PlayerPicker: View {
    @Binding var player: Int
    var body: some View {
        Picker("Player", selection: $player) { ForEach(0..<8, id: \.self) { Text("\($0 + 1)").tag($0) } }
            .pickerStyle(.segmented).frame(maxWidth: 360)
    }
}

// ---------- Players ----------
struct PlayersPage: View {
    @ObservedObject var input: InputStore
    @ObservedObject var monitor = ControllerMonitor.shared
    var body: some View {
        Section {
            ForEach(PlayerSetup.allCases) { s in
                Button { s.apply(to: &input.config) } label: { Label(s.rawValue, systemImage: "person.2.badge.gearshape") }.buttonStyle(.link)
            }
        } header: { Text("Quick setups") } footer: { Text("A quick setup changes who plays with what below; the two-players-on-one-keyboard setup also maps their keys.") }
        Section("Players") {
            ToggleRow(label: "Every controller plays Player 1", note: "For a one-player game with several controllers at hand: the last one moved rumbles.",
                      value: $input.config.merge, def: false)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Player").font(.caption).foregroundStyle(.secondary)
                    Text("Keyboard").font(.caption).foregroundStyle(.secondary)
                    Text("Mouse").font(.caption).foregroundStyle(.secondary)
                    Text("Controller").font(.caption).foregroundStyle(.secondary)
                    Text("").gridCellUnsizedAxes(.horizontal)
                }
                ForEach(0..<8, id: \.self) { i in
                    let def = PlayerConfig.defaults(i)
                    let p = input.config.players[i]
                    GridRow {
                        Text("Player \(i + 1)").fontWeight(.medium)
                        Toggle("", isOn: $input.config.players[i].keyboard).labelsHidden()
                        Toggle("", isOn: $input.config.players[i].mouse).labelsHidden()
                        Picker("", selection: $input.config.players[i].controller) {
                            Text("Automatic (next free)").tag("auto")
                            Text("None").tag("none")
                            Divider()
                            ForEach(1...8, id: \.self) { n in Text("The \(Self.ordinal(n)) controller connected").tag("index:\(n)") }
                            let named = names(including: p.controller)
                            if !named.isEmpty {
                                Divider()
                                ForEach(named, id: \.self) { n in Text(n).tag("name:" + n) }
                            }
                        }
                        .labelsHidden().disabled(input.config.merge).fixedSize()
                        ResetButton(enabled: p.keyboard != def.keyboard || p.mouse != def.mouse || p.controller != def.controller) {
                            input.config.players[i].keyboard = def.keyboard; input.config.players[i].mouse = def.mouse; input.config.players[i].controller = def.controller
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        Section {
            if monitor.controllers.isEmpty {
                Text("No controller is connected. Connect one by Bluetooth or USB; it appears here.").foregroundStyle(.secondary)
            }
            ForEach(Array(monitor.controllers.enumerated()), id: \.element.id) { n, c in
                HStack(spacing: 10) {
                    Image(systemName: "gamecontroller.fill").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(n + 1). \(c.name)").fontWeight(.medium)
                        Text([c.category, c.motion ? "motion" : "no motion", c.haptics ? "rumble" : "no rumble", c.battery.isEmpty ? "" : "battery \(c.battery)"].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(expected(n)).font(.caption).foregroundStyle(.secondary)
                    Button("Rumble") { monitor.test(c) }.disabled(!c.haptics).help("A short rumble, to tell controllers apart")
                }
            }
        } header: { Text("Connected controllers") } footer: {
            Text("Controllers take players when the game starts and whenever one connects: by name first, then by the order they connected, then the automatic order, in which a controller that comes back gets its player back.")
        }
    }
    private func names(including current: String) -> [String] {
        var n = monitor.controllers.map(\.name)
        if current.hasPrefix("name:") { let c = String(current.dropFirst(5)); if !n.contains(c) { n.append(c) } }
        return n.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    static func ordinal(_ n: Int) -> String { ["1st", "2nd", "3rd", "4th", "5th", "6th", "7th", "8th"][n - 1] }
    private func expected(_ index: Int) -> String {
        let owner = monitor.owners(input.config)
        return owner[index] >= 0 ? "→ Player \(owner[index] + 1)" : "not used"
    }
}

// ---------- Recording a binding ----------
// Keys and mouse buttons come from AppKit's events, a controller's elements from polling GameController (the first element pushed past half way)
final class Recorder: ObservableObject {
    @Published var result: InputBind?
    private var monitor: Any?, timer: Timer?, baseline: [ObjectIdentifier: [String: Float]] = [:]
    func start(_ src: BindSource) {
        stop(); result = nil
        switch src {
        case .key:
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
                if let t = e.window?.firstResponder as? NSTextView, t.isFieldEditor { return e }   // typing in the search field searches
                guard let self, self.result == nil else { return nil }   // the first key is the binding; keys after it, while the popover closes, go nowhere
                if e.type == .flagsChanged { if KeyNames.modifierDown(e) { self.result = .key(Int(e.keyCode)) }; return nil }
                if !e.isARepeat { self.result = .key(Int(e.keyCode)) }
                return nil
            }
        case .pad:
            baseline = Dictionary(uniqueKeysWithValues: GCController.controllers().map { (ObjectIdentifier($0), PadNames.sample($0)) })
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.poll() }
        case .mouse: break   // MouseCaptureView reports it
        }
    }
    private func poll() {
        for c in GCController.controllers() {
            let now = PadNames.sample(c), base = baseline[ObjectIdentifier(c)] ?? [:]
            for (code, v) in now where v > 0.6 && (base[code] ?? 0) < 0.3 { result = .pad(code); stop(); return }
            baseline[ObjectIdentifier(c)] = base.merging(now.filter { $0.value < 0.3 }) { _, n in n }   // an element let go counts again
        }
    }
    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil
        timer?.invalidate(); timer = nil
    }
    deinit { stop() }
}
struct MouseCaptureView: NSViewRepresentable {
    let report: (String) -> Void
    final class V: NSView {
        var report: ((String) -> Void)?
        private var reported = false   // the first button or scroll is the binding, not the rest of a double click or of a scroll's events
        private func send(_ code: String) { if !reported { reported = true; report?(code) } }
        override func mouseDown(with e: NSEvent) { send("left") }
        override func rightMouseDown(with e: NSEvent) { send("right") }
        override func otherMouseDown(with e: NSEvent) {
            let n = e.buttonNumber
            if n == 2 { send("middle") } else if n >= 3 && n <= 7 { send("button\(n + 1)") }
        }
        override func scrollWheel(with e: NSEvent) {
            let s: CGFloat = e.isDirectionInvertedFromDevice ? -1 : 1, dy = e.scrollingDeltaY * s, dx = e.scrollingDeltaX * s
            if abs(dy) > 0.5 { send(dy > 0 ? "wheel_up" : "wheel_down") } else if abs(dx) > 0.5 { send(dx > 0 ? "wheel_left" : "wheel_right") }
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.report = report; return v }
    func updateNSView(_ v: V, context: Context) { v.report = report }
}

struct BindingEditor: View {
    let title: String
    let source: BindSource
    let current: InputBind?
    let done: (InputBind?) -> Void   // nil: cleared
    let cancel: () -> Void
    @StateObject private var rec = Recorder()
    @State private var search = ""
    @FocusState private var searching: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Group {
                switch source {
                case .key:   // keys record unless the search field has the focus; a click on the prompt takes it back
                    if searching {
                        Button { searching = false } label: { prompt("Typing searches the list", "Click here to record a key instead.", busy: false) }.buttonStyle(.plain)
                    } else {
                        prompt("Press a key now", "Any key, including Escape and the modifier keys on their own.")
                    }
                case .pad: prompt("Press a button or move a stick on a controller", GCController.controllers().isEmpty ? "No controller is connected: pick from the list below." : "Any connected controller.")
                case .mouse:
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12))
                        RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                        VStack(spacing: 4) {
                            Image(systemName: "computermouse").font(.title2)
                            Text("Click here with a mouse button, or scroll").font(.callout)
                        }
                        MouseCaptureView { done(.mouse($0)) }
                    }
                    .frame(height: 90)
                }
            }
            TextField("Search", text: $search).textFieldStyle(.roundedBorder).focused($searching)
            List {
                ForEach(groups, id: \.self) { g in
                    Section(g) {
                        ForEach(options(in: g), id: \.0) { o in
                            Button { done(InputBind(src: source, code: o.0)) } label: {
                                HStack { Text(o.1); Spacer(); if current?.code == o.0 { Image(systemName: "checkmark") } }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(height: 220)
            HStack {
                Button("Clear", role: .destructive) { done(nil) }.disabled(current == nil)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)   // while recording, Escape is a key to record: the recorder takes it before the shortcut
            }
        }
        .padding(14).frame(width: 340)
        .onAppear {
            rec.start(source)
            // the popover gives its text field the focus when it opens, and keys would search instead of recording
            DispatchQueue.main.async { searching = false; if let w = NSApp.keyWindow, (w.firstResponder as? NSTextView)?.isFieldEditor == true { w.makeFirstResponder(nil) } }
        }
        .onDisappear { rec.stop() }
        .onChange(of: rec.result) { _, r in if let r { done(r) } }
    }
    private func prompt(_ t: String, _ sub: String, busy: Bool = true) -> some View {
        HStack(spacing: 10) {
            if busy { ProgressView().controlSize(.small) } else { Image(systemName: "record.circle").foregroundStyle(.tint) }
            VStack(alignment: .leading, spacing: 2) { Text(t).font(.callout.weight(.medium)); Text(sub).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
    }
    private var all: [(String, String, String)] {   // code, name, group
        switch source {
        case .key: return KeyNames.table.map { (String($0.0), $0.1, $0.2) }
        case .mouse: return MouseNames.table.map { ($0.0, $0.1, "Mouse") }
        case .pad: return PadNames.table.map { ($0.code, $0.long, $0.group) }
        }
    }
    private var filtered: [(String, String, String)] { search.isEmpty ? all : all.filter { $0.1.localizedCaseInsensitiveContains(search) } }
    private var groups: [String] { filtered.reduce(into: []) { if !$0.contains($1.2) { $0.append($1.2) } } }
    private func options(in g: String) -> [(String, String)] { filtered.filter { $0.2 == g }.map { ($0.0, $0.1) } }
}

// One binding cell: its label, a popover to record or pick another
struct BindingCell: View {
    let title: String
    let source: BindSource
    @Binding var bind: InputBind?
    var conflict: String? = nil
    @State private var editing = false
    var body: some View {
        Button { editing = true } label: {
            HStack(spacing: 4) {
                if let c = conflict { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(c) }
                Text(bind?.label ?? "—").lineLimit(1).truncationMode(.middle).foregroundStyle(bind == nil ? .secondary : .primary)
            }
            .frame(minWidth: 72, maxWidth: .infinity)
        }
        .controlSize(.small)
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            BindingEditor(title: title, source: source, current: bind, done: { bind = $0; editing = false }, cancel: { editing = false })
        }
        .accessibilityLabel("\(title): \(bind?.label ?? "not bound")")
    }
}

// ---------- Controls: the mapping table ----------
struct ControlsPage: View {
    @ObservedObject var input: InputStore
    @Binding var player: Int
    var body: some View {
        let p = input.config.players[player], def = PlayerConfig.defaults(player)
        Section {
            HStack {
                PlayerPicker(player: $player)
                Spacer()
                Menu("Presets") {
                    ForEach(MappingPreset.allCases) { pr in Button(pr.rawValue) { pr.apply(to: &input.config.players[player], index: player) } }
                    Divider()
                    Menu("Copy from") {
                        ForEach(0..<8, id: \.self) { o in
                            if o != player { Button("Player \(o + 1)") { input.config.players[player].binds = input.config.players[o].binds; input.config.players[player].modes = input.config.players[o].modes } }
                        }
                    }
                }
                .fixedSize()
                Button("Reset Player \(player + 1)'s Mapping") { input.config.players[player].binds = def.binds; input.config.players[player].modes = [:] }
                    .disabled(p.sameBinds(def))
            }
            if !p.keyboard || !p.mouse {
                Label(!p.keyboard && !p.mouse ? "Player \(player + 1) does not read the keyboard or the mouse (Players page): only the controller columns count."
                      : !p.keyboard ? "Player \(player + 1) does not read the keyboard (Players page)." : "Player \(player + 1) does not read the mouse (Players page).", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Click a cell, then press what should drive that input, or pick it from the list. Mode: Hold presses while held, Toggle turns on and off with each press (an auto-run on a stick direction), Turbo repeats while held. A controller's face buttons are named by position: on a Nintendo controller, East is A.")
        }
        ForEach(SwitchInputs.groups, id: \.self) { g in
            Section(g) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Switch input").font(.caption).foregroundStyle(.secondary)
                        ForEach(BindColumn.allCases) { Text($0.title).font(.caption).foregroundStyle(.secondary) }
                        Text("Mode").font(.caption).foregroundStyle(.secondary)
                        Text("")
                    }
                    ForEach(SwitchInputs.all.filter { $0.group == g }) { t in
                        GridRow {
                            Text(t.label).frame(minWidth: 112, alignment: .leading)
                            ForEach(BindColumn.allCases) { col in
                                BindingCell(title: "\(t.label): \(col.title)", source: col.source,
                                            bind: Binding(get: { input.config.players[player].slots(t.id)[col.rawValue] }, set: { input.config.players[player].set(t.id, col, $0) }),
                                            conflict: conflict(t.id, col))
                            }
                            Picker("", selection: Binding(get: { input.config.players[player].mode(t.id) }, set: { input.config.players[player].modes[t.id] = $0 == "hold" ? nil : $0 })) {
                                Text("Hold").tag("hold"); Text("Toggle").tag("toggle"); Text("Turbo").tag("turbo")
                            }
                            .labelsHidden().frame(width: 84).controlSize(.small)
                            ResetButton(enabled: p.slots(t.id) != def.slots(t.id) || p.mode(t.id) != "hold") {
                                input.config.players[player].setSlots(t.id, def.slots(t.id)); input.config.players[player].modes[t.id] = nil
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
    // A key, mouse button or element this player uses for another input too, or that a hotkey takes
    private func conflict(_ target: String, _ col: BindColumn) -> String? {
        let p = input.config.players[player]
        guard let b = p.slots(target)[col.rawValue] else { return nil }
        var also: [String] = []
        for t in SwitchInputs.all where t.id != target && p.slots(t.id).contains(b) { also.append(t.label) }
        for h in Hotkeys.all where input.config.hotkey(h.id).contains(b) { also.append("the hotkey \"\(h.label)\" (it wins)") }
        if b.src == .key, !p.keyboard { return "Player \(player + 1) does not read the keyboard" }
        if b.src == .mouse, !p.mouse { return "Player \(player + 1) does not read the mouse" }
        return also.isEmpty ? nil : "Also bound to " + also.joined(separator: ", ")
    }
}

// ---------- Sticks and mouse ----------
struct StickCurve: View {   // the stick's response: output against deflection, through its dead zone, edge, curve, sensitivity and minimum
    let s: StickConfig
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
            ctx.stroke(Path(r), with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
            ctx.stroke(Path { $0.move(to: CGPoint(x: r.minX, y: r.maxY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.minY)) }, with: .color(.secondary.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3]))
            var path = Path()
            for i in 0...100 {
                let x = Double(i) / 100, y = Self.response(s, x)
                let p = CGPoint(x: r.minX + r.width * x, y: r.maxY - r.height * y)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .color(.accentColor), lineWidth: 2)
        }
        .frame(width: 110, height: 110)
        .accessibilityHidden(true)
    }
    static func response(_ s: StickConfig, _ m: Double) -> Double {   // input_map.h im_stick, for one axis
        let dz = max(0, min(0.95, s.deadzone)); if m <= dz { return 0 }
        let outer = max(dz + 0.01, min(1, s.outer > 0 ? s.outer : 1))
        var n = (min(m, outer) - dz) / (outer - dz)
        if s.curve > 0 && s.curve != 1 { n = pow(n, s.curve) }
        let anti = max(0, min(0.9, s.anti)); n = anti + (1 - anti) * n
        return min(1, n * (s.sens > 0 ? s.sens : 1))
    }
}
struct SticksPage: View {
    @ObservedObject var input: InputStore
    @Binding var player: Int
    private func x(_ v: Double) -> String { String(format: "%.2fx", v) }
    var body: some View {
        let def = PlayerConfig.defaults(player)
        Section { PlayerPicker(player: $player) } footer: { Text("These settings are Player \(player + 1)'s. The controller's sticks are read as the controller reports them; the dead zone here is on top of its own.") }
        ForEach(0..<2, id: \.self) { k in
            Section(k == 0 ? "Controller left stick" : "Controller right stick") {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 10) {
                        NumberRow(label: "Dead zone", note: "Deflection the stick ignores.", value: $input.config.players[player].sticks[k].deadzone, range: 0...0.9, step: 0.01, def: def.sticks[k].deadzone)
                        NumberRow(label: "Outer edge", note: "Deflection that already counts as full.", value: $input.config.players[player].sticks[k].outer, range: 0.3...1, step: 0.01, def: def.sticks[k].outer)
                        NumberRow(label: "Response curve", note: "Above 1x: finer control near the center.", value: $input.config.players[player].sticks[k].curve, range: 0.3...3, step: 0.05, def: def.sticks[k].curve, format: x)
                        NumberRow(label: "Sensitivity", value: $input.config.players[player].sticks[k].sens, range: 0.25...2, step: 0.05, def: def.sticks[k].sens, format: x)
                        NumberRow(label: "Minimum output", note: "The smallest deflection past the dead zone, for games with a dead zone of their own.", value: $input.config.players[player].sticks[k].anti, range: 0...0.9, step: 0.01, def: def.sticks[k].anti)
                        ToggleRow(label: "Invert horizontal", value: $input.config.players[player].sticks[k].invX, def: false)
                        ToggleRow(label: "Invert vertical", value: $input.config.players[player].sticks[k].invY, def: false)
                    }
                    StickCurve(s: input.config.players[player].sticks[k])
                }
            }
        }
        Section("Buttons from analog inputs") {
            NumberRow(label: "Trigger press point", note: "0: the controller's own. Where ZL / ZR (or whatever a trigger drives) counts as pressed.", value: $input.config.players[player].triggerPress,
                      range: 0...0.95, step: 0.05, def: def.triggerPress, format: { $0 == 0 ? "Controller's own" : "\(Int(($0 * 100).rounded())) %" })
            NumberRow(label: "Stick press point", note: "A stick direction bound to a button presses it from this deflection.", value: $input.config.players[player].stickPress, range: 0.1...0.95, step: 0.05, def: def.stickPress)
        }
        Section("Keys and buttons on a stick") {
            NumberRow(label: "Stick deflection from a key", note: "How far a key (or a mouse button) bound to a stick direction tilts it.", value: $input.config.players[player].keyStick, range: 0.1...1, step: 0.05, def: def.keyStick)
            NumberRow(label: "Walk", note: "The left stick's deflection while Walk is held (bind it on the Controls page).", value: $input.config.players[player].walk, range: 0.1...1, step: 0.05, def: def.walk)
            NumberRow(label: "Turbo rate", note: "Presses per second of an input in Turbo mode.", value: $input.config.players[player].turboHz, range: 2...30, step: 1, def: def.turboHz, format: { "\(Int($0)) per second" })
        }
        Section {
            ChoiceRow(label: "The mouse moves", value: $input.config.players[player].mouseMode,
                      options: [("touch", "The touchscreen (left button touches)"), ("right_stick", "The right stick (camera)"), ("left_stick", "The left stick"), ("gyro", "The gyro (motion aiming)"), ("off", "Nothing (buttons only)")],
                      def: def.mouseMode)
            NumberRow(label: "Horizontal sensitivity", value: $input.config.players[player].mouseSensX, range: 0.1...5, step: 0.05, def: def.mouseSensX, format: x)
            NumberRow(label: "Vertical sensitivity", value: $input.config.players[player].mouseSensY, range: 0.1...5, step: 0.05, def: def.mouseSensY, format: x)
            NumberRow(label: "Smoothing", note: "Evens out the stick's movement; more feels heavier.", value: $input.config.players[player].mouseSmooth, range: 0...0.95, step: 0.05, def: def.mouseSmooth)
            ToggleRow(label: "Invert horizontal", value: $input.config.players[player].mouseInvX, def: false)
            ToggleRow(label: "Invert vertical", value: $input.config.players[player].mouseInvY, def: false)
        } header: { Text("Mouse") } footer: {
            Text(input.config.players[player].mouse ? "As a stick or a gyro the pointer is captured with a click in the game and released with Esc (Hotkeys page)." : "Player \(player + 1) does not read the mouse: turn it on on the Players page.")
        }
    }
}

// ---------- Motion and rumble, per player ----------
struct MotionPlayerSection: View {
    @ObservedObject var input: InputStore
    @Binding var player: Int
    private func x(_ v: Double) -> String { String(format: "%.2fx", v) }
    var body: some View {
        let def = PlayerConfig.defaults(player)
        Section {
            PlayerPicker(player: $player)
            ChoiceRow(label: "Motion comes from", value: $input.config.players[player].motionSource,
                      options: [("controller", "The controller's gyro"), ("mouse", "The mouse (when it is the gyro)"), ("keys", "Tilt keys (Controls page)"), ("off", "Nowhere: the controller lies still")],
                      def: def.motionSource)
            NumberRow(label: "Gyro sensitivity", value: $input.config.players[player].gyroSens, range: 0.1...4, step: 0.05, def: def.gyroSens, format: x)
            ToggleRow(label: "Invert pitch (tilting forward and back)", value: $input.config.players[player].invPitch, def: false)
            ToggleRow(label: "Invert roll (tilting left and right)", value: $input.config.players[player].invRoll, def: false)
            ToggleRow(label: "Invert yaw (turning)", value: $input.config.players[player].invYaw, def: false)
        } header: { Text("Player motion") } footer: {
            Text("A controller with a gyro (DualSense, DualShock 4, Switch Pro, Joy-Con) drives the game's motion controls as on a Switch. Shake is a binding on the Controls page; the tilt keys too.")
        }
        Section("Emulated motion (keyboard and mouse)") {
            NumberRow(label: "Mouse gyro sensitivity", note: "With the mouse as the gyro (Sticks and Mouse page).", value: $input.config.players[player].mouseGyroSens, range: 0.1...5, step: 0.05, def: def.mouseGyroSens, format: x)
            NumberRow(label: "Tilt angle", note: "How far the tilt keys tilt the controller.", value: $input.config.players[player].tiltAngle, range: 5...90, step: 1, def: def.tiltAngle, format: { "\(Int($0))°" })
            NumberRow(label: "Tilt speed", value: $input.config.players[player].tiltSpeed, range: 30...720, step: 10, def: def.tiltSpeed, format: { "\(Int($0))° per second" })
            NumberRow(label: "Turn speed", note: "The turn keys' rate.", value: $input.config.players[player].twistSpeed, range: 30...720, step: 10, def: def.twistSpeed, format: { "\(Int($0))° per second" })
            NumberRow(label: "Return to level", note: "0: the mouse gyro stays where it was moved. Otherwise how fast it levels again when the mouse rests.",
                      value: $input.config.players[player].autoCenter, range: 0...360, step: 5, def: def.autoCenter, format: { $0 == 0 ? "Stays" : "\(Int($0))° per second" })
        }
    }
}
struct RumblePlayerSection: View {
    @ObservedObject var input: InputStore
    @ObservedObject var monitor = ControllerMonitor.shared
    @Binding var player: Int
    let globalGain: Double
    var globalMin = 0.0
    private func hd(_ c: ControllerMonitor.Info) -> Int? { monitor.controller(c).flatMap { dm_pad_is_nintendo($0) ? RumblePlayer.device(for: $0) : nil } }
    // A Nintendo controller plays its two bands in HD Rumble, as the game will (the Test page's patterns); another controller a short pulse through Core Haptics
    private func tryOn(_ c: ControllerMonitor.Info) {
        if let d = hd(c), let pattern = RumblePattern.all.first(where: { $0.id == "impacts" }) {
            RumblePlayer.shared.shape = RumblePlayer.shaping(input.config.players[player], gain: globalGain, min: globalMin)
            RumblePlayer.shared.play(pattern, on: d)
        } else { monitor.test(c, player: input.config.players[player], globalGain: globalGain) }
    }
    var body: some View {
        let def = PlayerConfig.defaults(player)
        Section {
            PlayerPicker(player: $player)
            ToggleRow(label: "Rumble for Player \(player + 1)", value: $input.config.players[player].rumbleOn, def: true)
            NumberRow(label: "Strength", value: $input.config.players[player].rumbleGain, range: 0...3, step: 0.05, def: def.rumbleGain)
            NumberRow(label: "Low band (160 Hz)", note: "The deep part of HD Rumble: impacts, engines.", value: $input.config.players[player].rumbleLow, range: 0...3, step: 0.05, def: def.rumbleLow)
            NumberRow(label: "High band (320 Hz)", note: "The sharp part: textures, clicks.", value: $input.config.players[player].rumbleHigh, range: 0...3, step: 0.05, def: def.rumbleHigh)
            NumberRow(label: "Cutoff", note: "Weaker rumble stays off on this player's controller (the larger of this and the cutoff above).", value: $input.config.players[player].rumbleMin, range: 0...0.9, step: 0.05, def: def.rumbleMin)
            ToggleRow(label: "Swap left and right motors", value: $input.config.players[player].rumbleSwap, def: false)
            if !monitor.controllers.isEmpty {
                HStack {
                    Text("Try it on")
                    ForEach(monitor.controllers) { c in Button(c.name) { tryOn(c) }.disabled(!c.haptics && hd(c) == nil) }
                }
                .onAppear { _ = dm_test_switch_count() }   // opens the Nintendo controllers' HID devices before the first try
            }
        } header: { Text("Player rumble") } footer: {
            Text("The game drives a Switch controller's two HD Rumble motors, each with a low and a high band. A Pro Controller or Joy-Con plays them exactly, as on a Switch; a controller with left and right handles (DualSense, Xbox) keeps the motors apart, a DualShock 4 its strong and weak motor. The Test page has patterns to compare.")
        }
    }
}

// ---------- Hotkeys ----------
struct HotkeysPage: View {
    @ObservedObject var input: InputStore
    var body: some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Action").font(.caption).foregroundStyle(.secondary)
                    ForEach(Hotkeys.columns, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    Text("")
                }
                ForEach(Hotkeys.all, id: \.id) { h in
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.label)
                            if !h.note.isEmpty { Text(h.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                        .frame(minWidth: 220, alignment: .leading)
                        ForEach(0..<3, id: \.self) { col in
                            BindingCell(title: "\(h.label): \(Hotkeys.columns[col])", source: Hotkeys.source(col),
                                        bind: Binding(get: { input.config.hotkey(h.id)[col] }, set: { input.config.setHotkey(h.id, col, $0) }))
                        }
                        ResetButton(enabled: input.config.hotkey(h.id) != InputConfig.defaults.hotkey(h.id)) { input.config.hotkeys[h.id] = InputConfig.defaults.hotkeys[h.id] }
                    }
                }
            }
        } footer: {
            Text("A hotkey's key or button does not reach the game. A controller's Home or Share button makes a good hotkey: games get nothing from them otherwise.")
        }
    }
}
