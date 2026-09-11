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

    /// Directories to prepend to PATH for spawned servers.
    ///
    /// Resolving `pnpm` is not enough: pnpm execs `node`, and node execs more
    /// tools, so the whole chain needs the toolchain directory on PATH. This
    /// includes the directory each located tool actually came from, plus a
    /// login-shell PATH when one can be read.
    static var binDirectories: [String] {
        var dirs: [String] = []
        for tool in ["pnpm", "npm", "node", "yarn", "bun"] {
            if let path = which(tool) {
                let dir = (path as NSString).deletingLastPathComponent
                if !dir.isEmpty && !dirs.contains(dir) { dirs.append(dir) }
            }
        }
        // A login+interactive shell reads the user's rc files, so it sees
        // version managers (nvm, volta, asdf) that fixed paths would miss.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellPath = Shell.run("\(shell) -lic 'printf %s \"$PATH\"' 2>/dev/null")
        for dir in shellPath.split(separator: ":").map(String.init) where !dir.isEmpty {
            if !dirs.contains(dir) { dirs.append(dir) }
        }
        return dirs
    }
}

// MARK: - Shell

enum Shell {
    /// Run a command and return its stdout.
    ///
    /// Only for commands that **exit on their own** — `lsof`, `ps`, `kill`,
    /// `open`. Reading to end-of-file waits for the write end of the pipe to
    /// close, and every process holding that descriptor must exit first. Use
    /// `launch` for anything that leaves a process behind.
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

    /// Start a command that outlives this call, capturing nothing.
    ///
    /// `run` cannot do this. It reads the child's stdout to EOF, and EOF
    /// arrives only when *every* holder of that pipe's write end has closed
    /// it — including the long-lived server the command backgrounds, which
    /// inherits the descriptor. The `sh` we spawned exits immediately, but the
    /// read blocks for as long as the server runs, so `run` would return only
    /// when the server stops. That deadlock is what pinned the UI on
    /// "Starting…" forever: the code after the launch never executed.
    ///
    /// Giving the child no pipes at all removes the descriptor to wait on. The
    /// command redirects its own output to the log file, so nothing is lost.
    static func launch(_ command: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        // Not a Pipe: /dev/null is a plain file, so no descriptor of ours
        // survives into the server, and there is nothing to read to EOF.
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { return }
        // Reap the short-lived `sh` so it does not linger as a zombie. It exits
        // as soon as it has backgrounded the server, so this does not wait on
        // the server itself.
        task.waitUntilExit()
    }
}

// MARK: - Localization

/// The languages the interface is available in.
///
/// `system` follows macOS: the app is Chinese when the system's preferred
/// language is Chinese, English otherwise. The two explicit cases let someone
/// run the app in one language while the rest of the system is in another,
/// which is common enough among developers to be worth the switch.
enum Language: String, Codable, CaseIterable {
    case system
    case english = "en"
    case chinese = "zh-Hans"

    /// The language actually used for rendering, with `system` resolved.
    var effective: Language {
        guard self == .system else { return self }
        // `preferredLanguages` is ordered by the user's own ranking, so the
        // first Chinese entry ahead of any other match is the honest answer.
        // Matching the prefix covers zh-Hans, zh-Hans-CN, zh-CN and friends.
        for code in Locale.preferredLanguages {
            if code.hasPrefix("zh") { return .chinese }
            if code.hasPrefix("en") { return .english }
        }
        return .english
    }

    /// Name shown in the Preferences picker, in the language it selects — a
    /// language list nobody can read is not a language list.
    var displayName: String {
        switch self {
        case .system:  return L.t("System", "跟随系统")
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }
}

/// The string table.
///
/// Two languages and a few dozen strings do not justify `.lproj` bundles and
/// `NSLocalizedString`: those would split the text away from the code that
/// uses it, and this app is deliberately one file that builds with a bare
/// `swiftc` call. `L.t(en, zh)` keeps both readings on the same line, where a
/// missing translation is visible rather than a silent fallback at runtime.
enum L {
    /// The language currently rendering. Set from config at startup and
    /// whenever Preferences is saved.
    static var current: Language = .system

    /// Pick one of the two readings for the active language.
    static func t(_ en: String, _ zh: String) -> String {
        current.effective == .chinese ? zh : en
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
    /// Interface language. Optional in the JSON: a config file written by an
    /// older build has no such key, and must keep loading rather than being
    /// discarded for it — which `JSONDecoder` would otherwise do, silently
    /// resetting every one of the user's settings to defaults.
    ///
    /// An unrecognized value decodes to nil rather than failing, for the same
    /// reason: this file is documented as hand-editable, and a typo here
    /// (`zh`, `chinese`) should cost the user their language preference, not
    /// their project path, port and browser. See `init(from:)`.
    var language: Language?

    private enum CodingKeys: String, CodingKey {
        case repo, command, port, browser, logFile, language
    }

    /// Decode with a tolerant `language`.
    ///
    /// Spelled out rather than left to the synthesized initializer, which
    /// treats a present-but-invalid enum value as a hard failure and takes the
    /// whole file down with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repo = try container.decode(String.self, forKey: .repo)
        command = try container.decode(String.self, forKey: .command)
        port = try container.decode(String.self, forKey: .port)
        browser = try container.decode(String.self, forKey: .browser)
        logFile = try container.decode(String.self, forKey: .logFile)
        language = try? container.decodeIfPresent(Language.self, forKey: .language)
    }

    /// Memberwise initializer, restored: writing `init(from:)` suppresses it.
    init(repo: String, command: String, port: String, browser: String, logFile: String, language: Language?) {
        self.repo = repo
        self.command = command
        self.port = port
        self.browser = browser
        self.logFile = logFile
        self.language = language
    }

    static let configURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/dsh-launcher/config.json")

    /// Where the companion Host plugin publishes the running server's port,
    /// PID and tokenized URL. Written by `index.js` in this repository; absent
    /// when the plugin is not installed or the server is not running.
    ///
    /// This is the plugin's default path, so the two halves agree without any
    /// configuration. A user who moves it in `cordis.patch.yml` falls back to
    /// log parsing, which is the behaviour they had before the plugin existed.
    static let runtimeURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/dsh-launcher/runtime.json")

    static var defaults: Config {
        Config(
            repo: autodetectRepo() ?? NSHomeDirectory(),
            command: "pnpm dsh web --no-open --port {port}",
            port: "3080",
            browser: "Google Chrome",
            logFile: NSTemporaryDirectory() + "dsh-web.log",
            language: .system
        )
    }

    /// The language to render in; `system` when the file predates the setting.
    var resolvedLanguage: Language { language ?? .system }

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
        let command = config.resolvedCommand.replacingOccurrences(of: "'", with: "'\\''")

        // A GUI app inherits no login PATH, and `sh -lc` does not read the
        // user's rc files either — so a toolchain under /opt/homebrew/bin is
        // invisible and the run dies with `env: node: No such file or
        // directory` (pnpm resolves, but the node it execs does not). Prepend
        // the directories where the tools were actually found, so processes
        // spawned further down the chain can see them too.
        let extraPath = Tools.binDirectories.joined(separator: ":")

        // Truncate the log per run: it is parsed below for this run's URL, and
        // stale content would yield a stale (invalid) token.
        //
        // `launch`, not `run`: the server this backgrounds outlives the call,
        // and `run` would wait on a pipe that server keeps open — see
        // Shell.launch for why that hung the UI on "Starting…".
        Shell.launch("cd '\(config.repo)' && "
            + "PATH='\(extraPath)':\"$PATH\" /usr/bin/nohup /bin/sh -c '\(command)' "
            + "> '\(log)' 2>&1 &")
    }

    /// The tokenized URL as reported by the server itself.
    ///
    /// The companion Host plugin (`dsh-menubar-launcher`, this repository's
    /// `index.js`) runs inside the harness and writes its port, PID and
    /// tokenized URL to `~/.config/dsh-launcher/runtime.json` on startup,
    /// removing the file on shutdown. That is a far better source than the log:
    /// it is correct even for a server this app did not start, which is exactly
    /// the case log-scraping cannot serve.
    ///
    /// Returns nil when the plugin is not installed, the file is stale, or its
    /// schema version is one this build does not understand.
    ///
    /// - Parameter expectedPID: the PID currently listening on the port, or nil
    ///   when nothing is. A descriptor describes a *running* server, so both a
    ///   missing listener and a differing one mean the file is left over from a
    ///   process that is gone and its token is dead.
    ///
    /// The plugin deletes the file on shutdown, which covers the ordinary case.
    /// It cannot cover `kill -9`, so the listening PID — not the file's
    /// existence — is what decides. Being strict here is cheap: a rejected
    /// descriptor merely falls back to log parsing, whereas accepting a stale
    /// one opens a tab that answers 401.
    static func descriptorURL(config: Config, expectedPID: String?) -> String? {
        // No listener means no running server, whatever the file claims.
        guard let expectedPID else { return nil }

        guard let data = try? Data(contentsOf: Config.runtimeURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // An unknown schema version means the file was written by a newer
        // plugin whose fields this build cannot be trusted to read.
        guard let version = object["version"] as? Int, version == 1 else { return nil }

        // A descriptor is only about the server this app is managing. A file
        // describing a harness on another port must not be used.
        guard let port = object["port"] as? Int, String(port) == config.port else { return nil }

        // The decisive staleness check: the process that wrote this file must
        // be the one holding the port right now.
        guard let pid = object["pid"] as? Int, String(pid) == expectedPID else { return nil }

        guard let url = object["authenticatedUrl"] as? String, !url.isEmpty else { return nil }
        return url
    }

    /// The URL to open, including its authentication token.
    ///
    /// DSH mints a per-process launch token and prints
    /// `dsh web: http://127.0.0.1:PORT/?token=…`. Opening the bare origin
    /// returns HTTP 401, so the token has to be carried across.
    ///
    /// Two sources, in order of trustworthiness:
    ///   1. the runtime descriptor written by the companion Host plugin — works
    ///      for any server, however it was started;
    ///   2. this run's log file — the original mechanism, kept as a fallback so
    ///      the app still works without the plugin installed.
    ///
    /// Returns nil when neither yields a tokenized URL.
    static func authenticatedURL(config: Config) -> String? {
        if let fromPlugin = descriptorURL(config: config, expectedPID: listenerPID(port: config.port)) {
            return fromPlugin
        }
        guard let text = try? String(contentsOfFile: config.logFile, encoding: .utf8) else { return nil }
        // Exclude ) ] > and quotes from the token: DSH prints the LAN variant in
        // parentheses — `… (LAN: http://…?token=…)` — and a greedy class would
        // swallow the closing bracket and produce an invalid token.
        let pattern = #"https?://[^\s'"()\[\]<>]*[?&]token=[^\s'"()\[\]<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let urls = matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        guard !urls.isEmpty else { return nil }

        // Prefer a loopback URL. DSH prints the LAN address on the same line,
        // and the last match would otherwise be the LAN one — which may be
        // unreachable, and needlessly exposes the token to the network.
        let loopback = urls.last { url in
            url.contains("127.0.0.1") || url.contains("localhost") || url.contains("[::1]")
        }
        return loopback ?? urls.last
    }

    /// Whatever the run printed, for surfacing a failure to the user.
    static func logTail(config: Config, lines: Int = 6) -> String {
        guard let text = try? String(contentsOfFile: config.logFile, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    /// Does this line open an error report, rather than merely mention one?
    ///
    /// Anchored on purpose. The line that *throws* (`throw new Error(...)`) and
    /// the frames below it both contain the word, but only the reported error
    /// begins with it — matching loosely lands on the throw site and spends the
    /// excerpt on source context instead of the message.
    static func opensAnError(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.range(of: "^[A-Za-z]*(Error|Exception)\\b", options: .regularExpression) != nil { return true }
        let lower = t.lowercased()
        return ["error:", "fatal", "failed to", "err!", "panic:", "uncaught "]
            .contains { lower.hasPrefix($0) }
    }

    /// The first error in the log, plus a little context — the part worth
    /// showing when a run fails.
    ///
    /// A Node crash dump ends in closing braces, an `AggregateError` tail and a
    /// version banner, so the *last* few lines of a failed run say nothing at
    /// all. The single line that names the cause sits at the top, often
    /// hundreds of lines up, with the detail (which packages, which paths)
    /// indented beneath it. Falls back to the tail for a log with no
    /// recognisable error — a server that hung rather than threw, where the
    /// most recent output really is the informative part.
    static func logExcerpt(config: Config, lines: Int = 6) -> String {
        guard let text = try? String(contentsOfFile: config.logFile, encoding: .utf8) else { return "" }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = all.firstIndex(where: opensAnError) else {
            return logTail(config: config, lines: lines)
        }
        return all[start..<min(start + lines, all.count)].joined(separator: "\n")
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

    /// What a start attempt actually did, read off the port's owner before and
    /// after the launch.
    enum StartOutcome {
        case started            // a new PID owns the port
        case portTaken          // the incumbent still owns it; we never bound
        case diedAfterBinding   // we bound, then the process exited
        case neverBound         // the port never opened at all
    }

    /// Kept pure so the truth table can be exercised without launching a server.
    ///
    /// The subtle case is `after == nil` *after* the port was seen open: that is
    /// our own server binding and then dying during startup (a failed plugin
    /// load, say), not a collision. Reporting it as "another server is already
    /// on the port" sends people hunting for a process that was never there,
    /// and hides the real error sitting in the log. Note that a collision is
    /// impossible by definition when `before` is nil.
    static func startOutcome(before: String?, after: String?, everListened: Bool) -> StartOutcome {
        guard everListened else { return .neverBound }
        guard let after else { return .diedAfterBinding }
        return after == before ? .portTaken : .started
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

    /// Open the running server in the configured browser.
    ///
    /// Prefers the tokenized URL this run printed: DSH mints a per-process
    /// launch token, and the bare origin answers 401, which shows up as a blank
    /// or "unauthorized" tab. Falls back to the plain URL for servers that
    /// print no token (a plain Vite dev server, say).
    static func openBrowser(config: Config) {
        let target = authenticatedURL(config: config) ?? config.url
        let app = config.browser.replacingOccurrences(of: "'", with: "'\\''")
        let quotedURL = "'" + target.replacingOccurrences(of: "'", with: "'\\''") + "'"
        if app.isEmpty {
            Shell.run("\(Tools.open) \(quotedURL)")            // system default
        } else {
            Shell.run("\(Tools.open) -a '\(app)' \(quotedURL)")
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

    /// Adopt the saved language before anything renders.
    ///
    /// This runs when `shared` is first touched, which is during
    /// `applicationDidFinishLaunching` — before the status item, its menu, or
    /// the panel exist. Doing it later would build the first menu in the wrong
    /// language and only correct it on the next open.
    private init() {
        L.current = config.resolvedLanguage
    }

    private(set) var runningPID: String?
    private(set) var busy = false
    private(set) var busyMessage = ""

    /// Observers notified whenever state changes (menu + window redraw).
    private var observers: [() -> Void] = []
    private var pollTimer: Timer?

    func addObserver(_ block: @escaping () -> Void) { observers.append(block) }

    /// Views that must rebuild their static text when the language changes.
    ///
    /// Separate from `addObserver`: state observers fire several times a second
    /// while polling, and re-setting every button title on each tick would be
    /// wasted work. The menu bar needs no entry here — it is rebuilt from
    /// scratch each time it opens, so it picks the new language up by itself.
    private var relabelers: [() -> Void] = []
    func addRelabeler(_ block: @escaping () -> Void) { relabelers.append(block) }

    /// Re-render fixed titles after a language change.
    func relabel() {
        DispatchQueue.main.async { self.relabelers.forEach { $0() } }
    }

    private func notify() {
        DispatchQueue.main.async { self.observers.forEach { $0() } }
    }

    var isRunning: Bool { runningPID != nil }

    var statusText: String {
        if busy { return busyMessage }
        return isRunning
            ? L.t("Running on port \(config.port)", "正在端口 \(config.port) 上运行")
            : L.t("Not running", "未运行")
    }

    var detailText: String {
        if busy { return "" }
        if let pid = runningPID { return "PID \(pid) · \(Server.describe(pid: pid))" }
        if !config.repoExists {
            return L.t("⚠︎ Project folder not found — see Preferences",
                       "⚠︎ 未找到项目目录 —— 请查看偏好设置")
        }
        return L.t("Press Start to launch the server.", "点击“启动”来运行服务器。")
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
            Alerts.warn(L.t("Project folder not found:\n\(config.repo)", "未找到项目目录：\n\(config.repo)"),
                        detail: L.t("Set the correct path in Preferences (⌘,).", "请在偏好设置（⌘,）中填写正确的路径。"))
            completion?(false)
            return
        }
        setBusy(true, L.t("Starting…", "正在启动…"))
        let cfg = config
        // Who was already on the port? If the same PID is still there after our
        // launch, our instance failed to bind (EADDRINUSE) and "the port is
        // open" is a false positive — the state machine would otherwise sit in
        // "Starting…" forever.
        let beforePID = Server.listenerPID(port: cfg.port)
        DispatchQueue.global().async {
            Server.start(config: cfg)
            let everListened = Server.waitUntilReady(port: cfg.port)
            var afterPID: String? = nil
            if everListened {
                Thread.sleep(forTimeInterval: 1.0)   // let it finish binding + print
                afterPID = Server.listenerPID(port: cfg.port)
            }
            let outcome = Server.startOutcome(before: beforePID,
                                              after: afterPID,
                                              everListened: everListened)
            let actuallyStarted = outcome == .started
            self.refresh()
            let tail = actuallyStarted ? "" : Server.logExcerpt(config: cfg)
            let openIt = actuallyStarted
            DispatchQueue.main.async {
                self.setBusy(false)
                self.refresh()
                if outcome == .portTaken {
                    // Never throw away someone else's running server: reuse it,
                    // and say so instead of pretending we started ours.
                    // `beforePID` is non-nil here: .portTaken requires it.
                    let detail = tail.isEmpty
                        ? L.t("Another server is already on port \(cfg.port) (PID \(beforePID ?? "?")).\n\nFull log: \(cfg.logFile)", "端口 \(cfg.port) 上已有另一个服务器（PID \(beforePID ?? "?")）。\n\n完整日志：\(cfg.logFile)")
                        : L.t("\(tail)\n\nAnother server is already on port \(cfg.port). It is left running.", "\(tail)\n\n端口 \(cfg.port) 上已有另一个服务器，它会继续运行。")
                    Alerts.warn(L.t("Port \(cfg.port) is already in use.", "端口 \(cfg.port) 已被占用。"), detail: detail)
                } else if !actuallyStarted {
                    // Show what the server actually printed. A bare "timed out"
                    // hides the real cause, which is usually one clear line
                    // (a missing toolchain, a port clash, a bad command).
                    let detail = tail.isEmpty
                        ? L.t("Nothing was logged.\nCheck: \(cfg.logFile)", "没有任何日志输出。\n请检查：\(cfg.logFile)")
                        : L.t("\(tail)\n\nFull log: \(cfg.logFile)", "\(tail)\n\n完整日志：\(cfg.logFile)")
                    // Separate headline for a server that bound the port and
                    // then exited: "did not start" reads like it never ran, and
                    // the port is already free again by the time this shows.
                    let title = outcome == .diedAfterBinding
                        ? L.t("The server started, then exited.", "服务器启动后随即退出。")
                        : L.t("The server did not start.", "服务器未能启动。")
                    Alerts.warn(title, detail: detail)
                }
                completion?(actuallyStarted)
                // Launch the browser after the UI has settled, off the main
                // thread: it spawns processes and can take a moment.
                if openIt {
                    DispatchQueue.global().async {
                        Thread.sleep(forTimeInterval: 0.4)   // token already flushed
                        Server.openBrowser(config: cfg)
                    }
                }
            }
        }
    }

    func restart() {
        guard let pid = runningPID ?? Server.listenerPID(port: config.port) else { refresh(); return }
        setBusy(true, L.t("Restarting…", "正在重启…"))
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
            alert.messageText = L.t("Stop the server?", "要停止服务器吗？")
            alert.informativeText = L.t("PID \(pid) will be terminated.\n", "将终止进程 PID \(pid)。\n")
                + L.t("Anything connected in the browser will disconnect.", "浏览器中所有已连接的会话都会断开。")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L.t("Stop Server", "停止服务器"))
            alert.addButton(withTitle: L.t("Cancel", "取消"))
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        setBusy(true, L.t("Stopping…", "正在停止…"))
        let cfg = config
        DispatchQueue.global().async {
            let ok = Server.stop(pid: pid, port: cfg.port)
            self.refresh()
            DispatchQueue.main.async {
                self.setBusy(false)
                self.refresh()
                if !ok {
                    Alerts.warn(L.t("Could not stop PID \(pid).", "无法停止进程 PID \(pid)。"),
                                detail: L.t("Try again, or stop it from a terminal.", "请重试，或从终端手动停止。"))
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
    /// The DeepSeek whale, as SVG path data (viewBox 0 0 50 50).
    /// Drawn natively rather than shipped as a bitmap so it stays crisp at any
    /// menu bar size and on any display scale.
    private static let whalePath =
        "M48.8354 10.0479C48.3232 9.79199 48.1025 10.2798 47.8032 10.5278C47.7007 10.6079 47.6143 1" +
        "0.7119 47.5273 10.8076C46.7793 11.624 45.9048 12.1597 44.7622 12.0957C43.0923 12 41.666 12" +
        ".5356 40.4058 13.8398C40.1377 12.2319 39.2476 11.272 37.8926 10.6558C37.1836 10.3359 36.46" +
        "68 10.0156 35.9702 9.31982C35.6235 8.82373 35.5293 8.27197 35.356 7.72754C35.2456 7.3999 3" +
        "5.1353 7.06396 34.7651 7.00781C34.3633 6.94385 34.2056 7.2876 34.0479 7.57568C33.418 8.751" +
        "95 33.1733 10.0479 33.1973 11.3599C33.2524 14.312 34.4736 16.6641 36.8999 18.3359C37.1758 " +
        "18.5278 37.2466 18.7197 37.1597 19C36.9946 19.5757 36.7974 20.1357 36.624 20.7119C36.5137 " +
        "21.0801 36.3486 21.1597 35.9624 21C34.6309 20.4321 33.481 19.5918 32.4644 18.5757C30.7393 " +
        "16.8721 29.1792 14.9917 27.2334 13.52C26.7764 13.1758 26.3193 12.856 25.8467 12.5518C23.86" +
        "18 10.584 26.1069 8.96777 26.627 8.77588C27.1704 8.57568 26.8159 7.8877 25.0591 7.896C23.3" +
        "022 7.90381 21.6953 8.50391 19.647 9.30371C19.3477 9.42383 19.0322 9.51172 18.7095 9.58398" +
        "C16.8501 9.22363 14.9199 9.14355 12.9033 9.37598C9.10596 9.80762 6.07275 11.6396 3.84326 1" +
        "4.7681C1.16455 18.5278 0.53418 22.7998 1.30664 27.2559C2.11768 31.9521 4.46582 35.8398 8.0" +
        "7373 38.8799C11.8159 42.0322 16.1255 43.5762 21.041 43.2803C24.0269 43.104 27.3516 42.6963" +
        " 31.1016 39.4561C32.0469 39.936 33.0396 40.1279 34.686 40.272C35.9546 40.3921 37.1758 40.2" +
        "08 38.1211 40.0078C39.6021 39.688 39.4995 38.2881 38.9639 38.0322C34.623 35.9678 35.5762 3" +
        "6.8081 34.71 36.1279C36.9155 33.4639 40.2402 30.6958 41.54 21.728C41.6426 21.0161 41.5557 " +
        "20.5679 41.54 19.9917C41.5322 19.6396 41.6108 19.5039 42.0049 19.4639C43.0923 19.3359 44.1" +
        "479 19.0317 45.1167 18.4878C47.9292 16.9199 49.064 14.3438 49.3315 11.2559C49.3711 10.7837" +
        " 49.3237 10.2959 48.8354 10.0479ZM24.3262 37.8398C20.1196 34.4639 18.0791 33.3521 17.2358 " +
        "33.3999C16.4482 33.4482 16.5898 34.3682 16.7632 34.9678C16.9443 35.5601 17.1812 35.9683 17" +
        ".5117 36.4878C17.7402 36.832 17.8979 37.3442 17.2832 37.728C15.9282 38.584 13.5728 37.4399" +
        " 13.4624 37.3838C10.7207 35.7358 8.42822 33.5601 6.81348 30.584C5.25342 27.7197 4.34766 24" +
        ".6479 4.19775 21.3677C4.1582 20.5757 4.38672 20.2959 5.15869 20.1519C6.17529 19.96 7.22314" +
        " 19.9199 8.23926 20.0718C12.5327 20.7119 16.1885 22.6719 19.2529 25.7759C21.002 27.5439 22" +
        ".3252 29.6558 23.6885 31.7202C25.1377 33.9121 26.6978 36 28.6831 37.7119C29.3843 38.312 29" +
        ".9434 38.7681 30.479 39.104C28.8643 39.2881 26.1699 39.3281 24.3262 37.8398ZM26.3433 24.60" +
        "01C26.3433 24.248 26.6191 23.9678 26.9658 23.9678C27.0444 23.9678 27.1152 23.9839 27.1782 " +
        "24.0078C27.2651 24.04 27.3438 24.0879 27.4067 24.1602C27.5171 24.272 27.5801 24.4321 27.58" +
        "01 24.6001C27.5801 24.9521 27.3042 25.2319 26.9575 25.2319C26.6108 25.2319 26.3433 24.9521" +
        " 26.3433 24.6001ZM32.6064 27.8799C32.2046 28.0479 31.8027 28.1919 31.4165 28.208C30.8179 2" +
        "8.2397 30.1641 27.9922 29.8096 27.688C29.2583 27.2158 28.8643 26.9521 28.6987 26.1279C28.6" +
        "279 25.7759 28.6675 25.2319 28.7305 24.9199C28.8721 24.248 28.7144 23.8159 28.2495 23.4238" +
        "C27.8716 23.104 27.3911 23.0161 26.8633 23.0161C26.666 23.0161 26.4849 22.9277 26.3511 22." +
        "856C26.1304 22.7441 25.9492 22.4639 26.1226 22.1201C26.1777 22.0078 26.4458 21.7358 26.508" +
        "8 21.688C27.2256 21.272 28.0527 21.4077 28.8169 21.7197C29.5259 22.0161 30.0615 22.5601 30" +
        ".834 23.3281C31.6216 24.2559 31.7632 24.5117 32.2124 25.208C32.5669 25.752 32.8901 26.312 " +
        "33.1104 26.9521C33.2446 27.3521 33.0713 27.6802 32.6064 27.8799Z"

    /// Minimal SVG path parser: this data uses only M, C and Z.
    private static func bezierPath(scale: CGFloat, offset: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        var numbers: [CGFloat] = []
        var command: Character = " "
        var current = CGPoint.zero
        var scanner = whalePath[...]

        // SVG y grows downward, AppKit y grows upward -> flip within a 50-unit box.
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: offset.x + x * scale, y: offset.y + (50 - y) * scale)
        }

        func flush() {
            switch command {
            case "M":
                guard numbers.count >= 2 else { break }
                current = point(numbers[0], numbers[1])
                path.move(to: current)
            case "C":
                var i = 0
                while i + 5 < numbers.count {
                    let c1 = point(numbers[i],     numbers[i + 1])
                    let c2 = point(numbers[i + 2], numbers[i + 3])
                    let to = point(numbers[i + 4], numbers[i + 5])
                    path.curve(to: to, controlPoint1: c1, controlPoint2: c2)
                    current = to
                    i += 6
                }
            case "Z":
                path.close()
            default:
                break
            }
            numbers.removeAll(keepingCapacity: true)
        }

        while let ch = scanner.first {
            if ch == "M" || ch == "C" || ch == "Z" {
                flush()
                command = ch
                scanner = scanner.dropFirst()
                if ch == "Z" { flush() }
            } else if ch == "-" || ch == "." || ch.isNumber {
                // Read one number; '-' also terminates the previous one.
                var text = String(ch)
                scanner = scanner.dropFirst()
                while let n = scanner.first, n.isNumber || n == "." || n == "e" || n == "-" {
                    if n == "-" && !text.hasSuffix("e") { break }
                    text.append(n)
                    scanner = scanner.dropFirst()
                }
                if let value = Double(text) { numbers.append(CGFloat(value)) }
            } else {
                scanner = scanner.dropFirst()   // whitespace or comma
            }
        }
        flush()
        return path
    }

    /// Menu bar icon. `running` fills the whale; stopped draws it dimmed, so the
    /// two states differ by weight as well as shape.
    static func image(running: Bool) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let glyph: CGFloat = 16          // whale box inside the 18pt square
            let scale = glyph / 50
            let inset = (side - glyph) / 2
            let path = bezierPath(scale: scale, offset: CGPoint(x: inset, y: inset))

            if running {
                NSColor.black.setFill()
                path.fill()
            } else {
                // Template images are masks, so "grey" must come from alpha.
                NSColor.black.withAlphaComponent(0.45).setFill()
                path.fill()
            }
            return true
        }
        // Template = AppKit tints it for light/dark menu bars and highlight state.
        image.isTemplate = true
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
        controller.addRelabeler { [weak self] in
            self?.applyLabels()
            self?.render()
        }
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

        style(startButton, "", 24, 200, key: "\r")
        startButton.action = #selector(startTapped)
        style(openButton, "", 24, 190, key: "\r")
        openButton.action = #selector(openTapped)
        style(restartButton, "", 222, 106)
        restartButton.action = #selector(restartTapped)
        style(stopButton, "", 336, 110)
        stopButton.action = #selector(stopTapped)
        // Titles come from one place, so a language change re-applies them all.
        applyLabels()

        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 24, y: 34, width: 420, height: 14)
        hint.lineBreakMode = .byTruncatingMiddle
        content.addSubview(hint)
    }

    /// Set every fixed title from the active language. Called once at build
    /// time and again whenever Preferences changes the language.
    func applyLabels() {
        startButton.title   = L.t("Start Server", "启动服务器")
        openButton.title    = L.t("Open in Browser", "在浏览器中打开")
        restartButton.title = L.t("Restart", "重启")
        stopButton.title    = L.t("Stop Server", "停止服务器")
    }

    func render() {
        let c = controller
        let running = c.isRunning

        statusDot.stringValue = c.busy ? "🟡" : (running ? "🟢" : "⚪️")
        statusLine.stringValue = c.statusText
        detailLine.stringValue = c.detailText
        hint.stringValue = L.t("Port \(c.config.port) · \(c.config.logFile)", "端口 \(c.config.port) · \(c.config.logFile)")

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
        alert.messageText = L.t("Preferences", "偏好设置")
        alert.informativeText = L.t("Settings are stored in:\n\(Config.configURL.path)",
                                    "设置保存在：\n\(Config.configURL.path)")
        alert.addButton(withTitle: L.t("Save", "保存"))
        alert.addButton(withTitle: L.t("Cancel", "取消"))
        alert.addButton(withTitle: L.t("Reveal Config File", "在访达中显示配置文件"))

        // One extra row (language) over the previous four-field form.
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 160))
        func label(_ text: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 11)
            l.alignment = .right
            l.frame = NSRect(x: 0, y: y + 3, width: 76, height: 16)
            form.addSubview(l)
        }
        func field(_ text: String, _ value: String, _ y: CGFloat) -> NSTextField {
            label(text, y)
            let f = NSTextField(string: value)
            f.frame = NSRect(x: 84, y: y, width: 292, height: 22)
            f.font = .systemFont(ofSize: 11)
            form.addSubview(f)
            return f
        }
        let repoField    = field(L.t("Project:", "项目目录："), config.repo, 134)
        let commandField = field(L.t("Command:", "启动命令："), config.command, 106)
        let portField    = field(L.t("Port:", "端口："), config.port, 78)
        let browserField = field(L.t("Browser:", "浏览器："), config.browser, 50)

        // Language is a fixed set, so it is a popup rather than a text field:
        // a typo in a free-text locale code is a silently unusable interface.
        label(L.t("Language:", "界面语言："), 22)
        let languagePopup = NSPopUpButton(frame: NSRect(x: 82, y: 20, width: 160, height: 25))
        languagePopup.font = .systemFont(ofSize: 11)
        for language in Language.allCases {
            languagePopup.addItem(withTitle: language.displayName)
        }
        languagePopup.selectItem(at: Language.allCases.firstIndex(of: config.resolvedLanguage) ?? 0)
        form.addSubview(languagePopup)

        let note = NSTextField(labelWithString: L.t(
            "Use {port} in the command. Empty browser = system default.",
            "命令中用 {port} 代表端口。浏览器留空则使用系统默认。"))
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
        let chosen = Language.allCases[max(0, languagePopup.indexOfSelectedItem)]
        updated.language = chosen
        updated.save()
        controller.config = updated
        // Apply immediately. Titles are read when a view renders, so the menu
        // and panel pick the new language up on the refresh below — no relaunch.
        L.current = chosen
        controller.relabel()
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
            add(L.t("Open in Browser", "在浏览器中打开"), #selector(menuOpen), "o")
            add(L.t("Restart Server", "重启服务器"), #selector(menuRestart), "r")
            add(L.t("Stop Server…", "停止服务器…"), #selector(menuStop))
        } else {
            add(L.t("Start Server", "启动服务器"), #selector(menuStart), "s", enabled: controller.config.repoExists)
        }

        menu.addItem(.separator())
        add(L.t("Show Panel", "显示面板"), #selector(menuShowPanel))
        add(L.t("Open Log", "打开日志"), #selector(menuOpenLog), "l")
        add(L.t("Preferences…", "偏好设置…"), #selector(menuPreferences), ",")
        menu.addItem(.separator())
        add(L.t("Quit DSH Launcher", "退出 DSH Launcher"), #selector(menuQuit), "q")
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
