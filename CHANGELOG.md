# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

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

[1.0.0]: https://github.com/songer522/dsh-launcher/releases/tag/v1.0.0
