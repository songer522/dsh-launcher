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

// MARK: - Main window

final class LauncherWindow: NSWindow {
    private var config = Config.load()

    private let statusDot = NSTextField(labelWithString: "")
    private let statusLine = NSTextField(labelWithString: "")
    private let detailLine = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private let startButton = NSButton()
    private let openButton = NSButton()
    private let restartButton = NSButton()
    private let stopButton = NSButton()

    private var busy = false

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
        // Also refuse fullscreen explicitly, so ⌃⌘F does nothing.
        collectionBehavior.insert(.fullScreenNone)

        buildLayout()
        refresh()
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

        let hint = NSTextField(labelWithString: "")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 24, y: 34, width: 420, height: 14)
        hint.stringValue = "Port \(config.port) · \(config.logFile)"
        hint.lineBreakMode = .byTruncatingMiddle
        content.addSubview(hint)
    }

    // MARK: State

    func refresh() {
        guard !busy else { return }
        let pid = Server.listenerPID(port: config.port)
        let running = pid != nil

        statusDot.stringValue = running ? "🟢" : "⚪️"
        statusLine.stringValue = running ? "Running on port \(config.port)" : "Not running"

        if let pid {
            detailLine.stringValue = "PID \(pid) · \(Server.describe(pid: pid))"
        } else if !config.repoExists {
            detailLine.stringValue = "⚠︎ Project folder not found — see Preferences"
        } else {
            detailLine.stringValue = "Press Start to launch the server."
        }

        startButton.isHidden = running
        openButton.isHidden = !running
        restartButton.isHidden = !running
        stopButton.isHidden = !running
        startButton.isEnabled = config.repoExists
    }

    private func setBusy(_ value: Bool, _ message: String? = nil) {
        busy = value
        value ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        if let message {
            statusDot.stringValue = "🟡"
            statusLine.stringValue = message
            detailLine.stringValue = ""
        }
        for b in [startButton, openButton, restartButton, stopButton] { b.isEnabled = !value }
    }

    // MARK: Actions

    @objc private func openTapped() { Server.openBrowser(config: config) }

    @objc private func startTapped() {
        guard config.repoExists else {
            warn("Project folder not found:\n\(config.repo)",
                 detail: "Set the correct path in Preferences (⌘,).")
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
            DispatchQueue.main.async {
                self.setBusy(false)
                self.refresh()
                if !ready {
                    self.warn("The server did not start in time.",
                              detail: "Check the log:\n\(cfg.logFile)")
                }
            }
        }
    }

    @objc private func restartTapped() {
        guard let pid = Server.listenerPID(port: config.port) else { refresh(); return }
        setBusy(true, "Restarting…")
        let cfg = config
        DispatchQueue.global().async {
            Server.stop(pid: pid, port: cfg.port)
            DispatchQueue.main.async { self.setBusy(false); self.startTapped() }
        }
    }

    @objc private func stopTapped() {
        guard let pid = Server.listenerPID(port: config.port) else { refresh(); return }

        // Explicit confirmation: the server may be hosting live sessions.
        let alert = NSAlert()
        alert.messageText = "Stop the server?"
        alert.informativeText = "PID \(pid) will be terminated.\n"
            + "Anything connected in the browser will disconnect."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop Server")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        setBusy(true, "Stopping…")
        let cfg = config
        DispatchQueue.global().async {
            let ok = Server.stop(pid: pid, port: cfg.port)
            DispatchQueue.main.async {
                self.setBusy(false)
                self.refresh()
                if !ok { self.warn("Could not stop PID \(pid).", detail: "Try again, or stop it from a terminal.") }
            }
        }
    }

    // MARK: Preferences

    @objc func showPreferences() {
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
            config.save()   // ensure it exists before revealing
            NSWorkspace.shared.activateFileViewerSelecting([Config.configURL])
            return
        }
        guard response == .alertFirstButtonReturn else { return }

        config.repo = repoField.stringValue.trimmingCharacters(in: .whitespaces)
        config.command = commandField.stringValue.trimmingCharacters(in: .whitespaces)
        config.port = portField.stringValue.trimmingCharacters(in: .whitespaces)
        config.browser = browserField.stringValue.trimmingCharacters(in: .whitespaces)
        config.save()
        refresh()
    }

    @objc func openLog() {
        if !FileManager.default.fileExists(atPath: config.logFile) {
            FileManager.default.createFile(atPath: config.logFile, contents: Data())
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: config.logFile))
    }

    private func warn(_ text: String, detail: String) {
        let a = NSAlert()
        a.messageText = text
        a.informativeText = detail
        a.alertStyle = .warning
        a.runModal()
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: LauncherWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        window = LauncherWindow()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Minimal menu bar: without one, ⌘Q and ⌘, do not work.
    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()

        appMenu.addItem(withTitle: "Preferences…",
                        action: #selector(LauncherWindow.showPreferences),
                        keyEquivalent: ",")
        appMenu.addItem(withTitle: "Open Log",
                        action: #selector(LauncherWindow.openLog),
                        keyEquivalent: "l")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DSH Launcher",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    // Closing the panel quits the launcher; the server keeps running because it
    // was started detached. Stopping is always explicit.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    // Re-check state on focus, so status is never stale after changes made
    // elsewhere (a terminal, another launcher instance).
    func windowDidBecomeMain(_ notification: Notification) { window.refresh() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
