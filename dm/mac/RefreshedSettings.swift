// nxnative refreshed: the Mac settings window's pages and the pieces every page uses. The rows of launcher.json (dm/games/settings.tsv through settings.py) keep the
// iOS launcher's model and store (LauncherSettings.swift: launcher.<VAR> in the app's preferences, what launcher.c reads at a start without the window); each goes on the page of
// its section, under its group, with a reset button beside it. The window adds text settings launcher.json has no kind for (refreshed.<VAR>), the input mapping (InputModel.swift)
// and pages of its own (players, controls, hotkeys, saves). Every change is kept at once: Quit keeps it too, and Reset All brings back every default.
import AppKit
import SwiftUI

enum Page: String, CaseIterable, Identifiable, Hashable {
    case game, display, audio, players, controls, sticks, motion, rumble, hotkeys, test, performance, system, saves, advanced, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .game: return "Game"
        case .display: return "Display"
        case .audio: return "Audio"
        case .players: return "Players"
        case .controls: return "Controls"
        case .sticks: return "Sticks and Mouse"
        case .motion: return "Motion"
        case .rumble: return "Rumble"
        case .hotkeys: return "Hotkeys"
        case .test: return "Test"
        case .performance: return "Performance"
        case .system: return "System"
        case .saves: return "Saves and Data"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }
    var symbol: String {
        switch self {
        case .game: return "gamecontroller"
        case .display: return "display"
        case .audio: return "speaker.wave.2"
        case .players: return "person.2"
        case .controls: return "keyboard"
        case .sticks: return "computermouse"
        case .motion: return "gyroscope"
        case .rumble: return "waveform.path"
        case .hotkeys: return "command"
        case .test: return "scope"
        case .performance: return "speedometer"
        case .system: return "gearshape"
        case .saves: return "externaldrive"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .game: return "Frame rate, resolution, console mode and language."
        case .display: return "The game's window, fullscreen and the pointer."
        case .audio: return "How loud the game plays."
        case .players: return "Who plays with the keyboard, the mouse and each controller."
        case .controls: return "Any key, mouse button or controller button for any Switch input, per player."
        case .sticks: return "Dead zones, response curves, thresholds, turbo and the mouse, per player."
        case .motion: return "Gyro and accelerometer, from a controller, the mouse or the keyboard."
        case .rumble: return "The game's HD Rumble on your controllers."
        case .hotkeys: return "Keys and controller buttons for the app itself."
        case .test: return "Try the controls, the motion sensors and the rumble as the game will get them."
        case .performance: return "How frames reach the screen and how the GPU's work is prepared."
        case .system: return "The console's profile, focus and downloadable content."
        case .saves: return "Cloud saves, backups, folders, and moving settings between games."
        case .advanced: return "Switches for testing and for games that need them."
        case .about: return "nxnative refreshed and this game."
        }
    }
    static let sidebar: [(String, [Page])] = [("Game", [.game, .display, .audio, .performance]), ("Input", [.players, .controls, .sticks, .motion, .rumble, .hotkeys, .test]),
                                              ("App", [.system, .saves, .advanced, .about])]
}

extension Setting {
    // The page of a row: its section's, a few rows the iPhone keeps elsewhere aside
    var page: Page {
        switch env {
        case "DM_RUMBLE", "DM_RUMBLE_GAIN", "DM_RUMBLE_MIN": return .rumble
        case "DM_METAL_HUD": return .display
        case "DM_BG_INPUT": return .system
        default: break
        }
        switch sectionTitle {
        case "Game": return .game
        case "Display": return .display
        case "Audio": return .audio
        case "Controls": return .players
        case "Motion": return .motion
        case "System": return .system
        case "Performance": return .performance
        default: return .advanced
        }
    }
    var groupTitle: String { group ?? (page == .advanced && sectionTitle != "Advanced" ? sectionTitle : "General") }
}

extension LauncherModel {
    func rows(on page: Page) -> [Setting] { settings.filter { $0.page == page && visible($0) } }
    func groups(on page: Page) -> [String] { rows(on: page).reduce(into: []) { if !$0.contains($1.groupTitle) { $0.append($1.groupTitle) } } }
    func rows(on page: Page, group: String) -> [Setting] { rows(on: page).filter { $0.groupTitle == group } }
    func isChanged(_ s: Setting) -> Bool { !fixed.contains(s.env) && !s.isDefault(values[s.env] ?? s.def) }
    func resetRow(_ s: Setting) { if !fixed.contains(s.env) { values[s.env] = s.def } }
    func changed(on page: Page) -> Bool { settings.contains { $0.page == page && isChanged($0) } }
    func reset(page: Page) { for s in settings where s.page == page { resetRow(s) } }
    func formatted(_ s: Setting, _ v: Double) -> String {
        switch s.unit {
        case "x": return String(format: "%.2fx", v)
        case "GB": return v == 0 ? "No limit" : "\(Int(v.rounded())) GB"
        case "threads": return v == 0 ? "Automatic" : "\(Int(v.rounded()))"
        default: return rangeLabel(s, v)
        }
    }
}

// Settings launcher.json has no kind for: text, kept as refreshed.<VAR> and put into the environment like the others (a value an env file or the launch set wins)
struct TextSetting: Identifiable {
    let env, label, note, placeholder, def: String
    let page: Page, group: String
    var multiline = false
    var id: String { env }
    var key: String { "refreshed." + env }
    static let all: [TextSetting] = [
        TextSetting(env: "DM_NICK", label: "Player name", note: "The name games show for your profile (at most 32 bytes).", placeholder: "Player", def: "Player", page: .system, group: "Profile"),
        TextSetting(env: "DM_MOTION_AXES", label: "Axis mapping", note: "Apple's controller axes to the Switch's, such as x,-z,y; empty: as they are.", placeholder: "x,y,z", def: "", page: .motion, group: "Tuning"),
        TextSetting(env: "DM_EXTRA_ENV", label: "Extra environment variables", note: "One KEY=VALUE per line, for any switch the host reads (docs/settings.md). They win over the settings above; an env.txt still wins over them.",
                    placeholder: "DM_SHOW_FPS=1", def: "", page: .advanced, group: "Environment", multiline: true),
    ]
}
final class TextStore: ObservableObject {
    @Published var values: [String: String] = [:] { didSet { save() } }
    let fixed: Set<String>
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let env = ProcessInfo.processInfo.environment
        fixed = Set(((env["DM_ENV_FILE_KEYS"] ?? "") + " " + (env["DM_ENV_LAUNCH_KEYS"] ?? "")).split(separator: " ").map(String.init))
        var v: [String: String] = [:]
        for t in TextSetting.all { v[t.env] = defaults.string(forKey: t.key) ?? t.def }
        values = v
    }
    func value(_ t: TextSetting) -> String { fixed.contains(t.env) ? ProcessInfo.processInfo.environment[t.env] ?? "" : values[t.env] ?? t.def }
    func save() {
        for t in TextSetting.all {
            let v = values[t.env] ?? t.def
            if v == t.def { defaults.removeObject(forKey: t.key) } else { defaults.set(v, forKey: t.key) }
        }
    }
    func reset() { values = Dictionary(uniqueKeysWithValues: TextSetting.all.map { ($0.env, $0.def) }) }
    func reset(page: Page) { for t in TextSetting.all where t.page == page { values[t.env] = t.def } }
    func changed(page: Page? = nil) -> Bool { TextSetting.all.contains { (page == nil || $0.page == page) && (values[$0.env] ?? $0.def) != $0.def } }

    // Into the environment, after the rows (so the extra lines win over them); a variable an env file or the launch environment set stays
    static func apply(_ defaults: UserDefaults = .standard) {
        let env = ProcessInfo.processInfo.environment
        let fixed = Set(((env["DM_ENV_FILE_KEYS"] ?? "") + " " + (env["DM_ENV_LAUNCH_KEYS"] ?? "")).split(separator: " ").map(String.init))
        for t in TextSetting.all where t.env != "DM_EXTRA_ENV" {
            guard let v = defaults.string(forKey: t.key), v != t.def, !v.isEmpty else { continue }
            if fixed.contains(t.env) { fputs("launcher: \(t.env) kept (env file or launch)\n", stderr); continue }
            setenv(t.env, t.env == "DM_NICK" ? String(decoding: Array(v.utf8.prefix(32)), as: UTF8.self) : v, 1); fputs("launcher: \(t.env)=\(v) (changed)\n", stderr)
        }
        for line in (defaults.string(forKey: "refreshed.DM_EXTRA_ENV") ?? "").split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "="), eq != l.startIndex else { continue }
            let k = String(l[..<eq]).trimmingCharacters(in: .whitespaces), v = String(l[l.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard k.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { fputs("[RED] launcher: extra environment line ignored: \(l)\n", stderr); continue }
            if fixed.contains(k) { fputs("launcher: extra \(k) not used: an env file or the launch set it\n", stderr); continue }
            setenv(k, v, 1); fputs("launcher: env \(k)=\(v) (extra environment variables)\n", stderr)
        }
    }
}

// The reset button beside every setting
struct ResetButton: View {
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "arrow.uturn.backward.circle.fill").imageScale(.medium) }
            .buttonStyle(.borderless)
            .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.35))
            .disabled(!enabled)
            .help(enabled ? "Reset to the default" : "At its default")
            .accessibilityLabel("Reset to the default")
            .frame(width: 22)
    }
}

// A row of launcher.json, with its reset button
struct EnvRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel
    private var locked: Bool { m.fixed.contains(s.env) }
    private var note: String {
        let def = defaultText
        var parts: [String] = []
        if !s.note.isEmpty { parts.append(s.note) }
        if locked { parts.append(m.fromLaunch.contains(s.env) ? "Set at launch" : "Set by an env file") } else if m.isChanged(s) { parts.append("Default: \(def)") }
        return parts.joined(separator: " · ")
    }
    private var defaultText: String {
        switch s.kind {
        case "choice": return s.options?.first { $0[0] == s.def }?[1] ?? s.def
        case "range": return m.formatted(s, Double(s.def) ?? 0)
        default: return s.def == s.onValue ? "On" : "Off"
        }
    }
    private var rangeValue: Binding<Double> {
        Binding(get: { Double(m.values[s.env] ?? s.def) ?? s.max ?? 1 }, set: { m.values[s.env] = String(format: "%.2f", $0) })
    }
    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.label)
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Group {
                switch s.kind {
                case "choice":
                    Picker(selection: m.binding(s)) { ForEach(s.options ?? [], id: \.[0]) { Text($0[1]).tag($0[0]) } } label: { label }
                        .pickerStyle(.menu)
                case "range":
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { label; Spacer(); Text(m.formatted(s, rangeValue.wrappedValue)).monospacedDigit().foregroundStyle(.secondary) }
                        Slider(value: rangeValue, in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.05).accessibilityLabel(s.label)
                    }
                default:
                    Toggle(isOn: Binding(get: { (m.values[s.env] ?? s.def) == s.onValue }, set: { m.values[s.env] = $0 ? s.onValue : s.offValue })) { label }
                }
            }
            .disabled(locked)
            ResetButton(enabled: m.isChanged(s)) { m.resetRow(s) }
        }
    }
}

struct TextRow: View {
    let t: TextSetting
    @ObservedObject var store: TextStore
    private var locked: Bool { store.fixed.contains(t.env) }
    var body: some View {
        let b = Binding(get: { store.value(t) }, set: { store.values[t.env] = $0 })
        HStack(alignment: t.multiline ? .top : .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if t.multiline {
                    Text(t.label)
                    TextEditor(text: b).font(.system(.body, design: .monospaced)).frame(minHeight: 90).scrollContentBackground(.hidden)
                        .padding(4).background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                } else {
                    TextField(t.label, text: b, prompt: Text(t.placeholder))
                }
                Text(locked ? t.note + " · Set by an env file or at launch" : t.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .disabled(locked)
            ResetButton(enabled: !locked && store.value(t) != t.def) { store.values[t.env] = t.def }
        }
    }
}

// A number the window edits (the input mapping's settings), with its reset button
struct NumberRow: View {
    let label: String
    var note = ""
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 0.05
    let def: Double
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded())) %" }
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                        if !note.isEmpty || abs(value - def) > 1e-9 {
                            Text([note, abs(value - def) > 1e-9 ? "Default: \(format(def))" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $value, in: range, step: step).accessibilityLabel(label)
            }
            ResetButton(enabled: abs(value - def) > 1e-9) { value = def }
        }
    }
}
struct ToggleRow: View {
    let label: String
    var note = ""
    @Binding var value: Bool
    let def: Bool
    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $value) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            ResetButton(enabled: value != def) { value = def }
        }
    }
}
struct ChoiceRow: View {
    let label: String
    var note = ""
    @Binding var value: String
    let options: [(String, String)]
    let def: String
    var body: some View {
        HStack(spacing: 8) {
            Picker(selection: $value) { ForEach(options, id: \.0) { Text($0.1).tag($0.0) } } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    let d = value != def ? "Default: \(options.first { $0.0 == def }?.1 ?? def)" : ""
                    if !note.isEmpty || !d.isEmpty { Text([note, d].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .pickerStyle(.menu)
            ResetButton(enabled: value != def) { value = def }
        }
    }
}

// The rows of launcher.json and the text settings of a page, one box per group
struct EnvSections: View {
    let page: Page
    @ObservedObject var m: LauncherModel
    @ObservedObject var text: TextStore
    var body: some View {
        let texts = TextSetting.all.filter { $0.page == page }
        let groups = m.groups(on: page) + texts.map(\.group).filter { !m.groups(on: page).contains($0) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        ForEach(groups, id: \.self) { g in
            Section(g) {
                ForEach(m.rows(on: page, group: g)) { EnvRow(s: $0, m: m) }
                ForEach(texts.filter { $0.group == g }) { TextRow(t: $0, store: text) }
            }
        }
    }
}

// Paths of this game's data (launcher.c makes the same ones, under $HOME as it does: a test's home, not the account's)
enum AppPaths {
    static var titleID: String { Bundle.main.object(forInfoDictionaryKey: "DMTitleID") as? String ?? "0000000000000000" }
    static var home: URL { ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser }
    static var support: URL { home.appendingPathComponent("Library/Application Support/nxnative/\(titleID)") }
    static var save: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["DM_SAVE"] ?? support.appendingPathComponent("save").path) }
    static var logs: URL { home.appendingPathComponent("Library/Logs/nxnative") }
    static var log: URL { logs.appendingPathComponent("\(titleID).log") }
    static var envFile: URL { support.appendingPathComponent("env.txt") }
    static var profiles: URL { home.appendingPathComponent("Library/Application Support/nxnative/profiles") }
}
