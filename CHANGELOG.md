# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

## [1.3.0] — 2026-09-08

### Added

- **A companion DSH plugin (`dsh-menubar-launcher`).** The repository is now
  also an installable DSH bundle: `dsh plugin --profile web add
  github:songer522/dsh-launcher`. The plugin runs inside the harness and
  publishes the running server's port, PID and tokenized URL to
  `~/.config/dsh-launcher/runtime.json`, removing the file when the server
  stops. It is written `0600` in a `0700` directory, because that URL carries a
  launch token — a credential.

  It declares no dependencies, so it installs against any harness version and
  needs no `allowBuilds` approval. In a profile with no web server it does
  nothing and the harness boots normally.

### Fixed

- **"Open in Browser" opened a dead tab for a server the app did not start.**
  The tokenized URL was recovered by grepping the app's own log file, which
  only exists for a server the app launched itself. Started from a terminal
  there was nothing to read, so the app fell back to the bare origin — which
  answers HTTP 401.

  The app now prefers the plugin's runtime descriptor and falls back to log
  parsing, so the plugin stays optional and its absence restores the previous
  behaviour. A descriptor is trusted only when the PID it names is the process
  currently listening on the port, so a file left behind by `kill -9` is
  ignored rather than used to open a tab whose token is dead.

## [1.2.1] — 2026-09-08

### Fixed

- **The menu and window stayed on "Starting…" after Start.** Starting on a port
  that was already occupied left the state machine stuck forever. The port check
  (`waitUntilReady`) only tested whether *something* was listening — when the
  new instance died with `EADDRINUSE`, the *old* server satisfied the check, so
  the flow reported success, opened the old server's URL, and never cleared the
  busy state.

  Start now records which PID owned the port before launching and re-checks
  after: if the listener is unchanged, the new instance never won the port. The
  busy state is cleared, the existing server is left running, and an alert says
  the port is already in use (with the failed instance's log shown) instead of
  hanging indefinitely.

- **Browser launch no longer blocks the state update.** Opening Chrome used to
  happen inside the completion path on the main thread; it now runs after the
  UI has settled, on a background thread.

### Changed

- Version bump only; no behavioural change intended beyond the two fixes above.

## [1.2.0] — 2026-09-08

### Fixed

- **Starting the server from the app did nothing.** A GUI app inherits no login
  `PATH`, and the `/bin/sh -lc` wrapper did not read the user's shell rc files
  either, so a Homebrew toolchain was invisible. `pnpm` itself resolved, but the
  `node` it execs did not, and the run died immediately with
  `env: node: No such file or directory` — leaving the app to sit through its
  40-second timeout. The launch now prepends the directories where the tools
  were actually found, plus a login-shell `PATH`, so the whole spawn chain can
  see the toolchain.

- **The opened tab was unauthorized.** DSH mints a per-process launch token and
  prints `dsh web: http://127.0.0.1:PORT/?token=…`; opening the bare origin
  answers **HTTP 401**. The app opened the bare origin, so the tab was dead and
  the URL had to be copied from a terminal by hand. The printed URL is now read
  back from the log and opened with its token. Servers that print no token
  (a plain Vite dev server, say) still fall back to the plain URL.

  The URL is matched excluding brackets and quotes, and loopback is preferred:
  DSH prints the LAN address on the same line inside parentheses, so a greedy
  match would capture a trailing `)` and prefer an address that may be
  unreachable — and would needlessly put the token on the network.

- **Start failures were silent.** A failed start reported only a timeout. The
  alert now shows the last lines the server actually printed, which is normally
  the one line that explains the failure.

### Changed

- The log is truncated at each start, so a parsed URL always belongs to the
  current run rather than a previous one.

## [1.1.1] — 2026-09-08

### Changed

- **Status bar icon is now the DeepSeek whale** rather than a plain circle. The
  glyph is stored as SVG path data and drawn natively with `NSBezierPath`, so it
  stays crisp at any menu bar height and on any display scale — no bitmaps to
  keep in sync. Running renders it solid; stopped renders it dimmed, so the two
  states differ by weight as well as by shape.

  Because template images are masks, the dimmed state comes from alpha rather
  than a grey fill — a grey colour would be flattened back to solid black by the
  template tinting.

## [1.1.0] — 2026-09-08

Reworked from a windowed app into a menu bar utility.

### Added

- **Menu bar status item.** The app now lives in the status bar. The icon is a
  template image (so it tints correctly in light and dark menu bars) and
  reflects state: filled when the server is running, outline when stopped.
- **Dropdown menu** with the full action set — Start / Open in Browser /
  Restart / Stop, plus Show Panel, Open Log, Preferences and Quit — with live
  status and PID shown at the top. The menu is rebuilt on open, so it can never
  display stale state.
- **Background polling** every 3 seconds, so the icon stays correct when the
  server is started or stopped outside the app (from a terminal, say).
- `LauncherController`, a single owner of config and server state shared by the
  menu and the panel, so the two views cannot disagree.

### Changed

- **No Dock icon.** The app runs as an accessory (`LSUIElement` plus
  `.accessory` activation policy), so it no longer appears in the Dock or in
  ⌘Tab. Quit from the menu bar.
- The window is now an optional panel opened via **Show Panel**, not the main
  interface, and no window is shown at launch.
- Closing the panel no longer quits the app; it stays in the menu bar.
  (`applicationShouldTerminateAfterLastWindowClosed` returns `false`.)

## [1.0.0] — 2026-09-08

First standalone release, extracted from a personal `tools/` folder into its
own project.

### Added

- Native AppKit control panel with live server status (PID and command shown).
- Start / Open in Browser / Restart / Stop actions; buttons adapt to state.
- Detached server launch, so quitting the launcher leaves the server running.
- Confirmation prompt before stopping, since a server may host live sessions.
- Preferences (⌘,) writing `~/.config/dsh-launcher/config.json`.
- Project auto-detection across `~/Workspace`, `~/Projects`, `~/Developer`,
  `~/src`, `~/code` and `~`.
- Configurable command with a `{port}` placeholder, so the app is not tied to
  DeepSeek Harness.
- PATH-independent binary resolution, with a login-shell fallback.
- `build.sh` with `--dev` and `--uninstall` modes.
- App icon and menu bar (⌘, preferences, ⌘L log, ⌘Q quit).

### Fixed

- **Traffic-light buttons.** The original AppleScript version used
  `display dialog`, a modal alert with no title bar and therefore no window
  controls. Rewritten as a real `NSWindow`: close and minimize enabled,
  zoom/fullscreen deliberately disabled.
- **Folder icon instead of app icon.** Editing the bundle after code-signing
  invalidated the signature, so macOS stopped treating it as an application.
  `build.sh` now signs last.
- **Custom icon ignored.** `osacompile` emits an `Assets.car` catalog that takes
  priority over `applet.icns`. The Swift build has no asset catalog.
- **Clients killed alongside the server.** Port probing used
  `lsof -ti tcp:PORT`, which also matches processes *connected* to the port —
  Chrome and other apps were in range. All probes now use `-sTCP:LISTEN`, which
  matches only the listening server.

[1.2.1]: https://github.com/songer522/dsh-launcher/releases/tag/v1.2.1
[1.2.0]: https://github.com/songer522/dsh-launcher/releases/tag/v1.2.0
[1.1.1]: https://github.com/songer522/dsh-launcher/releases/tag/v1.1.1
[1.1.0]: https://github.com/songer522/dsh-launcher/releases/tag/v1.1.0
[1.0.0]: https://github.com/songer522/dsh-launcher/releases/tag/v1.0.0
