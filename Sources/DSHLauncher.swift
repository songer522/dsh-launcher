// DSH Launcher — a small AppKit control panel for a local dev server.
//
// Written for `pnpm dsh web` (DeepSeek Harness) but not tied to it: the command,
// port, repo directory and browser all come from a config file.
//
// Window policy:
//   * close    — enabled
//   * minimize — enabled
//   * zoom / fullscreen — disabled (fixed-size panel)
//
// Three implementation details that are outright bugs if ignored:
//   * A GUI app does not read your shell rc files and has no login PATH, so
//     every binary is resolved explicitly (see Tools.which).
//   * Port probing uses `lsof -sTCP:LISTEN`. Plain `lsof -ti tcp:PORT` also
//     matches CLIENTS connected to the port (your browser!), so stopping the
//     server that way can kill unrelated apps.
//   * The server is started detached so it outlives this launcher.

import AppKit
import Foundation

// MARK: - Tool resolution

/// Locates helper binaries without relying on an inherited PATH.
enum Tools {
    /// Common Homebrew / system locations, searched in order.
    private static let searchPaths = [
        "/opt/homebrew/bin",       // Apple Silicon Homebrew
        "/usr/local/bin",          // Intel Homebrew
        "/opt/homebrew/sbin",
        "/usr/local/sbin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        NSHomeDirectory() + "/.volta/bin",
        NSHomeDirectory() + "/.nvm/versions/node",
        NSHomeDirectory() + "/.local/bin",
    ]

    /// Absolute path for `name`, or nil when it cannot be found.
    static func which(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        for dir in searchPaths {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        // Last resort: ask a login shell, which does read the user's rc files.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let out = Shell.run("\(shell) -lic 'command -v \(name)' 2>/dev/null")
        return out.isEmpty ? nil : out
    }

    static let lsof = which("lsof") ?? "/usr/sbin/lsof"
    static let open = "/usr/bin/open"
    static let kill = "/bin/kill"
    static let ps   = "/bin/ps"
}

// MARK: - Shell

enum Shell {
    @discardableResult
    static func run(_ command: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Configuration

/// User settings, resolved in this order:
///   1. ~/.config/dsh-launcher/config.json
///   2. auto-detection (a DSH checkout in common locations)
///   3. built-in defaults
struct Config: Codable {
    var repo: String
    var command: String
    var port: String
    var browser: String
    var logFile: String

    static let configURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/dsh-launcher/config.json")

    static var defaults: Config {
        Config(
            repo: autodetectRepo() ?? NSHomeDirectory(),
            command: "pnpm dsh web --no-open --port {port}",
            port: "3080",
            browser: "Google Chrome",
            logFile: NSTemporaryDirectory() + "dsh-web.log"
        )
    }

    /// Look for a DeepSeek Harness checkout in the usual places.
    static func autodetectRepo() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/Workspace/deepseek-harness",
            "\(home)/Projects/deepseek-harness",
            "\(home)/Developer/deepseek-harness",
            "\(home)/src/deepseek-harness",
            "\(home)/code/deepseek-harness",
            "\(home)/deepseek-harness",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path + "/package.json") { return path }
        }
        return nil
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(Config.self, from: data)
        else { return defaults }
        return decoded
    }

    /// Write the current settings, creating the directory if needed.
    func save() {
        let dir = Config.configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Config.configURL)
    }

    /// The launch command with placeholders substituted.
    var resolvedCommand: String {
        command.replacingOccurrences(of: "{port}", with: port)
    }

    var url: String { "http://127.0.0.1:\(port)" }

    /// Whether the configured repo looks usable.
    var repoExists: Bool {
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: repo, isDirectory: &isDir)
        return ok && isDir.boolValue
    }
}

// MARK: - Server control

enum Server {
    /// PID of the process LISTENING on `port`, or nil when the port is free.
    ///
    /// `-sTCP:LISTEN` is essential: without it lsof also reports clients that
    /// merely hold a connection to the port (browsers, editors), and acting on
    /// those PIDs would terminate unrelated applications.
    static func listenerPID(port: String) -> String? {
        let out = Shell.run("\(Tools.lsof) -ti tcp:\(port) -sTCP:LISTEN")
        let pid = out.split(separator: "\n").first.map(String.init) ?? ""
        return pid.isEmpty ? nil : pid
    }

    static func describe(pid: String) -> String {
        let out = Shell.run("\(Tools.ps) -p \(pid) -o command= | cut -c1-80")
        return out.isEmpty ? "(unknown process)" : out
    }

    /// Start detached so the server outlives this launcher.
    static func start(config: Config) {
        let log = config.logFile.replacingOccurrences(of: "'", with: "'\\''")
        Shell.run("cd '\(config.repo)' && /usr/bin/nohup /bin/sh -lc "
            + "'\(config.resolvedCommand.replacingOccurrences(of: "'", with: "'\\''"))' "
            + "> '\(log)' 2>&1 &")
    }

    /// Wait for the port to accept connections. Returns false on timeout.
    static func waitUntilReady(port: String, timeout: TimeInterval = 40) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if listenerPID(port: port) != nil { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }

    /// Graceful TERM, escalating to KILL only if the port stays bound.
    @discardableResult
    static func stop(pid: String, port: String) -> Bool {
        Shell.run("\(Tools.kill) \(pid)")
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.3)
            if listenerPID(port: port) == nil { return true }
        }
        Shell.run("\(Tools.kill) -9 \(pid)")
        Thread.sleep(forTimeInterval: 0.5)
        return listenerPID(port: port) == nil
    }

    static func openBrowser(config: Config) {
        let app = config.browser.replacingOccurrences(of: "'", with: "'\\''")
        if app.isEmpty {
            Shell.run("\(Tools.open) \(config.url)")           // system default
        } else {
            Shell.run("\(Tools.open) -a '\(app)' \(config.url)")
        }
    }
}

// MARK: - Shared controller
//
// One owner of config + state, shared by the status item and the window, so the
// two views can never disagree about whether the server is running.

final class LauncherController {
    static let shared = LauncherController()

    var config = Config.load()
    private(set) var runningPID: String?
    private(set) var busy = false
    private(set) var busyMessage = ""

    /// Observers notified whenever state changes (menu + window redraw).
    private var observers: [() -> Void] = []
    private var pollTimer: Timer?

    func addObserver(_ block: @escaping () -> Void) { observers.append(block) }

    private func notify() {
        DispatchQueue.main.async { self.observers.forEach { $0() } }
    }

    var isRunning: Bool { runningPID != nil }

    var statusText: String {
        if busy { return busyMessage }
        return isRunning ? "Running on port \(config.port)" : "Not running"
    }

    var detailText: String {
        if busy { return "" }
        if let pid = runningPID { return "PID \(pid) · \(Server.describe(pid: pid))" }
        if !config.repoExists { return "⚠︎ Project folder not found — see Preferences" }
        return "Press Start to launch the server."
    }

    /// Re-read server state. Cheap (one lsof), so it is safe to poll.
    func refresh() {
        let pid = Server.listenerPID(port: config.port)
        if pid != runningPID {
            runningPID = pid
            notify()
        }
    }

    /// Poll in the background so the menu bar icon stays honest even when the
    /// server is started or stopped from a terminal.
    func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, !self.busy else { return }
            DispatchQueue.global(qos: .utility).async { self.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        DispatchQueue.global(qos: .utility).async { self.refresh() }
    }

    private func setBusy(_ value: Bool, _ message: String = "") {
        busy = value
        busyMessage = message
        notify()
    }

    // MARK: Actions

    func openBrowser() { Server.openBrowser(config: config) }

    func start(completion: ((Bool) -> Void)? = nil) {
        guard config.repoExists else {
            Alerts.warn("Project folder not found:\n\(config.repo)",
                        detail: "Set the correct path in Preferences (⌘,).")
            completion?(false)
            return
        }
        setBusy(true, "Starting…")
        let cfg = config
        DispatchQueue.global().async {
            Server.start(config: cfg)
            let ready = Server.waitUntilReady(port: cfg.port)
            if ready {
                Thread.sleep(forTimeInterval: 0.6)   // let HTTP finish binding
                Server.openBrowser(config: cfg)
            }
            self.refresh()
            DispatchQueue.main.async {
                self.setBusy(false)
                self.refresh()
                if !ready {
                    Alerts.warn("The server did not start in time.",
                                detail: "Check the log:\n\(cfg.logFile)")
                }
                completion?(ready)
            }
        }
    }

    func restart() {
        guard let pid = runningPID ?? Server.listenerPID(port: config.port) else { refresh(); return }
        setBusy(true, "Restarting…")
        let cfg = config
        DispatchQueue.global().async {
            Server.stop(pid: pid, port: cfg.port)
            DispatchQueue.main.async { self.setBusy(false); self.start() }
        }
    }

    /// `confirm` is false when the caller already asked (menu bar path).
    func stop(confirm: Bool = true) {
        guard let pid = runningPID ?? Server.listenerPID(port: config.port) else { refresh(); return }

        if confirm {
            // A running server may be hosting live sessions — never stop silently.
            let alert = NSAlert()
            alert.messageText = "Stop the server?"
            alert.informativeText = "PID \(pid) will be terminated.\n"
                + "Anything connected in the browser will disconnect."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Stop Server")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        setBusy(true, "Stopping…")
        let cfg = config
        DispatchQueue.global().async {
            let ok = Server.stop(pid: pid, port: cfg.port)
            self.refresh()
            DispatchQueue.main.async {
                self.setBusy(false)
                self.refresh()
                if !ok {
                    Alerts.warn("Could not stop PID \(pid).",
                                detail: "Try again, or stop it from a terminal.")
                }
            }
        }
    }

    func openLog() {
        if !FileManager.default.fileExists(atPath: config.logFile) {
            FileManager.default.createFile(atPath: config.logFile, contents: Data())
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: config.logFile))
    }
}

enum Alerts {
    static func warn(_ text: String, detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = text
        a.informativeText = detail
        a.alertStyle = .warning
        a.runModal()
    }
}

// MARK: - Status bar icon
//
// Drawn in code as a template image so macOS tints it correctly for light and
// dark menu bars, and for the highlighted state when the menu is open.

enum StatusIcon {
    static func image(running: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 3.0, dy: 3.0)
            let path = NSBezierPath(ovalIn: inset)
            NSColor.black.setStroke()
            NSColor.black.setFill()
            path.lineWidth = 1.6
            if running {
                path.fill()          // filled = running
            } else {
                path.stroke()        // outline = stopped
            }
            return true
        }
        image.isTemplate = true      // let AppKit handle menu-bar tinting
        return image
    }
}

// MARK: - Main window

final class LauncherWindow: NSWindow {
    private let controller = LauncherController.shared

    private let statusDot = NSTextField(labelWithString: "")
    private let statusLine = NSTextField(labelWithString: "")
    private let detailLine = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let hint = NSTextField(labelWithString: "")

    private let startButton = NSButton()
    private let openButton = NSButton()
    private let restartButton = NSButton()
    private let stopButton = NSButton()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 268),
            // .titled gives the title bar; .closable and .miniaturizable give the
            // red and yellow buttons. Omitting .resizable disables the green
            // zoom/fullscreen button.
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "DSH Launcher"
        isReleasedWhenClosed = false
        center()
        collectionBehavior.insert(.fullScreenNone)

        buildLayout()
        controller.addObserver { [weak self] in self?.render() }
        render()
    }

    private func buildLayout() {
        let content = NSView(frame: contentRect(forFrameRect: frame))
        contentView = content

        let header = NSTextField(labelWithString: "DSH Launcher")
        header.font = .systemFont(ofSize: 20, weight: .semibold)
        header.frame = NSRect(x: 24, y: 208, width: 320, height: 26)
        content.addSubview(header)

        statusDot.font = .systemFont(ofSize: 15)
        statusDot.frame = NSRect(x: 24, y: 176, width: 20, height: 20)
        content.addSubview(statusDot)

        statusLine.font = .systemFont(ofSize: 14, weight: .medium)
        statusLine.frame = NSRect(x: 46, y: 176, width: 300, height: 20)
        content.addSubview(statusLine)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.frame = NSRect(x: 418, y: 176, width: 16, height: 16)
        content.addSubview(spinner)

        detailLine.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detailLine.textColor = .secondaryLabelColor
        detailLine.lineBreakMode = .byTruncatingTail
        detailLine.frame = NSRect(x: 46, y: 152, width: 396, height: 16)
        content.addSubview(detailLine)

        func style(_ b: NSButton, _ title: String, _ x: CGFloat, _ w: CGFloat, key: String = "") {
            b.title = title
            b.bezelStyle = .rounded
            b.frame = NSRect(x: x, y: 88, width: w, height: 32)
            b.target = self
            b.keyEquivalent = key
            content.addSubview(b)
        }

        style(startButton, "Start Server", 24, 200, key: "\r")
        startButton.action = #selector(startTapped)
        style(openButton, "Open in Browser", 24, 190, key: "\r")
        openButton.action = #selector(openTapped)
        style(restartButton, "Restart", 222, 106)
        restartButton.action = #selector(restartTapped)
        style(stopButton, "Stop Server", 336, 110)
        stopButton.action = #selector(stopTapped)

        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 24, y: 34, width: 420, height: 14)
        hint.lineBreakMode = .byTruncatingMiddle
        content.addSubview(hint)
    }

    func render() {
        let c = controller
        let running = c.isRunning

        statusDot.stringValue = c.busy ? "🟡" : (running ? "🟢" : "⚪️")
        statusLine.stringValue = c.statusText
        detailLine.stringValue = c.detailText
        hint.stringValue = "Port \(c.config.port) · \(c.config.logFile)"

        c.busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)

        startButton.isHidden = running
        openButton.isHidden = !running
        restartButton.isHidden = !running
        stopButton.isHidden = !running
        for b in [startButton, openButton, restartButton, stopButton] { b.isEnabled = !c.busy }
        startButton.isEnabled = !c.busy && c.config.repoExists
    }

    @objc private func openTapped()    { controller.openBrowser() }
    @objc private func startTapped()   { controller.start() }
    @objc private func restartTapped() { controller.restart() }
    @objc private func stopTapped()    { controller.stop() }

    @objc func showPreferences() { PreferencesPanel.show(controller: controller) }
    @objc func openLog()         { controller.openLog() }
}

// MARK: - Preferences

enum PreferencesPanel {
    static func show(controller: LauncherController) {
        NSApp.activate(ignoringOtherApps: true)
        let config = controller.config

        let alert = NSAlert()
        alert.messageText = "Preferences"
        alert.informativeText = "Settings are stored in:\n\(Config.configURL.path)"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reveal Config File")

        let form = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 132))
        func field(_ label: String, _ value: String, _ y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: label)
            l.font = .systemFont(ofSize: 11)
            l.alignment = .right
            l.frame = NSRect(x: 0, y: y + 3, width: 76, height: 16)
            form.addSubview(l)
            let f = NSTextField(string: value)
            f.frame = NSRect(x: 84, y: y, width: 292, height: 22)
            f.font = .systemFont(ofSize: 11)
            form.addSubview(f)
            return f
        }
        let repoField    = field("Project:", config.repo, 106)
        let commandField = field("Command:", config.command, 78)
        let portField    = field("Port:", config.port, 50)
        let browserField = field("Browser:", config.browser, 22)
        let note = NSTextField(labelWithString: "Use {port} in the command. Empty browser = system default.")
        note.font = .systemFont(ofSize: 9)
        note.textColor = .tertiaryLabelColor
        note.frame = NSRect(x: 84, y: 2, width: 292, height: 14)
        form.addSubview(note)
        alert.accessoryView = form

        let response = alert.runModal()
        if response == .alertThirdButtonReturn {
            controller.config.save()
            NSWorkspace.shared.activateFileViewerSelecting([Config.configURL])
            return
        }
        guard response == .alertFirstButtonReturn else { return }

        var updated = controller.config
        updated.repo = repoField.stringValue.trimmingCharacters(in: .whitespaces)
        updated.command = commandField.stringValue.trimmingCharacters(in: .whitespaces)
        updated.port = portField.stringValue.trimmingCharacters(in: .whitespaces)
        updated.browser = browserField.stringValue.trimmingCharacters(in: .whitespaces)
        updated.save()
        controller.config = updated
        controller.refresh()
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let controller = LauncherController.shared
    private var statusItem: NSStatusItem!
    private var window: LauncherWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        controller.addObserver { [weak self] in self?.updateStatusIcon() }
        controller.startPolling()
        updateStatusIcon()
        // Menu bar utility: no Dock icon, no window on launch. The status item
        // is the app. (LSUIElement in Info.plist does the same at load time;
        // this keeps the behaviour explicit in code too.)
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.image(running: false)
        statusItem.button?.toolTip = "DSH Launcher"
        let menu = NSMenu()
        menu.delegate = self          // rebuild each time it opens
        statusItem.menu = menu
    }

    private func updateStatusIcon() {
        statusItem?.button?.image = StatusIcon.image(running: controller.isRunning)
        statusItem?.button?.toolTip = "DSH Launcher — \(controller.statusText)"
    }

    /// Rebuild the menu on open so it always shows current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        controller.refresh()
        menu.removeAllItems()

        let status = NSMenuItem(title: controller.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if let pid = controller.runningPID {
            let detail = NSMenuItem(title: "PID \(pid)", action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
        }
        menu.addItem(.separator())

        func add(_ title: String, _ selector: Selector, _ key: String = "", enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            item.isEnabled = enabled && !controller.busy
            menu.addItem(item)
        }

        if controller.isRunning {
            add("Open in Browser", #selector(menuOpen), "o")
            add("Restart Server", #selector(menuRestart), "r")
            add("Stop Server…", #selector(menuStop))
        } else {
            add("Start Server", #selector(menuStart), "s", enabled: controller.config.repoExists)
        }

        menu.addItem(.separator())
        add("Show Panel", #selector(menuShowPanel))
        add("Open Log", #selector(menuOpenLog), "l")
        add("Preferences…", #selector(menuPreferences), ",")
        menu.addItem(.separator())
        add("Quit DSH Launcher", #selector(menuQuit), "q")
    }

    @objc private func menuStart()   { controller.start() }
    @objc private func menuOpen()    { controller.openBrowser() }
    @objc private func menuRestart() { controller.restart() }
    @objc private func menuStop()    { controller.stop() }
    @objc private func menuOpenLog() { controller.openLog() }
    @objc private func menuPreferences() { PreferencesPanel.show(controller: controller) }
    @objc private func menuQuit()    { NSApp.terminate(nil) }

    // MARK: Panel

    @objc private func menuShowPanel() {
        if window == nil {
            let w = LauncherWindow()
            w.delegate = self
            window = w
        }
        window?.render()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Closing the panel leaves the app alive in the menu bar; it must NOT quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func windowDidBecomeMain(_ notification: Notification) { controller.refresh() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Start as an accessory (menu bar only, no Dock icon).
app.setActivationPolicy(.accessory)
app.run()
