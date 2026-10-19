import AppKit
import SwiftUI

@main @MainActor enum Main {
    static let delegate = AppDelegate()
    static func main() {
        if CommandLine.arguments.contains("--selftest") { selftest(); return }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

enum Tab: String, CaseIterable { case agents = "ai", music, clip, notes, msgs, health }

/// A few seconds of news: the island drops into a card. Hovering it opens `tab`.
struct Flash: Equatable {
    let id = UUID(), icon: String, color: Color, app: String, title: String, body: String, tab: Tab, secs: Double
    var pet = false   // health reminder: the kitten instead of an icon, tip in plain text
}

@Observable final class NotchState {
    var open = false
    var tab: Tab = .agents
    var notch = CGSize(width: 190, height: 32)
    var flash: Flash?
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static let canvas = CGSize(width: 860, height: 340)  // transparent window; the shape animates inside it
    static let openSize = CGSize(width: 760, height: 280)
    static let toast = CGSize(width: 440, height: 40)  // the strip under the notch

    let state = NotchState()
    let music = Music()
    let clip = Clip()
    let agents = Agents()
    let notifs = Notifs()
    let coach = Coach()
    var panel: NotchPanel!
    var flyWindow: NSWindow?
    var closeWork: DispatchWorkItem?
    var inToast = false  // pointer was already over the toast; only a fresh touch dismisses it

    func applicationDidFinishLaunching(_ n: Notification) {
        panel = NotchPanel(contentRect: .init(origin: .zero, size: Self.canvas),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true  // only text fields grab the keyboard (and pin it open)
        panel.contentView = NSHostingView(rootView: NotchView(s: state, music: music, clip: clip, agents: agents, notifs: notifs, coach: coach))

        coach.canInterrupt = { [weak self] in
            guard let self else { return false }
            return !state.open && state.flash == nil && flyWindow == nil  // never stomp on a message or an open panel
        }
        coach.onDue = { [weak self] r in self?.fly(r) }

        place()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        // ponytail: global mouseMoved needs no Accessibility permission; key shortcuts would.
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
            MainActor.assumeIsolated { self?.track() }
            return e
        }
        // clicking outside closes a pinned (keyboard-focused) notch
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { if self?.state.open == true { self?.setOpen(false) } }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53, self?.state.open == true else { return e }  // esc
            MainActor.assumeIsolated { self?.setOpen(false) }
            return nil
        }
        // banners are read live through Accessibility; ask once (permission sticks thanks to the stable signature)
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        agents.onDone = { [weak self] name in
            NSSound(named: "Glass")?.play()
            self?.ping(Flash(icon: "checkmark.seal.fill", color: .neon, app: "Claude Code", title: name,
                             body: "done · your turn", tab: .agents, secs: 5))
        }
        notifs.onNew = { [weak self] n in
            // who texted, never what: "Mani → arshyrzd" (Telegram multi-account) → "Mani"
            let who = n.title.components(separatedBy: " → ").first ?? n.title
            self?.ping(Flash(icon: n.icon, color: n.brand, app: n.appName, title: who.isEmpty ? n.appName : who,
                             body: n.appName, tab: .msgs, secs: 7))
        }

        let ev = NSAppleEventManager.shared().currentAppleEvent
        if ev?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.booleanValue != true { pin() }
    }

    /// Opened from Finder/Launchpad/Spotlight, or clicked again while running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        pin()
        return false
    }

    /// Open and take keyboard focus; stays open until click-outside or esc.
    func pin() {
        setOpen(true)
        panel.makeKey()
    }

    func place() {
        guard let scr = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let f = scr.frame
        if let l = scr.auxiliaryTopLeftArea, let r = scr.auxiliaryTopRightArea, scr.safeAreaInsets.top > 0 {
            state.notch = CGSize(width: f.width - l.width - r.width, height: scr.safeAreaInsets.top)
        } else {
            state.notch = CGSize(width: 190, height: max(24, f.maxY - scr.visibleFrame.maxY))
        }
        let c = Self.canvas
        panel.setFrame(NSRect(x: f.midX - c.width / 2, y: f.maxY - c.height, width: c.width, height: c.height), display: true)
    }

    /// The kitten swoops across the screen (click-through), lands on the notch, and says the reminder.
    func fly(_ r: Routine) {
        guard let scr = panel.screen ?? NSScreen.main else { return }
        let f = scr.frame, t = toastRect
        // land where the kitten sits in the centered toast strip
        let to = CGPoint(x: t.midX - 122 - f.minX, y: f.maxY - (t.midY + 4))
        let from = CGPoint(x: Bool.random() ? -90 : f.width + 90, y: f.height * 0.62)
        let dur = 2.8

        let w = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.contentView = NSHostingView(rootView: FlyView(from: from, to: to, start: Date(), dur: dur))
        w.setFrame(f, display: true)
        w.orderFrontRegardless()
        flyWindow = w

        DispatchQueue.main.asyncAfter(deadline: .now() + dur) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSSound(named: "Pop")?.play()
                self.ping(Flash(icon: r.icon, color: .coral, app: "Reminder", title: r.name, body: r.tip, tab: .health, secs: 9, pet: true))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    MainActor.assumeIsolated { self.flyWindow?.orderOut(nil); self.flyWindow = nil }
                }
            }
        }
    }

    var toastRect: NSRect {
        let f = panel.frame, t = Self.toast
        return NSRect(x: f.midX - t.width / 2, y: f.maxY - state.notch.height - t.height, width: t.width, height: t.height)
    }

    func track() {
        let p = NSEvent.mouseLocation, f = panel.frame
        if flyWindow != nil { return }  // the kitten is landing
        if state.flash != nil, !state.open {  // touch-and-go: pointer entering the toast clears it
            let inside = toastRect.contains(p)
            if inside && !inToast { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { state.flash = nil } }
            inToast = inside
        }
        let size = state.open ? Self.openSize : CGSize(width: state.notch.width + 40, height: state.notch.height)
        let slack: CGFloat = state.open ? 18 : 2
        let hot = NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
            .insetBy(dx: -slack, dy: -slack)
        if hot.contains(p) {
            closeWork?.cancel(); closeWork = nil
            if !state.open { setOpen(true) }
        } else if state.open, closeWork == nil, !panel.isKeyWindow {
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.setOpen(false) } }
            closeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: w)
        }
    }

    func setOpen(_ open: Bool) {
        closeWork = nil
        if open, let f = state.flash { state.tab = f.tab; state.flash = nil }  // hovering a toast takes you to it
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { state.open = open }
        panel.ignoresMouseEvents = !open
        if !open, panel.isKeyWindow {  // hand keyboard back to whatever app you were in
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    func ping(_ f: Flash) {
        inToast = toastRect.contains(NSEvent.mouseLocation)  // don't insta-dismiss if the pointer is already parked there
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { state.flash = f }
        DispatchQueue.main.asyncAfter(deadline: .now() + f.secs) { [weak self] in
            MainActor.assumeIsolated {
                guard self?.state.flash?.id == f.id else { return }  // a newer flash owns the wings now
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { self?.state.flash = nil }
            }
        }
    }
}

/// `TopNotch --selftest`: parser + 5h-window math, then a dry scan of your real logs.
func selftest() {
    let tool: [String: Any] = ["type": "assistant", "message": ["stop_reason": "tool_use",
        "content": [["type": "tool_use", "name": "Bash", "input": ["command": "ls"]]]]]
    precondition(Agents.status(tool)! == (.run, "Bash › ls"))
    let done: [String: Any] = ["type": "assistant", "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "ok"]]]]
    precondition(Agents.status(done)!.0 == .wait)
    let result: [String: Any] = ["type": "user", "message": ["content": [["type": "tool_result"]]]]
    precondition(Agents.status(result)!.0 == .think)
    precondition(Agents.status(["type": "attachment"]) == nil)

    let l = Music.lrc("[ti:x]\n[00:13.42] Yeah\n[00:14.81] \n[01:02.50] I've been tryna call")
    precondition(l.count == 3 && l[0].t == 13.42 && l[1].text.isEmpty && l[2].t == 62.5 && l[2].text == "I've been tryna call")
    let m = Music(); m.lyrics = l
    precondition(m.line(at: 5) == nil && m.line(at: 13.5)!.text == "Yeah" && m.line(at: 70)!.i == 2)

    let blob = try! PropertyListSerialization.data(fromPropertyList: ["date": 0.0, "req": ["titl": "Ali", "subt": "", "body": "yo"]],
                                                  format: .binary, options: 0)
    let n = Notifs.parse(id: 7, bundle: "ru.keepcoder.Telegram", data: blob)!
    precondition(n.tag == "TG" && n.title == "Ali" && n.body == "yo" && n.date == Date(timeIntervalSinceReferenceDate: 0))
    precondition(Notifs.parse(id: 1, bundle: "x", data: Data("junk".utf8)) == nil)

    for name in symbols { precondition(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "missing SF Symbol \(name)") }

    // reminders: most overdue enabled one wins; nothing due early; disabled ones are skipped
    let now = Date(), rs = Coach.defaults
    var last = Dictionary(uniqueKeysWithValues: rs.map { ($0.id, now) })
    precondition(Coach.next(rs, last: last, now: now) == nil)
    last["water"] = now.addingTimeInterval(-61 * 60); last["blink"] = now.addingTimeInterval(-50 * 60)
    precondition(Coach.next(rs, last: last, now: now)?.id == "blink")  // 30m overdue beats 1m overdue
    var off = rs; off[0].on = false
    precondition(Coach.next(off, last: last, now: now)?.id == "water")

    let h = Calendar.current.dateInterval(of: .hour, for: Date())!.start
    let b = Agents.blocks([(h.addingTimeInterval(-10 * 3600), 50), (h.addingTimeInterval(-9 * 3600), 50),
                           (h.addingTimeInterval(60), 10), (h.addingTimeInterval(120), 5)])
    precondition(b.peak == 100 && b.week == 115 && b.current!.1 == 15 && b.current!.0 == h.addingTimeInterval(5 * 3600))

    let recent = FileManager.default.enumerator(at: Agents.root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
    for u in recent where u.pathExtension == "jsonl" && !u.path.contains("/subagents/") {
        guard let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              Date().timeIntervalSince(m) < 900, let t = Agents.tail(u) else { continue }
        print(t.0.rawValue, t.2.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?", "|", t.1.prefix(60), "|", fmtTok(Agents.usage(u).reduce(0) { $0 + $1.2 }))
    }
    print("selftest ok")
}
