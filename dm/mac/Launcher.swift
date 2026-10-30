// Mac app launcher: the settings window shown before the game starts, in the launcher's own process (launcher.c calls dm_mac_launcher before it starts the host). nxnative refreshed
// makes it a window with a page per subject (RefreshedSettings.swift Page): the game's rows of Resources/dm/launcher.json (dm/games/settings.py with SETTINGS_PLATFORM=mac) on their
// pages, the input mapping and its players (InputModel.swift, InputViews.swift), hotkeys, saves and data. The rows keep the iOS launcher's model and store (dm/ios/Sources/
// LauncherSettings.swift: launcher.<VAR> in the app's preferences, which launcher.c reads when the window is not shown; docs/frontends.md, Saved choices). Every option has a reset
// button, every page a Reset Page, and Reset All brings back every default. Changes are kept as they are made.
// Play puts the settings into this process's environment, which the host inherits, and writes input.json for the host (DM_INPUT_CONFIG); Quit and closing the window end the
// app without the game. "Show this window at launch" off: no window unless Option is held at launch; launcher.c then applies the saved choices and dm_mac_apply_extras the
// rest. The window never takes focus by itself: an app opened in the background (open -g) keeps its window behind until the player switches to it
import AppKit
import SwiftUI

private func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }

struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    @ObservedObject var input: InputStore
    @ObservedObject var text: TextStore
    let done: (Bool) -> Void
    @AppStorage("window.show") private var show = true
    @AppStorage("window.page") private var pageName = Page.game.rawValue
    @State private var player = 0
    @State private var confirmReset = false

    private var page: Binding<Page?> { Binding(get: { Page(rawValue: pageName) ?? .game }, set: { pageName = ($0 ?? .game).rawValue }) }
    private var current: Page { Page(rawValue: pageName) ?? .game }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(selection: page) {
                    ForEach(Page.sidebar, id: \.0) { section in
                        Section(section.0) {
                            ForEach(section.1) { p in
                                Label(p.title, systemImage: p.symbol).tag(Optional(p))
                                    .badge(pageChanged(p) ? Text("•") : nil)
                            }
                        }
                    }
                }
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            } detail: {
                Form {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: current.symbol).font(.system(size: 26)).foregroundStyle(.tint).frame(width: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(current.title).font(.title2.weight(.semibold))
                                Text(current.subtitle).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if current != .about {
                                Button("Reset Page") { resetPage(current) }.disabled(!pageChanged(current))
                            }
                        }
                    }
                    pageContent(current)
                }
                .formStyle(.grouped)
                .id(current)
            }
            Divider()
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(info("CFBundleName") ?? "Game").font(.headline)
                    Text("Version \(info("CFBundleShortVersionString") ?? "1.0") · nxnative refreshed").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Show this window at launch", isOn: $show).toggleStyle(.checkbox)
                    .help("Off: the game starts at once with these settings. Hold Option while the app opens to see this window again.")
                Button("Reset All…") { confirmReset = true }.disabled(!anyChanged)
                Button("Quit") { done(false) }
                Button("Play") { done(true) }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 560)
        .onChange(of: m.values) { _, _ in m.persist() }
        .alert("Reset every setting?", isPresented: $confirmReset) {
            Button("Reset All", role: .destructive) { m.reset(); input.reset(); text.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every page goes back to its default: the game's tested settings, nxnative's controls for every player, and the defaults of rumble, motion and hotkeys. Settings an env.txt fixes stay. Cloud saves and your save are not touched.")
        }
    }

    private var anyChanged: Bool { m.changed || input.changed || text.changed() || Page.allCases.contains(where: pageChanged) }
    private func pageChanged(_ p: Page) -> Bool {
        if m.changed(on: p) || text.changed(page: p) { return true }
        let c = input.config, d = InputConfig.defaults
        switch p {
        case .players: return c.merge != d.merge || zip(c.players, d.players).contains { $0.keyboard != $1.keyboard || $0.mouse != $1.mouse || $0.controller != $1.controller }
        case .controls: return zip(c.players, d.players).contains { !$0.sameBinds($1) }
        case .sticks: return zip(c.players, d.players).contains { Self.sticks($0) != Self.sticks($1) }
        case .motion: return zip(c.players, d.players).contains { Self.motion($0) != Self.motion($1) }
        case .rumble: return zip(c.players, d.players).contains { Self.rumble($0) != Self.rumble($1) }
        case .hotkeys: return !c.sameHotkeys(d)
        default: return false
        }
    }
    // The per-player settings each page owns, to compare and reset by page
    private static func sticks(_ p: PlayerConfig) -> [Double] {
        p.sticks.flatMap { [$0.deadzone, $0.outer, $0.curve, $0.sens, $0.anti, $0.invX ? 1 : 0, $0.invY ? 1 : 0] } + [p.triggerPress, p.stickPress, p.keyStick, p.walk, p.turboHz,
            p.mouseSensX, p.mouseSensY, p.mouseSmooth, p.mouseInvX ? 1 : 0, p.mouseInvY ? 1 : 0, Double(["touch", "right_stick", "left_stick", "gyro", "off"].firstIndex(of: p.mouseMode) ?? 9)]
    }
    private static func motion(_ p: PlayerConfig) -> [Double] {
        [Double(["controller", "mouse", "keys", "off"].firstIndex(of: p.motionSource) ?? 9), p.gyroSens, p.invPitch ? 1 : 0, p.invRoll ? 1 : 0, p.invYaw ? 1 : 0, p.mouseGyroSens, p.tiltAngle, p.tiltSpeed, p.twistSpeed, p.autoCenter]
    }
    private static func rumble(_ p: PlayerConfig) -> [Double] { [p.rumbleOn ? 1 : 0, p.rumbleGain, p.rumbleLow, p.rumbleHigh, p.rumbleMin, p.rumbleSwap ? 1 : 0] }

    private func resetPage(_ p: Page) {
        m.reset(page: p); text.reset(page: p)
        let d = InputConfig.defaults
        for i in 0..<8 {
            let def = d.players[i]
            switch p {
            case .players: input.config.players[i].keyboard = def.keyboard; input.config.players[i].mouse = def.mouse; input.config.players[i].controller = def.controller
            case .controls: input.config.players[i].binds = def.binds; input.config.players[i].modes = def.modes
            case .sticks:
                var q = input.config.players[i]
                q.sticks = def.sticks; q.triggerPress = def.triggerPress; q.stickPress = def.stickPress; q.keyStick = def.keyStick; q.walk = def.walk; q.turboHz = def.turboHz
                q.mouseMode = def.mouseMode; q.mouseSensX = def.mouseSensX; q.mouseSensY = def.mouseSensY; q.mouseSmooth = def.mouseSmooth; q.mouseInvX = def.mouseInvX; q.mouseInvY = def.mouseInvY
                input.config.players[i] = q
            case .motion:
                var q = input.config.players[i]
                q.motionSource = def.motionSource; q.gyroSens = def.gyroSens; q.invPitch = def.invPitch; q.invRoll = def.invRoll; q.invYaw = def.invYaw
                q.mouseGyroSens = def.mouseGyroSens; q.tiltAngle = def.tiltAngle; q.tiltSpeed = def.tiltSpeed; q.twistSpeed = def.twistSpeed; q.autoCenter = def.autoCenter
                input.config.players[i] = q
            case .rumble:
                var q = input.config.players[i]
                q.rumbleOn = def.rumbleOn; q.rumbleGain = def.rumbleGain; q.rumbleLow = def.rumbleLow; q.rumbleHigh = def.rumbleHigh; q.rumbleMin = def.rumbleMin; q.rumbleSwap = def.rumbleSwap
                input.config.players[i] = q
            default: break
            }
        }
        if p == .players { input.config.merge = d.merge }
        if p == .hotkeys { input.config.hotkeys = d.hotkeys }
    }

    @ViewBuilder private func pageContent(_ p: Page) -> some View {
        switch p {
        case .players:
            PlayersPage(input: input)
        case .controls:
            ControlsPage(input: input, player: $player)
        case .sticks:
            SticksPage(input: input, player: $player)
        case .motion:
            EnvSections(page: .motion, m: m, text: text)
            if m.values["DM_MOTION"] ?? "1" != "0" { MotionPlayerSection(input: input, player: $player) }
        case .rumble:
            EnvSections(page: .rumble, m: m, text: text)
            if m.values["DM_RUMBLE"] ?? "1" != "0" { RumblePlayerSection(input: input, player: $player, globalGain: Double(m.values["DM_RUMBLE_GAIN"] ?? "1") ?? 1) }
        case .hotkeys:
            HotkeysPage(input: input)
        case .saves:
            CloudSavesSection()
            DataSections(m: m, input: input, text: text)
        case .about:
            AboutSection(m: m)
        default:
            EnvSections(page: p, m: m, text: text)
            if m.rows(on: p).isEmpty && !TextSetting.all.contains(where: { $0.page == p }) {
                Section { Text("This game has no settings here.").foregroundStyle(.secondary) }
            }
        }
    }
}

/// Cloud saves: a folder the save is synced through (dm/host/save_sync.h), the one the iPhone app picks in its launcher's Cloud saves section. It is kept in this app's
/// preferences as cloudSaves.folder, which launcher.c puts into DM_SAVE_SYNC before the host starts; a DM_SAVE_SYNC an env file or the launch environment set wins, and is shown here.
struct CloudSavesSection: View {
    @AppStorage("cloudSaves.folder") private var folder = ""
    private let fixed: String? = {
        let env = ProcessInfo.processInfo.environment
        let keys = ((env["DM_ENV_FILE_KEYS"] ?? "") + " " + (env["DM_ENV_LAUNCH_KEYS"] ?? "")).split(separator: " ")
        return keys.contains("DM_SAVE_SYNC") || env["DM_SAVE_SYNC"] != nil ? env["DM_SAVE_SYNC"] : nil
    }()

    var body: some View {
        Section {
            HStack {
                LabeledContent("Cloud saves") {
                    Text(fixed.map { "\(Self.shown($0)) (env.txt)" } ?? (folder.isEmpty ? "Off" : Self.shown(folder)))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                ResetButton(enabled: fixed == nil && !folder.isEmpty) { folder = "" }
            }
            if fixed == nil {
                HStack {
                    Button(folder.isEmpty ? "Choose a folder…" : "Choose a different folder…", action: choose)
                    if !folder.isEmpty { Button("Turn off") { folder = "" } }
                }
            }
        } header: { Text("Cloud saves") } footer: {
            Text("Choose the iCloud Drive folder the iPhone app uses for this game. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in the save's -backups folder.")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = "Use for Cloud Saves"
        panel.message = "The folder the iPhone app chose in its launcher's Cloud saves"
        panel.directoryURL = URL(fileURLWithPath: folder.isEmpty ? Self.drive : folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    static let drive = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"   // iCloud Drive, as the Finder shows it

    /// A path under iCloud Drive as the Finder and the Files app name it: iCloud Drive › Documents › dev › Zelda; any other path as it is
    static func shown(_ path: String) -> String {
        guard path == drive || path.hasPrefix(drive + "/") else { return path }
        return (["iCloud Drive"] + path.dropFirst(drive.count).split(separator: "/").map(String.init)).joined(separator: " › ")
    }
}

// Folders, a save backup, settings to a file and back, and input profiles every game shares (~/Library/Application Support/nxnative/profiles)
struct DataSections: View {
    @ObservedObject var m: LauncherModel
    @ObservedObject var input: InputStore
    @ObservedObject var text: TextStore
    @State private var profiles: [String] = []
    @State private var profileName = ""
    @State private var message = ""
    var body: some View {
        Section("Folders") {
            HStack {
                Button("Open Save Folder") { open(AppPaths.save) }
                Button("Open Game Log") { NSWorkspace.shared.open(AppPaths.log) }.disabled(!FileManager.default.fileExists(atPath: AppPaths.log.path))
                Button("Show Logs Folder") { open(AppPaths.logs) }
            }
            HStack {
                Button("Edit env.txt") { editEnv() }
                Button("Show App Data") { open(AppPaths.support) }
            }
            Text("env.txt holds KEY=VALUE lines that win over this window; the window shows what it fixes greyed out. Changes count at the next start.").font(.caption).foregroundStyle(.secondary)
        }
        Section {
            HStack {
                Button("Back Up the Save Now") { backup() }
                Button("Show Backups") { open(AppPaths.support.appendingPathComponent("save-backups")) }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        } header: { Text("Save backup") } footer: { Text("Copies the save folder into save-backups, named with the date and time. To bring one back, quit the game and copy its contents over the save folder.") }
        Section {
            HStack {
                TextField("Profile name", text: $profileName, prompt: Text("My controls"))
                Button("Save Current Controls") { saveProfile() }.disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if profiles.isEmpty { Text("No input profile saved yet.").foregroundStyle(.secondary) }
            ForEach(profiles, id: \.self) { name in
                HStack {
                    Image(systemName: "person.crop.square")
                    Text(name)
                    Spacer()
                    Button("Load") { loadProfile(name) }
                    Button("Delete", role: .destructive) { try? FileManager.default.removeItem(at: profileURL(name)); refresh() }
                }
            }
        } header: { Text("Input profiles") } footer: {
            Text("A profile holds every player's controls, devices, sticks, mouse, motion, rumble and hotkeys, and every game made with nxnative refreshed sees it: map your controls once, load them in each game.")
        }
        .onAppear(perform: refresh)
        Section("All settings") {
            HStack {
                Button("Export Settings…") { exportAll() }
                Button("Import Settings…") { importAll() }
            }
            Text("A file with this game's choices, text settings and controls, for keeping or for another Mac.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func open(_ url: URL) { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); NSWorkspace.shared.open(url) }
    private func editEnv() {
        let url = AppPaths.envFile
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
            try? "# KEY=VALUE lines, one per line; # starts a comment. They win over the settings window (docs/settings.md, Settings in a file).\n# DM_SHOW_FPS=1\n".write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }
    private func backup() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let dest = AppPaths.support.appendingPathComponent("save-backups/\(f.string(from: Date())) manual")
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: AppPaths.save, to: dest)
            message = "Backed up to save-backups/\(dest.lastPathComponent)."
        } catch { message = "The backup failed: \(error.localizedDescription)" }
    }
    private func profileURL(_ name: String) -> URL { AppPaths.profiles.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-") + ".json") }
    private func refresh() {
        profiles = ((try? FileManager.default.contentsOfDirectory(atPath: AppPaths.profiles.path)) ?? []).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }
    private func saveProfile() {
        let name = profileName.trimmingCharacters(in: .whitespaces)
        try? FileManager.default.createDirectory(at: AppPaths.profiles, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(input.config) { try? d.write(to: profileURL(name)) }
        profileName = ""; refresh()
    }
    private func loadProfile(_ name: String) {
        if let d = try? Data(contentsOf: profileURL(name)), let c = InputConfig.decode(d) { input.config = c }
    }
    private func exportAll() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(info("CFBundleName") ?? "Game") settings.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var root: [String: Any] = ["nxnative-refreshed": 1, "game": AppPaths.titleID]
        root["choices"] = Dictionary(uniqueKeysWithValues: m.settings.compactMap { s -> (String, String)? in let v = m.values[s.env] ?? s.def; return s.isDefault(v) ? nil : (s.env, v) })
        root["text"] = text.values
        if let d = try? JSONEncoder().encode(input.config), let j = try? JSONSerialization.jsonObject(with: d) { root["input"] = j }
        if let d = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url) }
    }
    private func importAll() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let d = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        if let choices = root["choices"] as? [String: String] {
            for s in m.settings where !m.fixed.contains(s.env) { m.values[s.env] = choices[s.env].flatMap { s.accepts($0) ? $0 : nil } ?? s.def }
        }
        if let t = root["text"] as? [String: String] { for x in TextSetting.all { text.values[x.env] = t[x.env] ?? x.def } }
        if let j = root["input"], let jd = try? JSONSerialization.data(withJSONObject: j), let c = InputConfig.decode(jd) { input.config = c }
    }
}

struct AboutSection: View {
    @ObservedObject var m: LauncherModel
    var body: some View {
        Section("This game") {
            LabeledContent("Name", value: info("CFBundleName") ?? "Game")
            LabeledContent("Version", value: info("CFBundleShortVersionString") ?? "1.0")
            LabeledContent("Title ID", value: AppPaths.titleID)
            LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "")
            if let c = info("DMCommit") { LabeledContent("Packed from", value: c) }
            LabeledContent("Settings in this app", value: "\(m.settings.count) of the game's, plus controls for 8 players")
        }
        Section {
            Text("nxnative refreshed is a fork of nxnative for a better experience on the Mac: this settings window with a page per subject, a reset button on every option, the mapping of any key, mouse button or controller element to any Switch input for up to eight players, per-player rumble and motion with keyboard and mouse emulation, hotkeys, and window, audio and focus settings.")
            Link("nxnative (upstream)", destination: URL(string: "https://github.com/seedds/nxnative")!)
        } header: { Text("nxnative refreshed") } footer: { Text("Not affiliated with Nintendo or any game publisher. Play your own games.") }
    }
}

private final class Launcher: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: LauncherModel
    let input = InputStore()
    let text = TextStore()
    var window: NSWindow?
    var play = false

    init(_ model: LauncherModel) { self.model = model }

    func applicationDidFinishLaunching(_ n: Notification) {
        let name = info("CFBundleName") ?? "Game"
        let menu = NSMenu(), item = NSMenuItem(), app = NSMenu()
        app.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app; menu.addItem(item)
        let editItem = NSMenuItem(), edit = NSMenu(title: "Edit")   // copy and paste in the text fields
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = name; w.isReleasedWhenClosed = false; w.delegate = self
        w.contentMinSize = NSSize(width: 900, height: 560)
        w.setFrameAutosaveName("nxnative refreshed settings")
        window = w
        if w.frame.origin == .zero, let screen = w.screen ?? NSScreen.main { w.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.midX - w.frame.width / 2, y: screen.visibleFrame.maxY - 40)) }
        w.contentView = NSHostingView(rootView: LauncherView(m: model, input: input, text: text, done: { [weak self] in self?.finish($0) }))
        // no activation and no ordering in front of another app's windows: LaunchServices activates an app opened from Finder or the Dock (applicationDidBecomeActive), open -g does not
        if NSApp.isActive { w.makeKeyAndOrderFront(nil) } else { w.orderBack(nil) }
    }
    func applicationDidBecomeActive(_ n: Notification) { window?.makeKeyAndOrderFront(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {   // ⌘Q, or a logout or restart: the app ends without the game (exit 0, as Quit)
        fputs("launcher: quit without starting the game\n", stderr)
        return .terminateNow   // not terminateCancel, which a logout or restart takes as a refusal and stops
    }
    func windowWillClose(_ n: Notification) { finish(false) }

    func finish(_ play: Bool) {
        guard let w = window else { return }
        window = nil; self.play = play
        w.delegate = nil; w.orderOut(nil)
        NSApp.stop(nil)
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)   // run returns at the next event
    }
}

// The input mapping and the text settings into the environment, after the rows: with the window at Play, and at a start without it (launcher.c, after the saved choices)
private func applyExtras(_ config: InputConfig) {
    TextStore.apply()
    if ProcessInfo.processInfo.environment["DM_INPUT_CONFIG"] == nil, let url = InputStore.write(config, into: AppPaths.support) {
        setenv("DM_INPUT_CONFIG", url.path, 1); fputs("launcher: input mapping \(url.path)\n", stderr)
    }
}

// 1: Play (the window's settings are in the environment), 0: the player quit, 2: no window (no launcher.json, or "Show this window at launch" off): launcher.c applies the saved choices
@_cdecl("dm_mac_launcher")
public func dmMacLauncher() -> Int32 {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return 2 }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return 2 }
    if (UserDefaults.standard.object(forKey: "window.show") as? Bool) == false && !NSEvent.modifierFlags.contains(.option) {
        fputs("launcher: settings window off (hold Option at launch to show it)\n", stderr)
        return 2
    }
    let model = LauncherModel(file.settings)
    let app = NSApplication.shared, launcher = Launcher(model)
    app.setActivationPolicy(.regular)
    app.delegate = launcher
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    app.run()
    app.setActivationPolicy(.prohibited)   // the host is the game's app from here on
    guard launcher.play else { fputs("launcher: quit without starting the game\n", stderr); return 0 }
    model.apply()
    applyExtras(launcher.input.config)
    return 1
}

// No window (DM_LAUNCHER=0, --no-launcher, "Show this window at launch" off, or no launcher.json): the text settings and the input mapping as the window left them
@_cdecl("dm_mac_apply_extras")
public func dmMacApplyExtras() {
    applyExtras(InputStore().config)
}
