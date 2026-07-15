// CodexStatus — a standalone macOS menu-bar app for the Codex CLI.
//
// Watches ~/.codex/sessions/**/rollout-*.jsonl itself (no SwiftBar, no Python),
// shows a status-bar icon colored by state (green idle / amber working / red
// needs-approval), animates a cycling word + flower while a turn runs, offers a
// completion-sound toggle, and posts a notification when a turn finishes.
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

// MARK: - Log watcher (self-contained; mirrors the Python codex-watch logic)

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
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: keys,
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

    // Apply one event. Returns true if a turn just COMPLETED (for notifications).
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

    // Scan a whole file to seed state + info; set offset to EOF (skip history).
    func seed(_ url: URL) {
        state = .idle; startedAt = nil; durationMs = nil; lastMessage = ""
        buffer = ""
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                _ = handle(String(line))
            }
        }
        offset = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 ?? 0) ?? 0
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

    // Poll for changes. Returns true if a turn completed live (fire a notification).
    func poll() -> Bool {
        guard let n = newest() else { return false }
        if n != path {
            seed(n)          // switched sessions: reflect state, don't re-notify history
            return false
        }
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
    private var lastColor: NSColor?

    private let icon = "sparkle"
    private let words = ["Thinking", "Cooking", "Prompting", "Brewing", "Reasoning",
                         "Crunching", "Pondering", "Plotting", "Noodling", "Simmering",
                         "Vibing", "Scheming"]
    private let flowers = ["✿", "❀", "✾", "❁", "❋", "✾", "❀"]

    override init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        watcher = Watcher(home: home)
        super.init()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        UserDefaults.standard.register(defaults: ["completionSound": true])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if let n = watcher.newest() { watcher.seed(n) }
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        frame += 1
        if frame % 3 == 0 {          // poll the log ~every 0.9s
            if watcher.poll() { notifyDone() }
        }
        render()
    }

    private func color() -> NSColor {
        switch watcher.state {
        case .idle: return .systemGreen
        case .working: return .systemYellow
        case .needsApproval: return .systemRed
        case .unknown: return .systemGray
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let c = color()
        // Rebuild the icon in the state color (bold, NON-template so the color
        // actually shows — a template image would render menu-bar white).
        if lastColor != c {
            lastColor = c
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [c]))
            let img = NSImage(systemSymbolName: icon, accessibilityDescription: "Codex")?
                .withSymbolConfiguration(cfg)
            img?.isTemplate = false
            button.image = img
        }
        var title = ""
        switch watcher.state {
        case .working:
            let w = words[(frame / 8) % words.count]
            let f = flowers[frame % flowers.count]
            title = " \(w) \(f)"
        case .needsApproval:
            title = " Approval"
        default:
            title = ""
        }
        if title.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: c,
                             .font: NSFont.systemFont(ofSize: NSFont.systemFontSize - 1)])
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

    private func fmtDur(_ s: Int) -> String { s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s" }

    private func label() -> String {
        switch watcher.state {
        case .idle: return "idle"
        case .working: return "working"
        case .needsApproval: return "needs approval"
        case .unknown: return "unknown"
        }
    }

    private func info(_ menu: NSMenu, _ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let head = NSMenuItem(title: "Codex — \(label())", action: nil, keyEquivalent: "")
        head.isEnabled = false
        head.attributedTitle = NSAttributedString(
            string: "Codex — \(label())",
            attributes: [.foregroundColor: color(), .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
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
        if !watcher.approval.isEmpty { info(menu, "Approvals: \(watcher.approval)") }
        if !watcher.lastMessage.isEmpty {
            menu.addItem(.separator())
            let m = watcher.lastMessage
            info(menu, String(m.prefix(64)) + (m.count > 64 ? "…" : ""))
        }

        menu.addItem(.separator())
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
        let open = NSMenuItem(title: "Open Sessions Folder", action: #selector(openSessions), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "Quit Codex Status", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleSound() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: "completionSound"), forKey: "completionSound")
    }

    @available(macOS 13.0, *)
    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch { NSSound.beep() }
    }

    @objc private func openSessions() {
        NSWorkspace.shared.open(watcher.sessions)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
