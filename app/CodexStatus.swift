// Codex Bar — a standalone macOS app for the Codex CLI.
//
// Full app: a Dock icon + a window that opens on launch, AND a solid menu-bar
// status icon (icon-only, fixed width, colored by state so it never jitters).
// It watches ~/.codex/sessions/**/rollout-*.jsonl itself (no SwiftBar, no
// Python), and posts a notification when a turn finishes.
//
// Build: app/build.sh   ·   Install: install-app.sh

import AppKit
import Foundation
import ServiceManagement

// MARK: - State

enum CxState: String {
    case idle, working
    case needsApproval = "needs-approval"
    case unknown
}

// MARK: - Log watcher (self-contained)

final class Watcher {
    let home: URL
    private(set) var path: URL?
    private var offset: UInt64 = 0
    private var buffer = ""

    var state: CxState = .idle
    var startedAt: Double?
    var durationMs: Double?
    var lastMessage = ""
    var model = ""
    var cwd = ""
    var effort = ""
    var approval = ""

    init(home: URL) { self.home = home }

    var sessions: URL { home.appendingPathComponent("sessions") }

    func newest() -> URL? {
        guard let en = FileManager.default.enumerator(at: sessions,
              includingPropertiesForKeys: [.contentModificationDateKey],
              options: [.skipsHiddenFiles]) else { return nil }
        var best: URL?
        var bestDate = Date.distantPast
        for case let url as URL in en where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            if let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d > bestDate {
                bestDate = d; best = url
            }
        }
        return best
    }

    private func absorbMeta(_ type: String?, _ p: [String: Any]) {
        if type == "session_meta" {
            if let v = p["cwd"] as? String { cwd = v }
        } else if type == "turn_context" {
            if let v = p["cwd"] as? String { cwd = v }
            if let v = p["model"] as? String { model = v }
            if let v = p["effort"] as? String { effort = v }
            if let v = p["approval_policy"] as? String { approval = v }
        }
    }

    @discardableResult
    private func handle(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return false }
        let type = obj["type"] as? String
        absorbMeta(type, payload)
        guard type == "event_msg" else { return false }
        switch payload["type"] as? String {
        case "task_started":
            startedAt = (payload["started_at"] as? NSNumber)?.doubleValue
            state = .working
        case "task_complete":
            lastMessage = (payload["last_agent_message"] as? String)
                ?? (payload["last-assistant-message"] as? String) ?? ""
            durationMs = (payload["duration_ms"] as? NSNumber)?.doubleValue
            state = .idle
            return true
        case "turn_aborted":
            durationMs = (payload["duration_ms"] as? NSNumber)?.doubleValue
            state = .idle
        default:
            break
        }
        return false
    }

    func seed(_ url: URL) {
        state = .idle; startedAt = nil; durationMs = nil; lastMessage = ""; buffer = ""
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                _ = handle(String(line))
            }
        }
        offset = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64) ?? 0
        path = url
    }

    private func readNewLines(_ url: URL) -> [String] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset { offset = 0; buffer = "" }
        if size <= offset { return [] }
        try? fh.seek(toOffset: offset)
        let data = (try? fh.readToEnd()) ?? Data()
        offset = size
        buffer += String(data: data, encoding: .utf8) ?? ""
        var lines = buffer.components(separatedBy: "\n")
        buffer = lines.removeLast()
        return lines
    }

    func poll() -> Bool {
        guard let n = newest() else { return false }
        if n != path { seed(n); return false }
        var completed = false
        for line in readNewLines(n) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if handle(line) { completed = true }
        }
        return completed
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let watcher: Watcher
    private var timer: Timer?
    private var frame = 0
    private var lastImageKey = ""

    private var window: NSWindow!
    private var statusField: NSTextField!
    private var soundCheck: NSButton!
    private var loginCheck: NSButton!

    private let icon = "sparkle"
    private let words = ["Thinking", "Cooking", "Prompting", "Brewing", "Reasoning",
                         "Crunching", "Pondering", "Plotting", "Noodling", "Simmering",
                         "Vibing", "Scheming"]

    override init() {
        watcher = Watcher(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
        super.init()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        UserDefaults.standard.register(defaults: ["completionSound": true])
        NSApp.setActivationPolicy(.regular)      // full app: Dock icon
        buildMainMenu()
        buildStatusItem()
        buildWindow()
        if let n = watcher.newest() { watcher.seed(n) }
        render()
        updateWindow()
        showWindow()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow(); return true
    }

    // MARK: build

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Show Codex Bar", action: #selector(showWindow), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Codex Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly     // icon only → fixed width, no jitter
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 340),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Codex Bar"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 340))

        statusField = NSTextField(wrappingLabelWithString: "")
        statusField.frame = NSRect(x: 20, y: 96, width: 340, height: 224)
        statusField.isSelectable = true
        content.addSubview(statusField)

        soundCheck = NSButton(checkboxWithTitle: "Play completion sound",
                              target: self, action: #selector(toggleSound))
        soundCheck.frame = NSRect(x: 20, y: 62, width: 340, height: 22)
        content.addSubview(soundCheck)

        loginCheck = NSButton(checkboxWithTitle: "Launch at login",
                              target: self, action: #selector(toggleLogin))
        loginCheck.frame = NSRect(x: 20, y: 36, width: 340, height: 22)
        content.addSubview(loginCheck)

        let footer = NSTextField(labelWithString: "Watches ~/.codex/sessions")
        footer.frame = NSRect(x: 20, y: 12, width: 340, height: 16)
        footer.textColor = .tertiaryLabelColor
        footer.font = .systemFont(ofSize: 10)
        content.addSubview(footer)

        window.contentView = content
        window.center()
    }

    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: tick / render

    private func tick() {
        frame += 1
        if watcher.poll() { notifyDone() }
        render()
        if window.isVisible { updateWindow() }
    }

    private func baseColor() -> NSColor {
        switch watcher.state {
        case .idle: return .systemGreen
        case .working: return .systemYellow
        case .needsApproval: return .systemRed
        case .unknown: return .systemGray
        }
    }

    // Menu-bar icon: SOLID and icon-only. Constant color per state, rebuilt only
    // when the state actually changes — no per-tick redraw, no pulsing, no width
    // change, so it never dims, flickers, or hides. (Animation lives in the
    // window, where width doesn't matter.)
    private func render() {
        guard let button = statusItem.button else { return }
        let key = watcher.state.rawValue
        if key != lastImageKey {
            lastImageKey = key
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [baseColor()]))
            let img = NSImage(systemSymbolName: icon, accessibilityDescription: "Codex")?
                .withSymbolConfiguration(cfg)
            img?.isTemplate = false
            button.image = img
        }
        button.imagePosition = .imageOnly
    }

    private func fmtDur(_ s: Int) -> String { s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s" }

    private func stateLabel() -> String {
        switch watcher.state {
        case .idle: return "idle"
        case .working: return "working"
        case .needsApproval: return "needs approval"
        case .unknown: return "unknown"
        }
    }

    // Composed status text (used in the window). Words animate here, where width
    // doesn't matter — the menu bar stays solid.
    private func statusText() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let c = baseColor()
        out.append(NSAttributedString(string: "Codex — \(stateLabel())\n",
            attributes: [.foregroundColor: c, .font: NSFont.boldSystemFont(ofSize: 16)]))
        if watcher.state == .working {
            let w = words[(frame / 3) % words.count]
            out.append(NSAttributedString(string: "\(w)…\n",
                attributes: [.foregroundColor: c, .font: NSFont.systemFont(ofSize: 13)]))
        }
        var lines: [String] = []
        if watcher.state == .working, let s = watcher.startedAt {
            lines.append("Running for \(fmtDur(Int(Date().timeIntervalSince1970 - s)))")
        } else if let d = watcher.durationMs {
            lines.append("Last turn: \(fmtDur(Int(d / 1000)))")
        }
        if !watcher.cwd.isEmpty { lines.append("Project: \((watcher.cwd as NSString).lastPathComponent)") }
        if !watcher.model.isEmpty {
            lines.append("Model: \(watcher.model)" + (watcher.effort.isEmpty ? "" : "  ·  \(watcher.effort)"))
        }
        if !watcher.approval.isEmpty { lines.append("Approvals: \(watcher.approval)") }
        if !lines.isEmpty {
            out.append(NSAttributedString(string: lines.joined(separator: "\n") + "\n",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]))
        }
        if !watcher.lastMessage.isEmpty {
            let m = String(watcher.lastMessage.prefix(280))
            out.append(NSAttributedString(string: "\n" + m,
                attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]))
        }
        return out
    }

    private func updateWindow() {
        statusField.attributedStringValue = statusText()
        soundCheck.state = UserDefaults.standard.bool(forKey: "completionSound") ? .on : .off
        if #available(macOS 13.0, *) {
            loginCheck.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            loginCheck.isHidden = false
        } else {
            loginCheck.isHidden = true
        }
    }

    private func notifyDone() {
        let raw = watcher.lastMessage.isEmpty ? "Turn complete" : watcher.lastMessage
        let body = String(raw.prefix(200))
        let soundOn = UserDefaults.standard.bool(forKey: "completionSound")
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        var script = "display notification \"\(esc(body))\" with title \"Codex — ready for you\""
        if soundOn { script += " sound name \"Glass\"" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    // MARK: status-item menu

    private func info(_ menu: NSMenu, _ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let head = NSMenuItem(title: "Codex — \(stateLabel())", action: nil, keyEquivalent: "")
        head.isEnabled = false
        head.attributedTitle = NSAttributedString(string: "Codex — \(stateLabel())",
            attributes: [.foregroundColor: baseColor(), .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        menu.addItem(head)
        if watcher.state == .working, let s = watcher.startedAt {
            info(menu, "Running for \(fmtDur(Int(Date().timeIntervalSince1970 - s)))")
        } else if let d = watcher.durationMs {
            info(menu, "Last turn: \(fmtDur(Int(d / 1000)))")
        }
        if !watcher.cwd.isEmpty { info(menu, "Project: \((watcher.cwd as NSString).lastPathComponent)") }
        if !watcher.model.isEmpty {
            info(menu, "Model: \(watcher.model)" + (watcher.effort.isEmpty ? "" : "  ·  \(watcher.effort)"))
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Codex Bar Window", action: #selector(showWindow), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        let snd = NSMenuItem(title: "Completion sound", action: #selector(toggleSound), keyEquivalent: "")
        snd.target = self
        snd.state = UserDefaults.standard.bool(forKey: "completionSound") ? .on : .off
        menu.addItem(snd)
        if #available(macOS 13.0, *) {
            let li = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
            li.target = self
            li.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            menu.addItem(li)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Codex Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleSound() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: "completionSound"), forKey: "completionSound")
        updateWindow()
    }

    @available(macOS 13.0, *)
    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do { if svc.status == .enabled { try svc.unregister() } else { try svc.register() } }
        catch { NSSound.beep() }
        updateWindow()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
