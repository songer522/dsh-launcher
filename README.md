# DSH Launcher

A tiny macOS **menu bar** utility for a local development server: start it,
open it in your browser, restart it, or stop it — without touching a terminal.

It lives in the status bar with no Dock icon, so it stays out of your way.

Written for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(`pnpm dsh web`), but the command, port, project folder and browser are all
configurable, so it works for any long-running local server.

Native AppKit, single Swift file, **no dependencies**.

### Menu bar

The status icon is the DeepSeek whale, drawn as a template image so macOS
tints it for light and dark menu bars. It shows server state at a glance —
**solid** when running, **dimmed** when stopped — and everything is one click
away:

```
  🐳 ← status icon (solid = running, dimmed = stopped)
  ┌────────────────────────┐
  │ Running on port 3080   │
  │ PID 98948              │
  ├────────────────────────┤
  │ Open in Browser    ⌘O  │
  │ Restart Server     ⌘R  │
  │ Stop Server…           │
  ├────────────────────────┤
  │ Show Panel             │
  │ Open Log           ⌘L  │
  │ Preferences…       ⌘,  │
  ├────────────────────────┤
  │ Quit DSH Launcher  ⌘Q  │
  └────────────────────────┘
```

When the server is stopped, the menu shows **Start Server** instead.

State is polled every 3 seconds, so the icon stays correct even when you start
or stop the server from a terminal.

### Panel (optional)

**Show Panel** opens a small window with the same actions:

```
  ● ● ●   DSH Launcher

  🟢 Running on port 3080
     PID 98948 · node --import tsx/esm apps/cli/src/bin.ts web

  [ Open in Browser ]   [ Restart ]   [ Stop Server ]
```

Closing the panel does **not** quit the app — it stays in the menu bar.

## Install

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/songer522/dsh-launcher.git
cd dsh-launcher
./build.sh
```

That compiles, bundles, signs, and installs to `/Applications`.

```sh
./build.sh --dev        # build into ./build without installing
./build.sh --uninstall  # remove the installed app
```

## Configuration

On first run the app looks for a DeepSeek Harness checkout in the usual places
(`~/Workspace`, `~/Projects`, `~/Developer`, `~/src`, `~/code`, `~`). If your
project lives elsewhere, or you want to launch something entirely different,
open **Preferences** (⌘,).

Settings are stored as JSON at `~/.config/dsh-launcher/config.json`:

```json
{
  "repo": "/Users/you/Workspace/deepseek-harness",
  "command": "pnpm dsh web --no-open --port {port}",
  "port": "3080",
  "browser": "Google Chrome",
  "logFile": "/tmp/dsh-web.log"
}
```

| Field | Meaning |
|---|---|
| `repo` | working directory the command runs in |
| `command` | the launch command; `{port}` is substituted |
| `port` | the port to watch, and to substitute into the command |
| `browser` | app name to open, or `""` for the system default |
| `logFile` | where the server's stdout/stderr is written |

Because it is just a command in a directory, it happily runs `npm run dev`,
`vite`, `python -m http.server`, or anything else.

### Why a launch flag matters

The stock command uses `--no-open` because DSH otherwise opens the URL in the
**system default browser**. Suppressing that and opening the browser here is
what lets you use Chrome while Safari remains your system default.

## Window behaviour

The app is a menu bar utility (`LSUIElement`), so it has **no Dock icon** and no
⌘Tab entry. Quit it from the menu bar.

For the optional panel:

| Control | State |
|---|---|
| Close (red) | enabled — hides the panel; app stays in the menu bar |
| Minimize (yellow) | enabled |
| Zoom / fullscreen (green) | disabled — fixed-size panel |

Fullscreen is suppressed both by omitting `.resizable` from the window's
`styleMask` and by adding `.fullScreenNone` to its `collectionBehavior`, so
⌃⌘F does nothing either.

The server is started **detached**, so quitting the launcher never stops it.
Stopping is always an explicit, confirmed action — the server may be hosting
live sessions.

## How it works

Three details that are easy to get wrong:

**1. GUI apps have no shell PATH.** A double-clicked app does not read
`~/.zshrc` and does not inherit a login `PATH`, so `pnpm` would simply not be
found. Binaries are resolved explicitly against common install locations, with
a login-shell lookup as a fallback.

**2. Port probing must filter for listeners.** This app uses:

```sh
lsof -ti tcp:3080 -sTCP:LISTEN
```

Without `-sTCP:LISTEN`, `lsof` also reports every *client* connected to that
port — your browser, your editor — and acting on those PIDs would terminate
unrelated applications. Only one process can hold `LISTEN` on a port, so this
targets exactly the server no matter what its PID happens to be.

**3. Stopping is graceful.** `TERM` first, escalating to `KILL` only if the port
is still bound after ~6 seconds.

## Development

Everything lives in one file: `Sources/DSHLauncher.swift`.

```sh
swiftc -O Sources/DSHLauncher.swift -o build/DSHLauncher && ./build/DSHLauncher
```

### The code-signing gotcha

`build.sh` signs the bundle **last**, and that ordering is not cosmetic.
Modifying a bundle after signing — replacing the icon, editing `Info.plist` —
invalidates the signature, and macOS then refuses to treat the directory as an
application. The visible symptom is that **Finder shows a folder icon**, which
looks like an icon bug but is really a signature failure:

```
$ codesign -v "/Applications/DSH Launcher.app"
invalid Info.plist (plist or signature have been modified)
```

To see the icon macOS actually resolves, bypassing Finder's cache:

```sh
osascript -l JavaScript -e 'ObjC.import("AppKit");
var img=$.NSWorkspace.sharedWorkspace.iconForFile("/Applications/DSH Launcher.app");
var rep=$.NSBitmapImageRep.imageRepWithData(img.TIFFRepresentation);
rep.representationUsingTypeProperties($.NSPNGFileType,$()).writeToFileAtomically("/tmp/resolved.png",true);'
open /tmp/resolved.png
```

## Shell equivalents

If you prefer the terminal, these do the same jobs — note the same
`-sTCP:LISTEN` filter:

```sh
dshweb()  { (cd ~/Workspace/deepseek-harness && pnpm dsh web --no-open) & }
dshkill() { lsof -ti tcp:3080 -sTCP:LISTEN | xargs kill; }
```

## License

[MIT](LICENSE)
