// Codex Bar: a native macOS menu-bar companion for Codex.
//
// It reads Codex's local thread index and rollout logs. The index provides the
// non-archived session list; rollout events provide live state and notifications.

import AppKit
import Foundation
import ImageIO
import ServiceManagement
import UserNotifications

// MARK: - State

enum CxState: String {
    case idle, working
    case needsAttention = "needs-attention"
    case unknown
}

enum SessionSignal {
    case completed
    case needsAttention
}

enum HistoryKind: String, Codable {
    case completed
    case attention
}

struct HistoryEntry: Codable {
    let id: UUID
    let sessionID: String
    let projectName: String
    let sessionName: String
    let kind: HistoryKind
    let date: Date
}

struct UsageSnapshot {
    let usedPercent: Int
    let resetsAt: Date

    var remainingPercent: Int { max(0, 100 - usedPercent) }
}

final class SessionTracker {
    let id: String
    let path: URL
    var cwd: String
    var threadTitle: String
    var updatedAt: Date

    private var offset: UInt64 = 0
    private var buffer = ""
    private var pendingInputCalls = Set<String>()

    var state: CxState = .idle
    var startedAt: Double?
    var durationMs: Double?
    var lastMessage = ""
    var model = ""
    var effort = ""
    var approval = ""

    init(id: String, cwd: String, title: String, path: URL, updatedAt: Date) {
        self.id = id
        self.cwd = cwd
        self.threadTitle = title
        self.path = path
        self.updatedAt = updatedAt
        seed()
    }

    var sessionName: String {
        let parts = URL(fileURLWithPath: cwd).pathComponents.filter { $0 != "/" }
        if let projects = parts.firstIndex(of: "projects"), projects + 1 < parts.count {
            if projects + 2 < parts.count { return parts.last! }
        }
        let title = threadTitle.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Untitled session" : title
    }

    var projectName: String {
        let parts = URL(fileURLWithPath: cwd).pathComponents.filter { $0 != "/" }
        if let projects = parts.firstIndex(of: "projects"), projects + 1 < parts.count {
            return parts[projects + 1]
        }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "Project" : name
    }

    var displayName: String { "\(projectName)  /  \(sessionName)" }

    private func absorbMeta(_ type: String?, _ payload: [String: Any]) {
        if type == "session_meta" {
            if let value = payload["cwd"] as? String { cwd = value }
        } else if type == "turn_context" {
            if let value = payload["cwd"] as? String { cwd = value }
            if let value = payload["model"] as? String { model = value }
            if let value = payload["effort"] as? String { effort = value }
            if let value = payload["approval_policy"] as? String { approval = value }
        }
    }

    private func handle(_ line: String) -> SessionSignal? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return nil }

        let envelopeType = object["type"] as? String
        absorbMeta(envelopeType, payload)

        // A request_user_input tool call means Codex is waiting for the user.
        // Matching output resumes the in-progress turn.
        if envelopeType == "response_item" {
            let itemType = payload["type"] as? String ?? ""
            let name = (payload["name"] as? String) ?? (payload["tool_name"] as? String) ?? ""
            let callID = payload["call_id"] as? String ?? ""
            if (itemType == "function_call" || itemType == "custom_tool_call"),
               name == "request_user_input" {
                if !callID.isEmpty { pendingInputCalls.insert(callID) }
                state = .needsAttention
                return .needsAttention
            }
            if itemType.hasSuffix("_call_output"), !callID.isEmpty,
               pendingInputCalls.remove(callID) != nil {
                state = .working
            }
            return nil
        }

        guard envelopeType == "event_msg" else { return nil }
        let event = payload["type"] as? String ?? ""
        let lowered = event.lowercased()

        switch event {
        case "task_started":
            pendingInputCalls.removeAll()
            startedAt = (payload["started_at"] as? NSNumber)?.doubleValue
                ?? Date().timeIntervalSince1970
            state = .working
        case "task_complete":
            pendingInputCalls.removeAll()
            lastMessage = (payload["last_agent_message"] as? String)
                ?? (payload["last-assistant-message"] as? String) ?? ""
            durationMs = (payload["duration_ms"] as? NSNumber)?.doubleValue
            state = .idle
            return .completed
        case "turn_aborted":
            pendingInputCalls.removeAll()
            durationMs = (payload["duration_ms"] as? NSNumber)?.doubleValue
            state = .idle
        default:
            // Codex versions have used more than one approval-event spelling.
            // Treat request/pending/required events as attention, and resolution
            // events as a return to working.
            if lowered.contains("approval") {
                if lowered.contains("approved") || lowered.contains("denied")
                    || lowered.contains("resolved") || lowered.contains("response") {
                    state = .working
                } else {
                    state = .needsAttention
                    return .needsAttention
                }
            }
        }
        return nil
    }

    private func seed() {
        state = .idle
        startedAt = nil
        durationMs = nil
        lastMessage = ""
        buffer = ""
        pendingInputCalls.removeAll()
        if let text = try? String(contentsOf: path, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                _ = handle(String(line))
            }
        }
        offset = ((try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? UInt64) ?? 0
    }

    private func readNewLines() -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; buffer = "" }
        if size <= offset { return [] }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset = size
        buffer += String(data: data, encoding: .utf8) ?? ""
        var lines = buffer.components(separatedBy: "\n")
        buffer = lines.removeLast()
        return lines
    }

    func poll() -> [SessionSignal] {
        var signals: [SessionSignal] = []
        for line in readNewLines() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if let signal = handle(line) { signals.append(signal) }
        }
        return signals
    }
}

final class SessionStore {
    private let codexHome: URL
    private var trackers: [String: SessionTracker] = [:]
    private var lastRefresh = Date.distantPast

    init(codexHome: URL) { self.codexHome = codexHome }

    var sessions: [SessionTracker] {
        trackers.values.sorted {
            if $0.state != $1.state {
                let priority: [CxState: Int] = [.needsAttention: 0, .working: 1, .idle: 2, .unknown: 3]
                return priority[$0.state, default: 4] < priority[$1.state, default: 4]
            }
            if $0.state == .working, $0.startedAt != $1.startedAt {
                return ($0.startedAt ?? 0) > ($1.startedAt ?? 0)
            }
            if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
            return $0.updatedAt > $1.updatedAt
        }
    }

    var state: CxState {
        if sessions.contains(where: { $0.state == .needsAttention }) { return .needsAttention }
        if sessions.contains(where: { $0.state == .working }) { return .working }
        return sessions.isEmpty ? .unknown : .idle
    }

    var featured: SessionTracker? { sessions.first }

    func recentProjects(limit: Int = 10) -> [(name: String, path: String)] {
        guard let database = databaseURL() else { return [] }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-tabs", database.path,
            "SELECT replace(cwd, char(9), ' '), max(updated_at) FROM threads WHERE archived = 0 AND cwd != '' GROUP BY cwd ORDER BY max(updated_at) DESC LIMIT \(max(limit * 3, limit));"]
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        let data = try? output.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let data,
              let text = String(data: data, encoding: .utf8) else { return [] }

        var seen = Set<String>()
        var result: [(String, String)] = []
        for row in text.split(separator: "\n") {
            let path = String(row.split(separator: "\t", omittingEmptySubsequences: false).first ?? "")
            guard !path.isEmpty else { continue }
            let parts = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
            let name: String
            if let projects = parts.firstIndex(of: "projects"), projects + 1 < parts.count {
                name = parts[projects + 1]
            } else {
                name = URL(fileURLWithPath: path).lastPathComponent
            }
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            result.append((name, path))
            if result.count == limit { break }
        }
        return result
    }

    func start() { refreshThreads(force: true) }

    func poll() -> [(SessionTracker, SessionSignal)] {
        refreshThreads(force: false)
        var emitted: [(SessionTracker, SessionSignal)] = []
        for tracker in sessions {
            for signal in tracker.poll() { emitted.append((tracker, signal)) }
        }
        return emitted
    }

    private func databaseURL() -> URL? {
        let candidates = [
            codexHome.appendingPathComponent("state_5.sqlite"),
            codexHome.appendingPathComponent("sqlite/state_5.sqlite")
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        return candidates.max {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
    }

    private func threadRows() -> [(id: String, cwd: String, title: String, path: URL, updated: Date)] {
        guard let database = databaseURL() else { return [] }
        let openPaths = openRolloutPaths()
        guard !openPaths.isEmpty else { return [] }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-tabs", database.path,
            "SELECT id, replace(cwd, char(9), ' '), replace(replace(title, char(9), ' '), char(10), ' '), replace(rollout_path, char(9), ' '), updated_at FROM threads WHERE archived = 0 ORDER BY updated_at DESC;"]
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        let data = try? output.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { raw in
            let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5, openPaths.contains(parts[3]) else { return nil }
            return (parts[0], parts[1], parts[2], URL(fileURLWithPath: parts[3]),
                    Date(timeIntervalSince1970: Double(parts[4]) ?? 0))
        }
    }

    private func openRolloutPaths() -> Set<String> {
        let lsof = "/usr/sbin/lsof"
        guard FileManager.default.isExecutableFile(atPath: lsof) else { return [] }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: lsof)
        process.arguments = ["-Fn", "-c", "codex"]
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        let data = try? output.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard let data, let text = String(data: data, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { raw -> String? in
            let line = String(raw)
            guard line.hasPrefix("n"), line.contains("/.codex/sessions/"),
                  line.contains("/rollout-"), line.hasSuffix(".jsonl") else { return nil }
            return String(line.dropFirst())
        })
    }

    private func refreshThreads(force: Bool) {
        guard force || Date().timeIntervalSince(lastRefresh) >= 2 else { return }
        lastRefresh = Date()
        let rows = threadRows()
        let ids = Set(rows.map(\.id))
        trackers = trackers.filter { ids.contains($0.key) }
        for row in rows where FileManager.default.fileExists(atPath: row.path.path) {
            if let existing = trackers[row.id] {
                existing.cwd = row.cwd
                existing.threadTitle = row.title
                existing.updatedAt = row.updated
            } else {
                trackers[row.id] = SessionTracker(id: row.id, cwd: row.cwd, title: row.title,
                                                  path: row.path, updatedAt: row.updated)
            }
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class SessionRowView: NSView {
    var sessionID = ""
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
                         UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let codexHome: URL
    private let store: SessionStore
    private var timer: Timer?
    private var iconAnimationTimer: Timer?
    private var animationFrame = 0
    private var iconAnimationFrame = 0
    private var iconAnimationStartedAt = Date()
    private var lastImageKey = ""
    private var idleStatusImage: NSImage?
    private var skyBlueIdleStatusImage: NSImage?
    private var appLogoImage: NSImage?
    private var attentionStatusImage: NSImage?
    private var workingStatusFrames: [NSImage] = []
    private var skyBlueWorkingStatusFrames: [NSImage] = []
    private var workingSessionIconViews: [NSImageView] = []

    private var window: NSWindow!
    private var summaryField: NSTextField!
    private var sessionStack: NSStackView!
    private var sessionsCardHeightConstraint: NSLayoutConstraint!
    private var sessionDocumentHeightConstraint: NSLayoutConstraint!
    private var historyStack: NSStackView!
    private var timerCheck: NSButton!
    private var completionSoundCheck: NSButton!
    private var attentionSoundCheck: NSButton!
    private var completionSoundPopup: NSPopUpButton!
    private var attentionSoundPopup: NSPopUpButton!
    private var quietHoursCheck: NSButton!
    private var quietStartPopup: NSPopUpButton!
    private var quietEndPopup: NSPopUpButton!
    private var updateCheck: NSButton!
    private var dockCheck: NSButton!
    private var appearancePopup: NSPopUpButton!
    private var loginCheck: NSButton!
    private var lastRowsKey = ""
    private var history: [HistoryEntry] = []
    private var latestVersion: String?
    private var updateURL: URL?
    private var updateCheckInFlight = false
    private var weeklyUsage: UsageSnapshot?
    private var usageRefreshInFlight = false
    private var lastUsageRefresh = Date.distantPast
    private weak var liveMenuHeaderTitle: NSTextField?
    private weak var liveMenuHeaderSubtitle: NSTextField?
    private var liveMenuSessions: [String: NSMenuItem] = [:]
    private let icon = "sparkle"
    private let soundNames = ["Glass", "Hero", "Pop", "Ping", "Purr", "Tink"]
    private let activityWords = ["Thinking", "Cooking", "Prompting", "Brewing", "Reasoning",
                                 "Crunching", "Pondering", "Plotting", "Noodling", "Simmering"]

    override init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        codexHome = home
        store = SessionStore(codexHome: home)
        super.init()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        UserDefaults.standard.register(defaults: [
            "showTimer": true,
            "completionSound": true,
            "attentionSound": true,
            "completionSoundName": "Glass",
            "attentionSoundName": "Ping",
            "quietHoursEnabled": false,
            "quietStartHour": 22,
            "quietEndHour": 8,
            "checkForUpdates": true,
            "showInDock": true,
            "statusAppearance": "system"
        ])
        loadHistory()
        configureNotifications()
        applyDockVisibility(UserDefaults.standard.bool(forKey: "showInDock"))
        buildMainMenu()
        buildStatusItem()
        buildWindow()
        store.start()
        refreshWeeklyUsage()
        render()
        updateWindow(force: true)
        showWindow()
        let refreshTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        timer = refreshTimer
        RunLoop.main.add(refreshTimer, forMode: .common)
        let gifTimer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.advanceWorkingIcon()
        }
        gifTimer.tolerance = 0.003
        iconAnimationTimer = gifTimer
        RunLoop.main.add(gifTimer, forMode: .common)
        if UserDefaults.standard.bool(forKey: "checkForUpdates") {
            checkForUpdates(silent: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }

    // MARK: - Build UI

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
        // A previous presentation mode may leave AppKit's persisted status-item
        // visibility disabled. Codex Bar is menu-bar-only again, so always restore it.
        statusItem.isVisible = true
        statusItem.button?.setAccessibilityLabel("Codex Bar Status")
        loadStatusAssets()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func prepareStatusImage(_ image: NSImage?) -> NSImage? {
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        return image
    }

    private func prepareFullColorStatusImage(_ image: NSImage?) -> NSImage? {
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = false
        return image
    }

    private func symbolImage(_ name: String, pointSize: CGFloat = 14,
                             color: NSColor? = nil) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize,
                                                                  weight: .medium)) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return color.map { tintedStatusImage(image, color: $0) } ?? image
    }

    private func tintedStatusImage(_ image: NSImage, color: NSColor) -> NSImage {
        let result = NSImage(size: image.size)
        let bounds = NSRect(origin: .zero, size: image.size)
        result.lockFocus()
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        color.setFill()
        bounds.fill(using: .sourceAtop)
        result.unlockFocus()
        result.isTemplate = false
        return result
    }

    private func makeAttentionStatusImage() -> NSImage {
        let result = NSImage(size: NSSize(width: 18, height: 18))
        result.lockFocus()
        skyBlueColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 5, y: 5, width: 8, height: 8)).fill()
        result.unlockFocus()
        result.isTemplate = false
        return result
    }

    private func loadStatusAssets() {
        attentionStatusImage = makeAttentionStatusImage()
        if let url = Bundle.main.url(forResource: "app-logo", withExtension: "png",
                                     subdirectory: "StatusAssets") {
            appLogoImage = NSImage(contentsOf: url)
            appLogoImage?.isTemplate = false
        }
        if let url = Bundle.main.url(forResource: "codex-logo", withExtension: "svg",
                                     subdirectory: "StatusAssets") {
            idleStatusImage = prepareStatusImage(NSImage(contentsOf: url))
        }
        if let url = Bundle.main.url(forResource: "colored-idle", withExtension: "png",
                                     subdirectory: "StatusAssets") {
            skyBlueIdleStatusImage = prepareFullColorStatusImage(NSImage(contentsOf: url))
        }
        if let url = Bundle.main.url(forResource: "codex-animation", withExtension: "gif",
                                     subdirectory: "StatusAssets"),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 36,
                kCGImageSourceShouldCacheImmediately: true
            ]
            workingStatusFrames = (0..<CGImageSourceGetCount(source)).compactMap { index in
                guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                    return nil
                }
                let image = NSImage(cgImage: frame, size: NSSize(width: 18, height: 18))
                image.isTemplate = true
                return image
            }
            skyBlueWorkingStatusFrames = workingStatusFrames.map {
                tintedStatusImage($0, color: skyBlueColor)
            }
        }
    }

    private func heading(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        return label
    }

    private func sectionHeading(_ title: String, symbol: String) -> NSView {
        let icon = NSImageView(image: symbolImage(symbol, pointSize: 13) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18)
        ])
        let label = heading(title, size: 13, weight: .semibold)
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        return stack
    }

    private func preferenceLabel(_ title: String, symbol: String) -> NSView {
        let icon = NSImageView(image: symbolImage(symbol, pointSize: 12) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18)
        ])
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func iconButton(_ symbol: String, help: String, action: Selector) -> NSButton {
        let button = NSButton(image: symbolImage(symbol, pointSize: 12) ?? NSImage(),
                              target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.toolTip = help
        button.setAccessibilityLabel(help)
        return button
    }

    private func borderedContainer() -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.cornerRadius = 14
        box.borderColor = .separatorColor
        box.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45)
        box.titlePosition = .noTitle
        return box
    }

    private func sectionCard(_ title: String, symbol: String, body bodyView: NSView,
                             insets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)) -> NSBox {
        let box = borderedContainer()
        box.contentViewMargins = .zero

        let card = NSView()
        let header = NSVisualEffectView()
        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .active
        header.translatesAutoresizingMaskIntoConstraints = false

        let headingView = sectionHeading(title, symbol: symbol)
        headingView.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headingView)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        bodyView.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(bodyView)

        card.addSubview(header)
        card.addSubview(divider)
        card.addSubview(body)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            header.topAnchor.constraint(equalTo: card.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),
            headingView.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            headingView.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            divider.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),

            body.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            body.topAnchor.constraint(equalTo: divider.bottomAnchor),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            bodyView.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: insets.left),
            bodyView.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -insets.right),
            bodyView.topAnchor.constraint(equalTo: body.topAnchor, constant: insets.top),
            bodyView.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -insets.bottom)
        ])
        box.contentView = card
        return box
    }

    private func hourTitle(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        let date = Calendar.current.date(from: DateComponents(hour: hour)) ?? Date()
        return formatter.string(from: date)
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 790),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Codex Bar"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 600, height: 700)
        window.isReleasedWhenClosed = false
        window.hasShadow = false

        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 680, height: 790))
        content.material = .windowBackground
        content.blendingMode = .behindWindow
        content.state = .active

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 50),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])

        let brandIcon = NSImageView(image: appLogoImage ?? NSApp.applicationIconImage)
        brandIcon.imageScaling = .scaleProportionallyUpOrDown
        brandIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            brandIcon.widthAnchor.constraint(equalToConstant: 42),
            brandIcon.heightAnchor.constraint(equalToConstant: 42)
        ])

        let title = heading("Codex Bar", size: 22, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Your Codex tasks, always within reach")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        let openCodex = NSButton(title: "Open Codex", target: self, action: #selector(openCodexApp))
        openCodex.image = symbolImage("arrow.up.forward.app")
        openCodex.imagePosition = .imageLeading
        openCodex.bezelStyle = .rounded
        openCodex.keyEquivalent = ""

        let header = NSStackView(views: [brandIcon, titleStack, NSView(), openCodex])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        root.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        summaryField = NSTextField(wrappingLabelWithString: "")
        summaryField.textColor = .secondaryLabelColor
        summaryField.font = .systemFont(ofSize: 12, weight: .medium)
        summaryField.maximumNumberOfLines = 2
        root.addArrangedSubview(summaryField)
        summaryField.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        sessionStack = NSStackView()
        sessionStack.orientation = .vertical
        sessionStack.alignment = .leading
        sessionStack.spacing = 0
        sessionStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        sessionStack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 620, height: 260))
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(sessionStack)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            sessionStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            sessionStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            sessionStack.topAnchor.constraint(equalTo: document.topAnchor),
            sessionStack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        sessionDocumentHeightConstraint = document.heightAnchor.constraint(equalToConstant: 130)
        sessionDocumentHeightConstraint.isActive = true
        let sessionsCard = sectionCard("Open Sessions", symbol: "rectangle.stack", body: scroll)
        root.addArrangedSubview(sessionsCard)
        sessionsCard.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        sessionsCardHeightConstraint = sessionsCard.heightAnchor.constraint(equalToConstant: 175)
        sessionsCardHeightConstraint.isActive = true

        historyStack = NSStackView()
        historyStack.orientation = .vertical
        historyStack.alignment = .leading
        historyStack.spacing = 2
        let historyCard = sectionCard("Recent Activity", symbol: "clock.arrow.circlepath",
                                      body: historyStack,
                                      insets: NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14))
        root.addArrangedSubview(historyCard)
        historyCard.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        historyCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true

        timerCheck = NSButton(checkboxWithTitle: "Enabled", target: self, action: #selector(toggleTimer))
        dockCheck = NSButton(checkboxWithTitle: "Enabled", target: self, action: #selector(toggleDockVisibility))
        loginCheck = NSButton(checkboxWithTitle: "Enabled", target: self, action: #selector(toggleLogin))
        updateCheck = NSButton(checkboxWithTitle: "Enabled", target: self, action: #selector(toggleUpdateChecks))
        completionSoundCheck = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCompletionSound))
        attentionSoundCheck = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleAttentionSound))
        quietHoursCheck = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleQuietHours))

        appearancePopup = NSPopUpButton()
        appearancePopup.addItems(withTitles: ["System", "Sky Blue"])
        appearancePopup.target = self
        appearancePopup.action = #selector(changeAppearance)

        completionSoundPopup = NSPopUpButton()
        completionSoundPopup.addItems(withTitles: soundNames)
        completionSoundPopup.target = self
        completionSoundPopup.action = #selector(changeSoundSelection(_:))
        attentionSoundPopup = NSPopUpButton()
        attentionSoundPopup.addItems(withTitles: soundNames)
        attentionSoundPopup.target = self
        attentionSoundPopup.action = #selector(changeSoundSelection(_:))

        let completionControls = NSStackView(views: [completionSoundCheck, completionSoundPopup,
            iconButton("play.fill", help: "Preview completion sound", action: #selector(previewCompletionSound))])
        completionControls.orientation = .horizontal
        completionControls.alignment = .centerY
        completionControls.spacing = 6

        let attentionControls = NSStackView(views: [attentionSoundCheck, attentionSoundPopup,
            iconButton("play.fill", help: "Preview question sound", action: #selector(previewAttentionSound))])
        attentionControls.orientation = .horizontal
        attentionControls.alignment = .centerY
        attentionControls.spacing = 6

        quietStartPopup = NSPopUpButton()
        quietStartPopup.addItems(withTitles: (0..<24).map(hourTitle))
        quietStartPopup.target = self
        quietStartPopup.action = #selector(changeQuietSchedule)
        quietEndPopup = NSPopUpButton()
        quietEndPopup.addItems(withTitles: (0..<24).map(hourTitle))
        quietEndPopup.target = self
        quietEndPopup.action = #selector(changeQuietSchedule)
        let toLabel = NSTextField(labelWithString: "to")
        toLabel.textColor = .secondaryLabelColor
        let quietControls = NSStackView(views: [quietHoursCheck, quietStartPopup, toLabel, quietEndPopup])
        quietControls.orientation = .horizontal
        quietControls.alignment = .centerY
        quietControls.spacing = 6

        let settings = NSGridView()
        settings.rowSpacing = 8
        settings.columnSpacing = 20
        settings.xPlacement = .fill
        settings.addRow(with: [preferenceLabel("Menu-bar timer", symbol: "timer"), timerCheck])
        settings.addRow(with: [preferenceLabel("Completion sound", symbol: "speaker.wave.2"), completionControls])
        settings.addRow(with: [preferenceLabel("Question sound", symbol: "bell.badge"), attentionControls])
        settings.addRow(with: [preferenceLabel("Quiet hours", symbol: "moon"), quietControls])
        settings.addRow(with: [preferenceLabel("Icon color", symbol: "paintpalette"), appearancePopup])
        settings.addRow(with: [preferenceLabel("Show in Dock", symbol: "dock.rectangle"), dockCheck])
        settings.addRow(with: [preferenceLabel("Launch at login", symbol: "power"), loginCheck])
        settings.addRow(with: [preferenceLabel("Automatic update checks", symbol: "arrow.triangle.2.circlepath"), updateCheck])

        let settingsCard = sectionCard("Preferences", symbol: "slider.horizontal.3", body: settings,
                                       insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        root.addArrangedSubview(settingsCard)
        settingsCard.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        window.contentView = content
        window.center()
    }

    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openCodexApp() {
        if let url = URL(string: "codex://") { NSWorkspace.shared.open(url) }
    }

    @objc private func newCodexChat() {
        if let url = URL(string: "codex://threads/new") { NSWorkspace.shared.open(url) }
    }

    @objc private func newChatInProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              var components = URLComponents(string: "codex://threads/new") else { return }
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private func preferenceSet(_ key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private func setPreferenceSet(_ values: Set<String>, forKey key: String) {
        UserDefaults.standard.set(Array(values).sorted(), forKey: key)
    }

    private var visibleSessions: [SessionTracker] {
        let hidden = preferenceSet("hiddenSessionIDs")
        let pinned = preferenceSet("pinnedSessionIDs")
        let base = store.sessions.filter { !hidden.contains($0.id) }
        let positions = Dictionary(uniqueKeysWithValues: base.enumerated().map { ($0.element.id, $0.offset) })
        return base.sorted { left, right in
            let leftPinned = pinned.contains(left.id)
            let rightPinned = pinned.contains(right.id)
            if leftPinned != rightPinned { return leftPinned }
            return positions[left.id, default: 0] < positions[right.id, default: 0]
        }
    }

    private func openCodexThread(_ id: String) {
        guard let url = URL(string: "codex://threads/\(id)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSession(_ sender: Any?) {
        let id: String?
        if let item = sender as? NSMenuItem { id = item.representedObject as? String }
        else if let gesture = sender as? NSClickGestureRecognizer,
                let row = gesture.view as? SessionRowView { id = row.sessionID }
        else { id = nil }
        guard let id else { return }
        openCodexThread(id)
    }

    private func mutateSessionPreference(_ key: String, id: String) {
        var values = preferenceSet(key)
        if values.contains(id) { values.remove(id) } else { values.insert(id) }
        setPreferenceSet(values, forKey: key)
        lastRowsKey = ""
        updateWindow(force: true)
    }

    @objc private func togglePinnedSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var pinned = preferenceSet("pinnedSessionIDs")
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        setPreferenceSet(pinned, forKey: "pinnedSessionIDs")
        lastRowsKey = ""
        updateWindow(force: true)
    }

    @objc private func toggleMutedSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        mutateSessionPreference("mutedSessionIDs", id: id)
    }

    @objc private func hideSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var hidden = preferenceSet("hiddenSessionIDs")
        hidden.insert(id)
        setPreferenceSet(hidden, forKey: "hiddenSessionIDs")
        lastRowsKey = ""
        updateWindow(force: true)
    }

    @objc private func unhideSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var hidden = preferenceSet("hiddenSessionIDs")
        hidden.remove(id)
        setPreferenceSet(hidden, forKey: "hiddenSessionIDs")
        lastRowsKey = ""
        updateWindow(force: true)
    }

    // MARK: - State and rendering

    private func tick() {
        animationFrame += 1
        refreshWeeklyUsage()
        for (session, signal) in store.poll() {
            switch signal {
            case .completed: notifyCompletion(session)
            case .needsAttention: notifyAttention(session)
            }
        }
        render()
        updateLiveMenu()
        if window.isVisible { updateWindow(force: false) }
    }

    private func advanceWorkingIcon() {
        guard store.state == .working, !workingStatusFrames.isEmpty else {
            iconAnimationFrame = 0
            iconAnimationStartedAt = Date()
            return
        }
        // Follow the GIF's authored 0.03s frame timeline exactly.
        let elapsed = Date().timeIntervalSince(iconAnimationStartedAt)
        iconAnimationFrame = Int(elapsed / 0.03) % workingStatusFrames.count
        let frames = skyBlueAppearance && skyBlueWorkingStatusFrames.count == workingStatusFrames.count
            ? skyBlueWorkingStatusFrames : workingStatusFrames
        if let button = statusItem.button {
            button.image = frames[iconAnimationFrame]
            button.contentTintColor = nil
        }
        let rowFrames = skyBlueWorkingStatusFrames.count == workingStatusFrames.count
            ? skyBlueWorkingStatusFrames : workingStatusFrames
        for iconView in workingSessionIconViews {
            iconView.image = rowFrames[iconAnimationFrame]
        }
    }

    private func stateLabel(_ state: CxState) -> String {
        switch state {
        case .idle: return "Ready"
        case .working: return "Working"
        case .needsAttention: return "Needs attention"
        case .unknown: return "No sessions"
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func activityText() -> String {
        let word = activityWords[(animationFrame / 60) % activityWords.count]
        let dots = String(repeating: ".", count: ((animationFrame / 10) % 3) + 1)
        return word + dots
    }

    private var statusFont: NSFont { .systemFont(ofSize: 13, weight: .medium) }
    private var statusTimerFont: NSFont { .monospacedDigitSystemFont(ofSize: 13, weight: .medium) }

    private func workingTitle(timer: String?, activity: String, color: NSColor,
                              paddedTo targetWidth: CGFloat? = nil) -> NSAttributedString {
        let value = NSMutableAttributedString(string: " ",
            attributes: [.foregroundColor: color, .font: statusFont])
        if let timer {
            value.append(NSAttributedString(string: timer,
                attributes: [.foregroundColor: color, .font: statusTimerFont]))
            value.append(NSAttributedString(string: " ",
                attributes: [.foregroundColor: color, .font: statusFont]))
        }
        value.append(NSAttributedString(string: activity,
            attributes: [.foregroundColor: color, .font: statusFont]))
        if let targetWidth {
            // AppKit centers an image+title group using the title's intrinsic
            // width. Add an invisible, precisely-kerned trailing glyph so all
            // activity words and dot counts have the exact same width.
            let spacerFont = NSFont.systemFont(ofSize: 1)
            let spacer = NSAttributedString(string: " ", attributes: [.font: spacerFont])
            let compensation = max(0, targetWidth - value.size().width - spacer.size().width)
            value.append(NSAttributedString(string: " ", attributes: [
                .font: spacerFont,
                .foregroundColor: NSColor.clear,
                .kern: compensation
            ]))
        }
        return value
    }

    @discardableResult
    private func reserveWorkingWidth(seconds: Int?, showTimer: Bool) -> CGFloat {
        let timerPattern: String?
        if showTimer, let seconds {
            if seconds >= 3600 {
                let hourDigits = max(1, String(seconds / 3600).count)
                timerPattern = String(repeating: "8", count: hourDigits) + ":88:88"
            } else {
                timerPattern = "88:88"
            }
        } else {
            timerPattern = nil
        }
        let widest = activityWords.map {
            workingTitle(timer: timerPattern, activity: $0 + "...", color: .labelColor).size().width
        }.max() ?? 90
        // The title is left-aligned inside a fixed slot. This covers the 18pt
        // image, image/title spacing, and the status-button edge insets.
        statusItem.length = ceil(widest + 30)
        return widest
    }

    private func elapsed(_ session: SessionTracker) -> Int? {
        guard session.state == .working, let started = session.startedAt else { return nil }
        return max(0, Int(Date().timeIntervalSince1970 - started))
    }

    private var skyBlueColor: NSColor {
        // #7B98FF
        NSColor(srgbRed: 123.0 / 255.0, green: 152.0 / 255.0, blue: 1.0, alpha: 1.0)
    }

    private var skyBlueAppearance: Bool {
        let value = UserDefaults.standard.string(forKey: "statusAppearance")
        return value == "skyBlue" || value == "colored"
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let state = store.state
        let workingFrame = workingStatusFrames.isEmpty ? -1 : iconAnimationFrame % workingStatusFrames.count
        let key = "\(state.rawValue)-\(skyBlueAppearance)"
        if key != lastImageKey {
            lastImageKey = key
            let fallback = NSImage(systemSymbolName: icon,
                accessibilityDescription: "Codex \(stateLabel(state))")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .bold))
            fallback?.isTemplate = true
            if state == .needsAttention {
                button.image = attentionStatusImage
                button.contentTintColor = nil
            } else if state == .working, workingFrame >= 0 {
                let frames = skyBlueAppearance && skyBlueWorkingStatusFrames.count == workingStatusFrames.count
                    ? skyBlueWorkingStatusFrames : workingStatusFrames
                button.image = frames[workingFrame]
                button.contentTintColor = nil
            } else if skyBlueAppearance, let skyBlueIdleStatusImage {
                button.image = skyBlueIdleStatusImage
                button.contentTintColor = nil
            } else {
                button.image = idleStatusImage ?? fallback
                button.contentTintColor = nil
            }
        }

        if state == .needsAttention {
            statusItem.length = NSStatusItem.variableLength
            button.alignment = .center
            let attentionCount = store.sessions.filter { $0.state == .needsAttention }.count
            let attentionTitle = attentionCount > 1 ? " \(attentionCount) Check Codex" : " Check Codex"
            button.attributedTitle = NSAttributedString(string: attentionTitle,
                attributes: [.foregroundColor: NSColor.labelColor,
                             .font: NSFont.systemFont(ofSize: 12, weight: .medium)])
            button.imagePosition = .imageLeading
        } else if let session = store.sessions.first(where: { $0.state == .working }) {
            let showTimer = UserDefaults.standard.bool(forKey: "showTimer")
            let seconds = elapsed(session)
            let timerText = showTimer ? seconds.map(formatDuration) : nil
            let reservedWidth = reserveWorkingWidth(seconds: seconds, showTimer: showTimer)
            button.alignment = .left
            button.attributedTitle = workingTitle(timer: timerText, activity: activityText(),
                                                   color: .labelColor, paddedTo: reservedWidth)
            button.imagePosition = .imageLeading
        } else {
            statusItem.length = NSStatusItem.variableLength
            button.alignment = .center
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        }
    }

    private func sessionRow(_ session: SessionTracker, showsSeparator: Bool) -> NSView {
        let row = SessionRowView()
        row.sessionID = session.id
        row.toolTip = "Open \(session.displayName) in Codex"
        row.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openSession(_:))))

        let stateIcon = NSImageView(image: sessionMenuImage(session) ?? NSImage())
        stateIcon.imageScaling = .scaleProportionallyUpOrDown
        stateIcon.translatesAutoresizingMaskIntoConstraints = false
        if session.state == .working { workingSessionIconViews.append(stateIcon) }

        let name = NSTextField(labelWithAttributedString: {
            let value = NSMutableAttributedString(string: session.projectName,
                attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                             .foregroundColor: NSColor.labelColor])
            value.append(NSAttributedString(string: " / \(session.sessionName)",
                attributes: [.font: NSFont.systemFont(ofSize: 14),
                             .foregroundColor: NSColor.secondaryLabelColor]))
            return value
        }())
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false

        var details = [session.state == .working ? activityText() : stateLabel(session.state)]
        if session.state == .working,
           UserDefaults.standard.bool(forKey: "showTimer"), let seconds = elapsed(session) {
            details.append(formatDuration(seconds))
        } else if session.state == .idle, let duration = session.durationMs {
            details.append("Last turn \(formatDuration(Int(duration / 1000)))")
        }
        if !session.model.isEmpty {
            details.append(session.model + (session.effort.isEmpty ? "" : " / \(session.effort)"))
        }
        let subtitle = NSTextField(labelWithString: details.joined(separator: "   "))
        subtitle.textColor = .tertiaryLabelColor
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let muted = preferenceSet("mutedSessionIDs").contains(session.id)
        let flags = NSStackView()
        flags.orientation = .horizontal
        flags.alignment = .centerY
        flags.spacing = 5
        if muted {
            let mute = NSImageView(image: symbolImage("speaker.slash", pointSize: 9) ?? NSImage())
            mute.contentTintColor = .secondaryLabelColor
            mute.toolTip = "Muted"
            flags.addArrangedSubview(mute)
        }
        flags.translatesAutoresizingMaskIntoConstraints = false

        let openButton = iconButton("arrow.up.forward.app", help: "Open in Codex",
                                    action: #selector(openSessionButton(_:)))
        openButton.identifier = NSUserInterfaceItemIdentifier(session.id)
        openButton.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.isHidden = !showsSeparator
        separator.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(stateIcon)
        row.addSubview(name)
        row.addSubview(subtitle)
        row.addSubview(flags)
        row.addSubview(openButton)
        row.addSubview(separator)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 64),
            stateIcon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            stateIcon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            stateIcon.widthAnchor.constraint(equalToConstant: 30),
            stateIcon.heightAnchor.constraint(equalToConstant: 30),
            name.leadingAnchor.constraint(equalTo: stateIcon.trailingAnchor, constant: 13),
            name.trailingAnchor.constraint(lessThanOrEqualTo: flags.leadingAnchor, constant: -8),
            name.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
            subtitle.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -10),
            subtitle.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),
            flags.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -8),
            flags.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            openButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            openButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])

        row.menu = sessionControlsMenu(session)
        return row
    }

    @objc private func openSessionButton(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        openCodexThread(id)
    }

    private func emptySessionsView() -> NSView {
        let icon = NSImageView(image: symbolImage("sparkles", pointSize: 20, color: skyBlueColor) ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28)
        ])
        let title = NSTextField(labelWithString: "No open sessions")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(labelWithString: "Start a Codex task and it will appear here.")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 5
        let view = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 130),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        return view
    }

    private func updateHistoryRows() {
        for view in historyStack.arrangedSubviews {
            historyStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if history.isEmpty {
            let empty = NSTextField(labelWithString: "Completed turns and questions will appear here.")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            historyStack.addArrangedSubview(empty)
            return
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        for entry in history.prefix(2) {
            let iconName = entry.kind == .attention ? "questionmark.bubble.fill" : "checkmark.circle"
            let icon = NSImageView(image: symbolImage(iconName, pointSize: 11,
                color: entry.kind == .attention ? skyBlueColor : nil) ?? NSImage())
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18)
            ])
            let liveSession = store.sessions.first { $0.id == entry.sessionID }
            let projectName = liveSession?.projectName ?? entry.projectName
            let sessionName = liveSession?.sessionName ?? entry.sessionName
            let label = NSTextField(labelWithString: "\(projectName) / \(sessionName)")
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.lineBreakMode = .byTruncatingMiddle
            let date = NSTextField(labelWithString: formatter.localizedString(for: entry.date, relativeTo: Date()))
            date.font = .systemFont(ofSize: 10)
            date.textColor = .tertiaryLabelColor
            let row = NSStackView(views: [icon, label, NSView(), date])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 7
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 24).isActive = true
            historyStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: historyStack.widthAnchor).isActive = true
        }
    }

    private func updateWindow(force: Bool) {
        let sessions = store.sessions
        let active = sessions.filter { $0.state == .working }.count
        let attention = sessions.filter { $0.state == .needsAttention }.count
        let total = sessions.count
        let fullBodyHeight = sessions.isEmpty ? CGFloat(130) : CGFloat(sessions.count * 64)
        let visibleBodyHeight = sessions.isEmpty ? fullBodyHeight : min(fullBodyHeight, CGFloat(3 * 64))
        sessionDocumentHeightConstraint.constant = fullBodyHeight
        sessionsCardHeightConstraint.constant = 45 + visibleBodyHeight
        if total == 0 {
            summaryField.stringValue = "Ready when you are."
        } else {
            var parts = ["\(total) open"]
            if active > 0 { parts.append("\(active) working") }
            if attention > 0 { parts.append("\(attention) waiting for you") }
            summaryField.stringValue = parts.joined(separator: ", ")
        }

        let preferenceKey = ["mutedSessionIDs"]
            .map { UserDefaults.standard.stringArray(forKey: $0)?.joined(separator: ",") ?? "" }
            .joined(separator: "|")
        let key = sessions.map { session in
            "\(session.id):\(session.state.rawValue):\(elapsed(session) ?? -1):\(session.cwd):\(session.threadTitle)"
        }.joined(separator: "|") + preferenceKey + (history.first?.id.uuidString ?? "")
        if force || key != lastRowsKey {
            lastRowsKey = key
            workingSessionIconViews.removeAll()
            for view in sessionStack.arrangedSubviews {
                sessionStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            if sessions.isEmpty {
                let empty = emptySessionsView()
                sessionStack.addArrangedSubview(empty)
                empty.widthAnchor.constraint(equalTo: sessionStack.widthAnchor).isActive = true
            } else {
                for (index, session) in sessions.enumerated() {
                    let row = sessionRow(session, showsSeparator: index < sessions.count - 1)
                    sessionStack.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: sessionStack.widthAnchor).isActive = true
                }
            }
            updateHistoryRows()
        }

        let defaults = UserDefaults.standard
        timerCheck.state = defaults.bool(forKey: "showTimer") ? .on : .off
        completionSoundCheck.state = defaults.bool(forKey: "completionSound") ? .on : .off
        attentionSoundCheck.state = defaults.bool(forKey: "attentionSound") ? .on : .off
        completionSoundPopup.selectItem(withTitle: defaults.string(forKey: "completionSoundName") ?? "Glass")
        attentionSoundPopup.selectItem(withTitle: defaults.string(forKey: "attentionSoundName") ?? "Ping")
        quietHoursCheck.state = defaults.bool(forKey: "quietHoursEnabled") ? .on : .off
        quietStartPopup.selectItem(at: defaults.integer(forKey: "quietStartHour"))
        quietEndPopup.selectItem(at: defaults.integer(forKey: "quietEndHour"))
        quietStartPopup.isEnabled = defaults.bool(forKey: "quietHoursEnabled")
        quietEndPopup.isEnabled = defaults.bool(forKey: "quietHoursEnabled")
        updateCheck.state = defaults.bool(forKey: "checkForUpdates") ? .on : .off
        dockCheck.state = defaults.bool(forKey: "showInDock") ? .on : .off
        appearancePopup.selectItem(at: skyBlueAppearance ? 1 : 0)
        if #available(macOS 13.0, *) {
            loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
            loginCheck.isHidden = false
        } else {
            loginCheck.isHidden = true
        }
    }

    // MARK: - Notifications

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: "OPEN_TASK", title: "Open Task",
                                        options: [.foreground])
        let mute = UNNotificationAction(identifier: "MUTE_SESSION", title: "Mute Session",
                                        options: [])
        let category = UNNotificationCategory(identifier: "CODEX_SESSION",
                                              actions: [open, mute], intentIdentifiers: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard let id = response.notification.request.content.userInfo["sessionID"] as? String else { return }
        if response.actionIdentifier == "MUTE_SESSION" {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var muted = self.preferenceSet("mutedSessionIDs")
                muted.insert(id)
                self.setPreferenceSet(muted, forKey: "mutedSessionIDs")
                self.updateWindow(force: true)
            }
        } else if response.actionIdentifier == "OPEN_TASK"
                    || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { [weak self] in self?.openCodexThread(id) }
        }
    }

    private func postLegacyNotification(title: String, body: String) {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
        }
        let script = "display notification \"\(escape(String(body.prefix(200))))\" with title \"\(escape(title))\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private func postNotification(title: String, body: String, sessionID: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                self?.postLegacyNotification(title: title, body: body)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = String(body.prefix(240))
            content.categoryIdentifier = "CODEX_SESSION"
            content.userInfo = ["sessionID": sessionID]
            let request = UNNotificationRequest(identifier: "codex-\(sessionID)-\(UUID().uuidString)",
                                                content: content, trigger: nil)
            center.add(request)
        }
    }

    private func isQuietHours() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "quietHoursEnabled") else { return false }
        let hour = Calendar.current.component(.hour, from: Date())
        let start = defaults.integer(forKey: "quietStartHour")
        let end = defaults.integer(forKey: "quietEndHour")
        if start == end { return true }
        if start < end { return hour >= start && hour < end }
        return hour >= start || hour < end
    }

    private func alertSound(named name: String) -> NSSound? {
        NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true)
    }

    private func playAlertSound(_ sound: NSSound?) {
        guard let sound else {
            NSSound.beep()
            return
        }
        sound.stop()
        sound.currentTime = 0
        if !sound.play() { NSSound.beep() }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: "activityHistory"),
              let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        history = saved
    }

    private func recordHistory(_ session: SessionTracker, kind: HistoryKind) {
        history.insert(HistoryEntry(id: UUID(), sessionID: session.id,
                                    projectName: session.projectName,
                                    sessionName: session.sessionName,
                                    kind: kind, date: Date()), at: 0)
        history = Array(history.prefix(50))
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "activityHistory")
        }
    }

    private func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    private func checkForUpdates(silent: Bool) {
        guard !updateCheckInFlight,
              let url = URL(string: "https://api.github.com/repos/anes-laieb/codex-bar/releases/latest") else { return }
        updateCheckInFlight = true
        var request = URLRequest(url: url)
        request.setValue("Codex-Bar", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateCheckInFlight = false
                guard error == nil, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    if !silent { self.showUpdateResult("Could not check for updates.") }
                    return
                }
                let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                if self.isVersion(version, newerThan: current) {
                    self.latestVersion = version
                    self.updateURL = (json["html_url"] as? String).flatMap(URL.init(string:))
                    if !silent { self.showUpdateResult("Codex Bar \(version) is available.") }
                } else if !silent {
                    self.showUpdateResult("You are using the latest version.")
                }
                self.updateWindow(force: true)
            }
        }.resume()
    }

    private func showUpdateResult(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Software Update"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func checkForUpdatesNow() { checkForUpdates(silent: false) }

    @objc private func openAvailableUpdate() {
        if let updateURL { NSWorkspace.shared.open(updateURL) }
    }

    private func notifyCompletion(_ session: SessionTracker) {
        let body = session.lastMessage.isEmpty ? "Turn complete" : session.lastMessage
        recordHistory(session, kind: .completed)
        let muted = preferenceSet("mutedSessionIDs").contains(session.id)
        if UserDefaults.standard.bool(forKey: "completionSound"), !muted, !isQuietHours() {
            playAlertSound(alertSound(named: UserDefaults.standard.string(forKey: "completionSoundName") ?? "Glass"))
        }
        if !muted {
            postNotification(title: "\(session.projectName) / \(session.sessionName) is ready",
                             body: body, sessionID: session.id)
        }
    }

    private func notifyAttention(_ session: SessionTracker) {
        recordHistory(session, kind: .attention)
        let muted = preferenceSet("mutedSessionIDs").contains(session.id)
        if UserDefaults.standard.bool(forKey: "attentionSound"), !muted, !isQuietHours() {
            playAlertSound(alertSound(named: UserDefaults.standard.string(forKey: "attentionSoundName") ?? "Ping"))
        }
        if !muted {
            postNotification(title: "\(session.projectName) / \(session.sessionName) needs attention",
                             body: "Codex is waiting for your answer or approval.", sessionID: session.id)
        }
    }

    // MARK: - Status-item menu

    private func refreshWeeklyUsage(force: Bool = false) {
        guard !usageRefreshInFlight,
              force || Date().timeIntervalSince(lastUsageRefresh) >= 15 else { return }
        usageRefreshInFlight = true
        lastUsageRefresh = Date()
        let home = codexHome
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let usage = Self.readLatestWeeklyUsage(from: home)
            DispatchQueue.main.async {
                self?.weeklyUsage = usage ?? self?.weeklyUsage
                self?.usageRefreshInFlight = false
            }
        }
    }

    private static func readLatestWeeklyUsage(from codexHome: URL) -> UsageSnapshot? {
        let sessions = codexHome.appendingPathComponent("sessions")
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: sessions,
            includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }

        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast))
        }

        for (url, _) in candidates.sorted(by: { $0.1 > $1.1 }).prefix(24) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let tailBytes: UInt64 = 2 * 1024 * 1024
            let start = size > tailBytes ? size - tailBytes : 0
            try? handle.seek(toOffset: start)
            guard let data = try? handle.readToEnd(),
                  let text = String(data: data, encoding: .utf8) else { continue }
            var lines = text.components(separatedBy: "\n")
            if start > 0, !lines.isEmpty { lines.removeFirst() }

            for line in lines.reversed() {
                guard line.contains("\"rate_limits\""),
                      let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let rateLimits = payload["rate_limits"] as? [String: Any],
                      (rateLimits["limit_id"] as? String ?? "codex") == "codex" else { continue }

                for key in ["primary", "secondary"] {
                    guard let limit = rateLimits[key] as? [String: Any],
                          let window = (limit["window_minutes"] as? NSNumber)?.intValue,
                          window >= 7 * 24 * 60,
                          let used = (limit["used_percent"] as? NSNumber)?.doubleValue,
                          let reset = (limit["resets_at"] as? NSNumber)?.doubleValue else { continue }
                    return UsageSnapshot(usedPercent: max(0, min(100, Int(used.rounded()))),
                                         resetsAt: Date(timeIntervalSince1970: reset))
                }
            }
        }
        return nil
    }

    private func weeklyUsageTitle() -> String {
        guard let usage = weeklyUsage else { return "Weekly usage unavailable" }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "d MMM"
        return "Weekly \(usage.remainingPercent)% left · \(formatter.string(from: usage.resetsAt))"
    }

    private func usageProgressItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 42))
        let label = NSTextField(labelWithString: weeklyUsageTitle())
        label.frame = NSRect(x: 18, y: 22, width: 304, height: 16)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        view.addSubview(label)

        let track = NSView(frame: NSRect(x: 18, y: 8, width: 304, height: 6))
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        track.layer?.cornerRadius = 3
        let percent = weeklyUsage?.remainingPercent ?? 0
        let fill = NSView(frame: NSRect(x: 0, y: 0,
            width: 304 * CGFloat(percent) / 100, height: 6))
        fill.wantsLayer = true
        let color: NSColor = percent <= 10 ? .systemRed
            : percent <= 25 ? .systemOrange : skyBlueColor
        fill.layer?.backgroundColor = color.cgColor
        fill.layer?.cornerRadius = 3
        track.addSubview(fill)
        track.setAccessibilityElement(true)
        track.setAccessibilityRole(.progressIndicator)
        track.setAccessibilityLabel("Weekly Codex usage remaining")
        track.setAccessibilityValue("\(percent) percent left")
        view.addSubview(track)
        item.view = view
        return item
    }

    private func sessionControlsMenu(_ session: SessionTracker) -> NSMenu {
        let menu = NSMenu()
        let open = configuredMenuItem("Open in Codex", symbol: "arrow.up.forward.app",
                                      action: #selector(openSession(_:)))
        open.representedObject = session.id
        menu.addItem(open)
        menu.addItem(.separator())

        let pinned = preferenceSet("pinnedSessionIDs").contains(session.id)
        let pin = configuredMenuItem(pinned ? "Unpin from Menu Bar" : "Pin in Menu Bar", symbol: "pin",
                                     action: #selector(togglePinnedSession(_:)))
        pin.representedObject = session.id
        menu.addItem(pin)

        let muted = preferenceSet("mutedSessionIDs").contains(session.id)
        let mute = configuredMenuItem(muted ? "Unmute Alerts" : "Mute Alerts",
                                      symbol: muted ? "speaker.wave.2" : "speaker.slash",
                                      action: #selector(toggleMutedSession(_:)))
        mute.representedObject = session.id
        menu.addItem(mute)

        let hide = configuredMenuItem("Hide from Menu Bar", symbol: "eye.slash",
                                      action: #selector(hideSession(_:)))
        hide.representedObject = session.id
        menu.addItem(hide)
        return menu
    }

    @discardableResult
    private func info(_ menu: NSMenu, _ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        return item
    }

    private func sessionMenuTitle(_ session: SessionTracker) -> String {
        func shortened(_ value: String, limit: Int) -> String {
            guard value.count > limit else { return value }
            return value.prefix(max(1, limit - 1))
                .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }

        let project = shortened(session.projectName, limit: 16)
        let sessionName = shortened(session.sessionName, limit: 24)
        var title = "\(project)  /  \(sessionName)"
        if UserDefaults.standard.bool(forKey: "showTimer"), let seconds = elapsed(session) {
            title += "  \(formatDuration(seconds))"
        }
        if preferenceSet("pinnedSessionIDs").contains(session.id) { title += "  (Pinned)" }
        return title
    }

    private func sessionMenuImage(_ session: SessionTracker) -> NSImage? {
        switch session.state {
        case .needsAttention: return symbolImage("questionmark.bubble.fill", color: skyBlueColor)
        case .working:
            guard !workingStatusFrames.isEmpty else {
                return symbolImage("ellipsis.circle.fill", color: skyBlueColor)
            }
            let frames = skyBlueWorkingStatusFrames.count == workingStatusFrames.count
                ? skyBlueWorkingStatusFrames : workingStatusFrames
            return frames[iconAnimationFrame % frames.count]
        case .idle: return symbolImage("checkmark.circle")
        case .unknown: return symbolImage("circle.dotted")
        }
    }

    private func menuHeaderItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 66))

        let iconView = NSImageView(frame: NSRect(x: 14, y: 16, width: 34, height: 34))
        iconView.image = appLogoImage ?? NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(iconView)

        let title = NSTextField(labelWithString: "Codex Bar")
        title.frame = NSRect(x: 60, y: 34, width: 260, height: 19)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        view.addSubview(title)
        liveMenuHeaderTitle = title

        let subtitle = NSTextField(labelWithString: menuSummary())
        subtitle.frame = NSRect(x: 60, y: 14, width: 260, height: 17)
        subtitle.font = .systemFont(ofSize: 11, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        view.addSubview(subtitle)
        liveMenuHeaderSubtitle = subtitle

        item.view = view
        return item
    }

    private func menuSummary() -> String {
        let sessions = visibleSessions
        let working = sessions.filter { $0.state == .working }.count
        let attention = sessions.filter { $0.state == .needsAttention }.count
        if attention > 0 { return "\(attention) waiting for you, \(sessions.count) open" }
        if working > 0 { return "\(working) working, \(sessions.count) open" }
        if sessions.isEmpty { return "Ready when you are" }
        return "\(sessions.count) open, all caught up"
    }

    private func configuredMenuItem(_ title: String, symbol: String,
                                    action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.image = symbolImage(symbol)
        return item
    }

    private func updateLiveMenu() {
        guard liveMenuHeaderTitle != nil else { return }
        liveMenuHeaderSubtitle?.stringValue = menuSummary()
        for session in visibleSessions.prefix(10) {
            liveMenuSessions[session.id]?.title = sessionMenuTitle(session)
            liveMenuSessions[session.id]?.image = sessionMenuImage(session)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshWeeklyUsage(force: true)
        menu.removeAllItems()
        liveMenuSessions.removeAll()
        menu.minimumWidth = 340
        menu.addItem(menuHeaderItem())
        menu.addItem(.separator())

        let sessions = visibleSessions
        if sessions.isEmpty {
            let empty = info(menu, "No visible sessions")
            empty.image = symbolImage("tray")
        } else {
            let section = info(menu, "Open sessions")
            section.image = symbolImage("rectangle.stack")
            for session in sessions.prefix(10) {
                let item = NSMenuItem(title: sessionMenuTitle(session), action: nil,
                                      keyEquivalent: "")
                item.image = sessionMenuImage(session)
                item.submenu = sessionControlsMenu(session)
                menu.addItem(item)
                liveMenuSessions[session.id] = item
            }
            if sessions.count > 10 { info(menu, "\(sessions.count - 10) more in the sessions window") }
        }

        menu.addItem(.separator())
        info(menu, "Usage")
        menu.addItem(usageProgressItem())

        menu.addItem(.separator())
        let newChat = configuredMenuItem("New Chat", symbol: "square.and.pencil", action: nil)
        let projectMenu = NSMenu()
        let noProject = configuredMenuItem("Without Project", symbol: "plus",
                                           action: #selector(newCodexChat))
        projectMenu.addItem(noProject)
        let projects = store.recentProjects()
        if !projects.isEmpty { projectMenu.addItem(.separator()) }
        for project in projects {
            let item = configuredMenuItem(project.name, symbol: "folder",
                                          action: #selector(newChatInProject(_:)))
            item.representedObject = project.path
            item.toolTip = project.path
            projectMenu.addItem(item)
        }
        newChat.submenu = projectMenu
        newChat.keyEquivalent = "n"
        newChat.keyEquivalentModifierMask = [.command]
        menu.addItem(newChat)

        let open = configuredMenuItem("Open Sessions Window", symbol: "rectangle.grid.1x2",
                                      action: #selector(showWindow))
        menu.addItem(open)

        let historyItem = configuredMenuItem("Recent Activity", symbol: "clock.arrow.circlepath", action: nil)
        let historyMenu = NSMenu()
        if history.isEmpty {
            info(historyMenu, "No recent activity")
        } else {
            for entry in history.prefix(8) {
                let title = "\(entry.projectName) / \(entry.sessionName)"
                let item = NSMenuItem(title: title, action: #selector(openSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.sessionID
                item.image = symbolImage(entry.kind == .attention ? "questionmark.bubble.fill" : "checkmark.circle")
                historyMenu.addItem(item)
            }
        }
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)

        let hidden = preferenceSet("hiddenSessionIDs")
        let hiddenSessions = store.sessions.filter { hidden.contains($0.id) }
        if !hiddenSessions.isEmpty {
            let hiddenItem = configuredMenuItem("Hidden Sessions", symbol: "eye.slash", action: nil)
            let hiddenMenu = NSMenu()
            for session in hiddenSessions {
                let item = NSMenuItem(title: "Show \(session.displayName) in Menu Bar",
                                      action: #selector(unhideSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = session.id
                item.image = symbolImage("eye")
                hiddenMenu.addItem(item)
            }
            hiddenItem.submenu = hiddenMenu
            menu.addItem(hiddenItem)
        }

        let preferences = configuredMenuItem("Quick Preferences", symbol: "slider.horizontal.3", action: nil)
        let preferencesMenu = NSMenu()
        let timerItem = configuredMenuItem("Show Timer", symbol: "timer", action: #selector(toggleTimer))
        timerItem.state = UserDefaults.standard.bool(forKey: "showTimer") ? .on : .off
        preferencesMenu.addItem(timerItem)

        let completionItem = configuredMenuItem("Completion Sound", symbol: "speaker.wave.2", action: #selector(toggleCompletionSound))
        completionItem.state = UserDefaults.standard.bool(forKey: "completionSound") ? .on : .off
        preferencesMenu.addItem(completionItem)

        let attentionItem = configuredMenuItem("Question Sound", symbol: "bell.badge", action: #selector(toggleAttentionSound))
        attentionItem.state = UserDefaults.standard.bool(forKey: "attentionSound") ? .on : .off
        preferencesMenu.addItem(attentionItem)

        let quietItem = configuredMenuItem("Quiet Hours", symbol: "moon", action: #selector(toggleQuietHours))
        quietItem.state = UserDefaults.standard.bool(forKey: "quietHoursEnabled") ? .on : .off
        preferencesMenu.addItem(quietItem)

        let dockItem = configuredMenuItem("Show in Dock", symbol: "dock.rectangle", action: #selector(toggleDockVisibility))
        dockItem.state = UserDefaults.standard.bool(forKey: "showInDock") ? .on : .off
        preferencesMenu.addItem(dockItem)

        let appearance = configuredMenuItem("Icon Color", symbol: "paintpalette", action: nil)
        let appearanceMenu = NSMenu()
        let systemItem = configuredMenuItem("System", symbol: "circle.lefthalf.filled", action: #selector(useSystemAppearance))
        systemItem.state = skyBlueAppearance ? .off : .on
        appearanceMenu.addItem(systemItem)
        let skyBlueItem = configuredMenuItem("Sky Blue", symbol: "drop.fill", action: #selector(useSkyBlueAppearance))
        skyBlueItem.state = skyBlueAppearance ? .on : .off
        appearanceMenu.addItem(skyBlueItem)
        appearance.submenu = appearanceMenu
        preferencesMenu.addItem(appearance)

        if #available(macOS 13.0, *) {
            let login = configuredMenuItem("Launch at Login", symbol: "power", action: #selector(toggleLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            preferencesMenu.addItem(login)
        }
        preferences.submenu = preferencesMenu
        menu.addItem(preferences)

        let update = configuredMenuItem(latestVersion.map { "Update Available: \($0)" } ?? "Check for Updates",
                                        symbol: latestVersion == nil ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill",
                                        action: latestVersion == nil ? #selector(checkForUpdatesNow) : #selector(openAvailableUpdate))
        menu.addItem(update)

        menu.addItem(.separator())
        let quit = configuredMenuItem("Quit Codex Bar", symbol: "xmark.circle", action: nil)
        quit.action = #selector(NSApplication.terminate(_:))
        quit.target = NSApp
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func toggleDefault(_ key: String) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        render()
        updateWindow(force: true)
    }

    @objc private func toggleTimer() { toggleDefault("showTimer") }
    @objc private func toggleCompletionSound() { toggleDefault("completionSound") }
    @objc private func toggleAttentionSound() { toggleDefault("attentionSound") }
    @objc private func toggleQuietHours() { toggleDefault("quietHoursEnabled") }

    @objc private func changeSoundSelection(_ sender: NSPopUpButton) {
        let key = sender === completionSoundPopup ? "completionSoundName" : "attentionSoundName"
        if let value = sender.titleOfSelectedItem { UserDefaults.standard.set(value, forKey: key) }
    }

    @objc private func previewCompletionSound() {
        playAlertSound(alertSound(named: UserDefaults.standard.string(forKey: "completionSoundName") ?? "Glass"))
    }

    @objc private func previewAttentionSound() {
        playAlertSound(alertSound(named: UserDefaults.standard.string(forKey: "attentionSoundName") ?? "Ping"))
    }

    @objc private func changeQuietSchedule() {
        UserDefaults.standard.set(quietStartPopup.indexOfSelectedItem, forKey: "quietStartHour")
        UserDefaults.standard.set(quietEndPopup.indexOfSelectedItem, forKey: "quietEndHour")
        updateWindow(force: true)
    }

    @objc private func toggleUpdateChecks() { toggleDefault("checkForUpdates") }

    private func applyDockVisibility(_ visible: Bool, preservingOpenWindow: Bool = false) {
        let shouldRestoreWindow = preservingOpenWindow && (window?.isVisible ?? false)
        let wasKeyWindow = window?.isKeyWindow ?? false
        let previousFrame = window?.frame

        NSApp.setActivationPolicy(visible ? .regular : .accessory)

        guard shouldRestoreWindow, let window else { return }
        let restoreWindow = { [weak self, weak window] in
            guard let self, let window else { return }
            if let previousFrame { window.setFrame(previousFrame, display: false) }
            if wasKeyWindow {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                window.orderFrontRegardless()
            }
            self.updateWindow(force: true)
        }

        // AppKit can withdraw windows after the activation-policy call returns,
        // so restore now and once more on the next main-run-loop pass.
        restoreWindow()
        DispatchQueue.main.async(execute: restoreWindow)
    }

    @objc private func toggleDockVisibility() {
        let defaults = UserDefaults.standard
        let visible = !defaults.bool(forKey: "showInDock")
        defaults.set(visible, forKey: "showInDock")
        applyDockVisibility(visible, preservingOpenWindow: true)
    }

    @objc private func changeAppearance() {
        setAppearance(skyBlue: appearancePopup.indexOfSelectedItem == 1)
    }

    @objc private func useSystemAppearance() { setAppearance(skyBlue: false) }
    @objc private func useSkyBlueAppearance() { setAppearance(skyBlue: true) }

    private func setAppearance(skyBlue: Bool) {
        UserDefaults.standard.set(skyBlue ? "skyBlue" : "system", forKey: "statusAppearance")
        lastImageKey = ""
        render()
        updateWindow(force: true)
    }

    @available(macOS 13.0, *)
    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() }
            else { try service.register() }
        } catch { NSSound.beep() }
        updateWindow(force: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
