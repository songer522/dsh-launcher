# DSH Launcher

> **简体中文** · [English](README.md)

一个极简的 macOS **菜单栏** 工具，用来管理本地开发服务器：启动、在浏览器中打开、重启或停止 —— 全程无需碰终端。

它常驻在状态栏里，没有 Dock 图标，不会打扰你。

专为 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
（`pnpm dsh web`）编写，但命令、端口、项目目录和浏览器都可以配置，所以它也适用于任意长期运行的本地服务器。

原生 AppKit，单个 Swift 文件，**零依赖**。

## 为什么我要做这个工具

起因很简单：每次我想用 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 时，从源码运行就意味着必须从终端运行。

```sh
cd ~/Workspace/deepseek-harness
pnpm dsh web
```

命令本身很小 —— 但它周围的那套仪式却不小。整个会话期间终端标签页都得开着；拉取新的改动后要回到终端、杀掉服务器、重新启动；带进程级 token 的 URL 得从日志里复制出来；会话结束时还得手动停掉服务器，否则它就一直占着端口。

所有实际工作都发生在浏览器标签页里。终端从来都不是这个工具的重点 —— 它只是入口处的收费站。所以我把这套仪式换成了菜单栏中的一个图标：一键启动、一键打开浏览器、更新后重启、确认后停止 —— 服务器状态一目了然，而且不会占用 Dock 位置。

也正是因为想*好好*做一个 GUI 应用，我才发现了那些终端一直默默掩盖的坑——GUI 应用不继承 shell 的 `PATH`、DSH 的启动 token 必须跟着进入打开的标签页、停止时必须只针对监听该端口的进程。这些都在[它是如何工作的](#它是如何工作的)里做了说明。

## 菜单栏

状态图标是 DeepSeek 鲸鱼，用模板图像绘制，macOS 会自动为浅色和深色菜单栏着色。它让你一眼就能看到服务器状态 —— 运行时是**实心**的，停止时是**变暗**的 —— 所有操作都在一处点击即可完成：

<p align="center">
  <img src="./docs/menubar.png" alt="DSH Launcher 菜单在 macOS 菜单栏中的样子，显示服务器状态和操作" width="360">
</p>

顶部两条变暗的灰字是状态而非操作：服务器状态（**正在启动…**、**运行在 3080 端口**或**已停止**）和 PID。

当服务器停止时，菜单会显示 **启动服务器**。

服务器状态每 3 秒轮询一次，即使你从终端启动或停止服务器，图标也会一直保持正确。

## 面板（可选）

**显示面板**会打开一个带有相同操作的小窗口：

```
  ● ● ●   DSH Launcher

  🟢 Running on port 3080
     PID 98948 · node --import tsx/esm apps/cli/src/bin.ts web

  [ Open in Browser ]   [ Restart ]   [ Stop Server ]
```

关闭面板**不会**退出应用——它仍然保留在菜单栏中。

## 安装

需要 macOS 13 及以上版本，以及 Xcode 命令行工具（`xcode-select --install`）。

```sh
git clone https://github.com/songer522/dsh-launcher.git
cd dsh-launcher
./build.sh
```

它会编译、打包、签名并安装到 `/Applications`。

```sh
./build.sh --dev        # 构建到 ./build 而不安装
./build.sh --uninstall  # 卸载已安装的应用程序
```

## 配置

首次运行时，应用会在常见位置（`~/Workspace`、`~/Projects`、`~/Developer`、`~/src`、`~/code`、`~`）查找 DeepSeek Harness 代码库。如果你的项目在别处，或者想启动一个完全不同的东西，请打开**偏好设置**（⌘,）。

设置以 JSON 形式存储在 `~/.config/dsh-launcher/config.json`：

```json
{
  "repo": "/Users/you/Workspace/deepseek-harness",
  "command": "pnpm dsh web --no-open --port {port}",
  "port": "3080",
  "browser": "Google Chrome",
  "logFile": "/tmp/dsh-web.log"
}
```

| 字段 | 含义 |
|---|---|
| `repo` | 命令运行的工作目录 |
| `command` | 启动命令；`{port}` 会被替换 |
| `port` | 要监听的端口，并替换到命令中 |
| `browser` | 要打开的应用名称，或 `""` 表示系统默认浏览器 |
| `logFile` | 服务器 stdout/stderr 的写入位置 |

因为它本质上只是“目录 + 命令”，所以它也能轻松运行 `npm run dev`、`vite`、`python -m http.server` 或任何其它东西。

### 为什么启动标志很关键

标准命令使用 `--no-open`，因为 DSH 会默认在系统默认浏览器中打开 URL。在这里抑制它并在应用自身内打开浏览器，这样你可以在使用 Chrome 的同时，让 Safari 保持为系统默认浏览器。

## 窗口行为

该应用是一个菜单栏工具（`LSUIElement`），所以它**没有 Dock 图标**，也没有 ⌘Tab 入口。只能从菜单栏退出。

对于可选面板：

| 控制项 | 状态 |
|---|---|
| 关闭（红色） | 可用 —— 隐藏面板；应用仍然保留在菜单栏 |
| 最小化（黄色） | 可用 |
| 缩放 / 全屏（绿色） | 禁用 —— 固定尺寸面板 |

全屏之所以被禁止，一方面是因为窗口的 `styleMask` 中省略了 `.resizable`，另一方面是给 `collectionBehavior` 添加了 `.fullScreenNone`，所以 ⌃⌘F 也无效。

服务器以**分离**方式启动，因此退出启动器永远不会停止服务器。停止永远是明确的、需要确认的操作——服务器可能正在托管实时会话。

## 它是如何工作的

四个容易弄错的关键细节：

**1. GUI 应用没有 shell PATH.** 双击的应用不会读取 `~/.zshrc`，也不会继承登录 `PATH`，所以 `pnpm` 根本找不到。会自动对照常见的安装位置显式解析二进制，并以登录 shell 查找为后备。生成的服务器也会在 `PATH` 前面加上这些目录：只解决 `pnpm` 是不够的，因为它会执行 `node`，否则会报 `env: node: No such file or directory`。

**2. 认证 token 必须带过来.** DSH 会为每个进程生成启动 token 并打印带 token 的 URL；裸域名会返回 HTTP 401，所以标签页会是死页。应用会从日志里读回打印的 URL 并打开那个。不打印 token 的服务器会回退到普通 URL。

**3. 端口探测必须筛出监听者。** 这个应用使用：

```sh
lsof -ti tcp:3080 -sTCP:LISTEN
```

如果没有 `-sTCP:LISTEN`，`lsof` 还会报告连接到该端口的每一个**客户端**(你的浏览器、你的编辑器)——对这些 PID 操作会杀死无关的应用。只有一个进程能持有 `LISTEN`，所以它总能精确定位到服务器，不管 PID 是什么。

**4. 停止是优雅的。** 先发 `TERM`，只有在约 6 秒后端口仍然被占用时才升级为 `KILL`。

## 开发

一切都在一个文件里：`Sources/DSHLauncher.swift`。

```sh
swiftc -O Sources/DSHLauncher.swift -o build/DSHLauncher && ./build/DSHLauncher
```

### 代码签名的坑

`build.sh` **最后** 才对 bundle 签名，这个顺序不是随意的。签名后再修改 bundle —— 替换图标、编辑 `Info.plist` —— 会让签名失效，macOS 于是拒绝把该目录当作应用。肉眼可见的症状是 **Finder 显示的是文件夹图标**，看着像图标 bug，其实是签名坏了：

```text
$ codesign -v "/Applications/DSH Launcher.app"
invalid Info.plist (plist or signature have been modified)
```

绕过 Finder 缓存，去看 macOS 实际按什么文件版本解析的图标：

```sh
osascript -l JavaScript -e 'ObjC.import("AppKit");
var img=$.NSWorkspace.sharedWorkspace.iconForFile("/Applications/DSH Launcher.app");
var rep=$.NSBitmapImageRep.imageRepWithData(img.TIFFRepresentation);
rep.representationUsingTypeProperties($.NSPNGFileType,$()).writeToFileAtomically("/tmp/resolved.png",true);'
open /tmp/resolved.png
```

## Shell 等价命令

如果你更习惯终端，下面的函数能完成同样的事。两个细节很重要：`-sTCP:LISTEN` 过滤器，以及捕获带 token 的 URL 而不是打开裸监听地址（裸监听地址会 401）。

```sh
dshweb() {
  local port="${DSH_WEB_PORT:-3080}"
  local log="${TMPDIR:-/tmp}/dsh-web-${port}.log"
  : > "$log"     # 旧的 URL 携带的是过期的 token
  (cd ~/Workspace/deepseek-harness && pnpm dsh web --no-open --port "$port" > "$log" 2>&1) &
  local server=$!
  tail -f "$log" & local tailer=$!

  while ! nc -z 127.0.0.1 "$port" 2>/dev/null; do
    kill -0 "$server" 2>/dev/null || { kill "$tailer" 2>/dev/null; return 1; }
    sleep 0.3
  done

  # DSH 形如 `dsh web: http://127.0.0.1:PORT/?token=…` ——打开它，而不是裸监听地址
  local url=""
  for _ in {1..40}; do
    url=$(grep -aoE "https?://[^[:space:]'\"()]*[?&]token=[^[:space:]'\"()]+" "$log" \
          | grep -E "127\.0\.0\.1|localhost" | tail -1)
    [ -n "$url" ] && break
    sleep 0.25
  done

  open -a "Google Chrome" "${url:-http://127.0.0.1:$port}"
  wait "$server"; kill "$tailer" 2>/dev/null
}

dshkill() { lsof -ti tcp:3080 -sTCP:LISTEN | xargs kill; }
```

注意，在 zsh 里后台**管道**（`cmd | tee log &`）会把 `$!` 设为 `tee` 而不是服务器，从而破坏了存活检测——所以要重定向到日志，再单独 tail 它。

还要当心，`lsof -ti tcp:PORT` **不带** `-sTCP:LISTEN` 时也会匹配连到该端口的客户端——那个广为流传的一行命令，可能会杀掉你的浏览器。

## 许可证

[MIT](LICENSE)