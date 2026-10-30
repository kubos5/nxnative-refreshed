// nxnative refreshed's Mac settings window (dm/mac/Launcher.swift and its pages), run by test_launcher_storage.py without showing a window: every page lays out, clicks down the sidebar open every page and the window gets no toolbar, each page's rows
// reset, the input mapping's defaults are the host's (the input.json the window writes for them is dm/host/tests/input_default.json, which t_input_json.m reads as im_default),
// stored mappings merge onto the defaults, the quick setups and presets keep two keyboard players apart, and the text settings reach the environment.
import AppKit
import SwiftUI

func checkLauncherLayout(_ model: LauncherModel, defaults: UserDefaults) -> Int {
    NSApplication.shared.setActivationPolicy(.prohibited)
    var failed = 0
    func expect(_ c: Bool, _ what: String) { print((c ? "PASS " : "FAIL ") + what); if !c { failed += 1 } }
    let input = InputStore(defaults: defaults), text = TextStore(defaults: defaults)

    // every page draws
    for p in Page.allCases {
        defaults.set(p.rawValue, forKey: "window.page")
        autoreleasepool {
            let view = NSHostingView(rootView: LauncherView(m: model, input: input, text: text, done: { _ in }).defaultAppStorage(defaults))
            view.frame = NSRect(x: 0, y: 0, width: 1060, height: 720)
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            expect(view.fittingSize.width > 0, "page \(p.title) lays out")
        }
    }

    // the sidebar in a window: no toolbar (a NavigationSplitView put one over the page in an AppKit window), and clicks down the sidebar open every page in its order
    // (an Optional tag on a List row matched nothing: a click selected no page). Mouse events through the window, as AppKit hands a click to the view
    defaults.set(Page.game.rawValue, forKey: "window.page")
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1060, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: LauncherView(m: model, input: input, text: text, done: { _ in }).defaultAppStorage(defaults))
    window.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    expect(window.toolbar == nil, "the window gets no toolbar")
    func click(x: CGFloat, top: CGFloat) {   // a point of the content, from its top left
        let cv = window.contentView!, loc = cv.convert(NSPoint(x: x, y: cv.isFlipped ? top : cv.bounds.height - top), to: nil)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    }
    var visited: [Page] = []
    for top in stride(from: 4.0, to: 680, by: 9) {
        click(x: 100, top: top)
        if let p = Page(rawValue: defaults.string(forKey: "window.page") ?? ""), visited.last != p { visited.append(p) }
    }
    expect(visited == Page.sidebar.flatMap(\.1), "clicks down the sidebar open every page in its order (\(visited.map(\.rawValue).joined(separator: " ")))")
    window.close()
    TestState.shared.stop()   // the Test page's polling, which a page view leaving without its window closing does not stop

    expect(Set(model.settings.map(\.page)).isSubset(of: Set(Page.allCases)) && model.settings.allSatisfy { $0.page != .about },
           "every row of the Mac list has a page")
    expect(model.settings.first { $0.env == "DM_RUMBLE" }?.page == .rumble && model.settings.first { $0.env == "DM_FULLSCREEN" }?.page == .display, "rows go to their pages")
    expect(model.settings.first { $0.env == "DM_MEM_CAP_GB" }.map { model.formatted($0, 0) } == "No limit" && model.settings.first { $0.env == "DM_MOTION_GAIN" }.map { model.formatted($0, 0.5) } == "0.50x",
           "ranges read in their units")

    // a row's reset, a page's reset
    if let fps = model.settings.first(where: { $0.env == "DM_WINDOW_SIZE" }) {
        model.values[fps.env] = "1920x1080"
        expect(model.isChanged(fps) && model.changed(on: .display), "a changed row marks its page")
        model.persist()
        expect(defaults.string(forKey: "launcher.DM_WINDOW_SIZE") == "1920x1080", "a change is kept at once")
        model.resetRow(fps)
        expect(!model.isChanged(fps), "the row's reset brings back its default")
        model.persist()
        expect(defaults.string(forKey: "launcher.DM_WINDOW_SIZE") == nil, "a default is not kept")
        model.values["DM_VOLUME"] = "0.50"; model.values["DM_CURSOR"] = "hide"
        model.reset(page: .audio)
        expect(model.values["DM_VOLUME"] == "1.0" && model.values["DM_CURSOR"] == "hide", "Reset Page resets that page only")
        model.reset(page: .display)
    } else { expect(false, "the Mac list has the window size row") }

    // the host's defaults
    expect(input.config == .defaults && !input.changed, "a new store starts at the defaults")
    if let path = ProcessInfo.processInfo.environment["NXR_INPUT_FIXTURE"], let want = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? NSDictionary {
        let got = InputConfig.defaults.hostJSON() as NSDictionary
        expect(got.isEqual(want), "the defaults' input.json is dm/host/tests/input_default.json (the host's im_default)")
    } else { expect(false, "NXR_INPUT_FIXTURE names input_default.json") }
    let p1 = InputConfig.defaults.players[0], p2 = InputConfig.defaults.players[1]
    expect(p1.keyboard && p1.mouse && !p2.keyboard && p1.slots("A")[BindColumn.key1.rawValue] == .key(38) && p2.slots("A")[BindColumn.pad1.rawValue] == .pad("east"),
           "player 1 has nxnative's keyboard map, every player the controller map")

    // storage: a stored mapping merges onto the defaults
    var c = InputConfig.defaults
    c.players[1].rumbleSwap = true; c.players[1].binds = ["A": [.key(3), nil, nil, nil, nil]]; c.merge = true
    input.config = c
    expect(defaults.data(forKey: InputStore.key) != nil && InputStore(defaults: defaults).config == c, "a changed mapping is kept and read back")
    var stored = try! JSONSerialization.jsonObject(with: defaults.data(forKey: InputStore.key)!) as! [String: Any]
    var players = stored["players"] as! [[String: Any]]
    players[0].removeValue(forKey: "tiltAngle"); players[0]["gyroSens"] = "fast"; stored["players"] = players; stored["unknown"] = 1
    let merged = InputConfig.decode(try! JSONSerialization.data(withJSONObject: stored))
    expect(merged?.players[0].tiltAngle == 35 && merged?.players[0].gyroSens == 1 && merged?.players[1].rumbleSwap == true && merged?.players[1].slots("B").allSatisfy { $0 == nil } == true,
           "a missing or mistyped field takes its default, an unknown one is ignored, a mapping is whole")
    input.reset()
    expect(defaults.data(forKey: InputStore.key) == nil, "the defaults are not kept")

    // quick setups and presets
    var s = InputConfig.defaults
    PlayerSetup.sharedKeyboard.apply(to: &s)
    let k1 = Set(s.players[0].binds.values.flatMap { $0 }.compactMap { $0 }.filter { $0.src == .key })
    let k2 = Set(s.players[1].binds.values.flatMap { $0 }.compactMap { $0 }.filter { $0.src == .key })
    expect(!k1.isEmpty && !k2.isEmpty && k1.isDisjoint(with: k2) && s.players[1].keyboard && s.players[0].controller == "none" && s.players[2].controller == "auto",
           "two players on one keyboard share no key; controllers from player 3")
    for t in SwitchInputs.all where !["Walk", "TiltUp", "TiltDown", "TiltLeft", "TiltRight", "TwistLeft", "TwistRight", "Recenter", "RSUp", "RSDown", "RSLeft", "RSRight"].contains(t.id) {
        if s.players[0].slots(t.id)[0] == nil || s.players[1].slots(t.id)[0] == nil { expect(false, "the shared-keyboard layouts bind \(t.id)") }
    }
    PlayerSetup.keyboardOwn.apply(to: &s)
    expect(s.players[0].controller == "none" && !s.players[1].keyboard && !s.merge, "keyboard on its own as player 1")
    var x = InputConfig.defaults.players[0]
    MappingPreset.xboxFace.apply(to: &x, index: 0)
    expect(x.slots("A")[BindColumn.pad1.rawValue] == .pad("south") && x.slots("A")[BindColumn.key1.rawValue] == .key(38), "the Xbox layout moves only the face buttons")
    MappingPreset.defaults.apply(to: &x, index: 3)
    expect(x.sameBinds(PlayerConfig.defaults(0)) && x.binds == PlayerConfig.defaults(0).binds, "the default preset gives another player the keyboard map too")
    x.set("A", .key1, nil); x.set("A", .key1, .key(38))
    var y = PlayerConfig.defaults(0); y.set("Walk", .key2, .key(56)); y.set("Walk", .key2, nil)
    expect(x.binds == PlayerConfig.defaults(0).binds && y == PlayerConfig.defaults(0), "a binding cleared and set again, or set and cleared, leaves the mapping as it was")

    // the Test page: what the keys give the game through the host's own mapping (launcher_bridge.m), the player's rumble settings, the patterns' ranges
    var keys = [UInt8](repeating: 0, count: 128); let mouse = [UInt8](repeating: 0, count: 12)
    func eval(_ player: Int32, _ config: InputConfig) -> dm_test_output {
        _ = dm_test_config(try! JSONSerialization.data(withJSONObject: config.hostJSON()))
        var o = dm_test_output(); keys.withUnsafeBufferPointer { k in mouse.withUnsafeBufferPointer { m in dm_test_eval(player, k.baseAddress, m.baseAddress, [], &o) } }
        return o
    }
    keys[38] = 1; keys[13] = 1   // J and W
    var o = eval(0, .defaults)
    expect(o.buttons & 1 == 1 && o.ly > 30000 && o.lx == 0, "J gives A and W the left stick up, as in the game")
    expect(eval(1, .defaults).buttons == 0, "a player who does not read the keyboard gets nothing from it")
    keys = [UInt8](repeating: 0, count: 128); keys[53] = 1   // Escape: the capture hotkey
    var esc = InputConfig.defaults; esc.players[0].set("B", .key2, .key(53))
    expect(eval(0, esc).buttons & 2 == 0, "a key taken by a hotkey does not reach the game")
    var toggle = InputConfig.defaults; toggle.players[0].modes["A"] = "toggle"
    keys = [UInt8](repeating: 0, count: 128); keys[38] = 1; _ = eval(0, toggle); keys[38] = 0; o = eval(0, toggle)
    expect(o.buttons & 1 == 1, "a toggle stays on after its key is let go")
    keys = [UInt8](repeating: 0, count: 128); keys[49] = 1
    expect(eval(0, .defaults).shake == 1, "Space shakes")
    var r = PlayerConfig.defaults(0); r.rumbleSwap = true; r.rumbleGain = 0.5
    let shaped = RumblePlayer.shaping(r, gain: 1, min: 0)(([0.8, 160, 0.4, 320], [0, 160, 0, 320]))
    expect(shaped.0 == [0, 160, 0, 320] && shaped.1 == [0.4, 160, 0.2, 320], "the Test page's rumble follows the player's swap and strength")
    r = PlayerConfig.defaults(0); r.rumbleOn = false
    expect(RumblePlayer.shaping(r, gain: 1, min: 0)(([1, 160, 1, 320], [1, 160, 1, 320])).0 == [0, 160, 0, 320], "and the player's rumble switch")
    expect(RumblePlayer.shaping(PlayerConfig.defaults(0), gain: 1, min: 0.5)(([0.4, 160, 0.75, 320], [0, 160, 0, 320])).0 == [0, 160, 0.5, 320], "and the cutoff")
    var inRange = true
    for p in RumblePattern.all { for t in stride(from: 0.0, to: p.length, by: 0.005) { let (a, b) = p.at(t); for v in [a, b] { inRange = inRange && v.count == 4 && (0...1).contains(v[0]) && (0...1).contains(v[2]) && (40...627).contains(v[1]) && (81...1253).contains(v[3]) } } }
    expect(inRange, "every rumble pattern stays within HD Rumble's amplitudes and each band's frequencies")

    // text settings
    text.values["DM_NICK"] = "Link"; text.values["DM_EXTRA_ENV"] = "DM_SHOW_FPS=1\n# a comment\nnot a line\nDM_METAL_HUD=0\n 1BAD=2"
    expect(defaults.string(forKey: "refreshed.DM_NICK") == "Link", "a text setting is kept")
    setenv("DM_ENV_FILE_KEYS", "DM_METAL_HUD", 1); setenv("DM_METAL_HUD", "1", 1)   // set by an env.txt
    TextStore.apply(defaults)
    setenv("DM_ENV_FILE_KEYS", "", 1)
    expect(String(cString: getenv("DM_NICK")) == "Link" && String(cString: getenv("DM_SHOW_FPS")) == "1", "text settings and extra lines reach the environment")
    expect(String(cString: getenv("DM_METAL_HUD")) == "1" && getenv("1BAD") == nil, "an env file's variable is kept, a bad line ignored")
    text.reset()
    expect(defaults.string(forKey: "refreshed.DM_NICK") == nil && !text.changed(), "Reset All forgets the text settings")
    unsetenv("DM_NICK"); unsetenv("DM_SHOW_FPS")
    return failed
}
