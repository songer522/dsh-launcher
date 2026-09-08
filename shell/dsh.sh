# dsh.sh — terminal companions to the DSH Launcher app.
#
# Provides `dshweb` (start or reuse the server, then open the tokenized URL in
# Chrome) and `dshkill` (stop whatever is listening on the port).
#
# Usage: source this file from your shell rc:
#
#   echo 'source ~/Workspace/dsh-launcher/shell/dsh.sh' >> ~/.zshrc
#
# Functions:
#   dshweb        reuse a running server if there is one, else start it
#   dshweb -r     restart: stop the running server first, then start fresh
#   dshkill       stop whatever is listening on the port
#
# Environment:
#   DSH_WEB_PORT   port to manage (default 3080)

# ---
# Two details here are easy to get wrong:
#
# 1. DSH mints a per-process launch token and prints
#    `dsh web: http://127.0.0.1:PORT/?token=…`. Opening the bare origin answers
#    HTTP 401 and the tab is dead, so the printed URL must be captured and
#    opened verbatim. That is why the server's output is redirected to a log:
#    the URL is read back out of it.
# 2. Restart is deliberately opt-in. A running server may be hosting live
#    sessions (the agent you are talking to runs *inside* it), so killing it
#    automatically on every invocation would silently destroy in-flight work.
# ---

_dshweb_token_url() {
  # Pull the tokenized URL out of the log. Excludes brackets/quotes and
  # prefers loopback: DSH prints the LAN address on the same line inside
  # parentheses, so a greedy match grabs a trailing ')' and an address that may
  # be unreachable.
  local log="$1"
  [ -f "$log" ] || return 1
  local found
  found=$(grep -aoE "https?://[^[:space:]'\"()]*[?&]token=[^[:space:]'\"()]+" "$log" 2>/dev/null \
          | grep -E "127\.0\.0\.1|localhost" | tail -1)
  [ -z "$found" ] && found=$(grep -aoE "https?://[^[:space:]'\"()]*[?&]token=[^[:space:]'\"()]+" "$log" 2>/dev/null | tail -1)
  [ -n "$found" ] && print -r -- "$found"
}

dshweb() {
  local repo="${DSH_WEB_REPO:-$HOME/Workspace/deepseek-harness}"
  local port="${DSH_WEB_PORT:-3080}"
  local url="http://127.0.0.1:${port}"
  local log="${TMPDIR:-/tmp}/dsh-web-${port}.log"
  local restart=0
  [ "$1" = "-r" ] || [ "$1" = "--restart" ] && restart=1

  if lsof -ti "tcp:${port}" -sTCP:LISTEN >/dev/null 2>&1; then
    if [ "$restart" -eq 1 ]; then
      echo "dshweb: restarting — stopping the server on ${port}"
      dshkill || return 1
    else
      local existing
      existing=$(_dshweb_token_url "$log")
      echo "dshweb: port ${port} is already in use by PID(s): $(lsof -ti tcp:${port} -sTCP:LISTEN | tr '\n' ' ')"
      if [ -n "$existing" ]; then
        echo "dshweb: reusing it — opening Chrome (token from ${log})"
        open -a "Google Chrome" "$existing"
      else
        # No log for this server (started elsewhere, or log removed): the bare
        # URL will 401, so say so rather than opening a dead tab.
        echo "dshweb: reusing it, but no tokenized URL was found in ${log}"
        echo "dshweb: that server was started elsewhere — copy its URL from its own terminal,"
        echo "dshweb: or run 'dshweb -r' to restart it under this shell."
        open -a "Google Chrome" "$url"
      fi
      echo "dshweb: (use 'dshweb -r' to restart, e.g. after patching a plugin)"
      return 0
    fi
  fi

  # Truncate first: a stale URL from a previous run carries a dead token.
  : > "$log"
  # No pipeline here. In zsh, `cmd | tee` sets $! to tee, not the server, which
  # would break the liveness check below. Redirect to the log and tail it
  # instead, so output still reaches the terminal.
  ( cd "$repo" && pnpm dsh web --no-open --port "$port" > "$log" 2>&1 ) &
  local server=$!
  tail -f "$log" 2>/dev/null &
  local tailer=$!

  # Wait for the port, but give up if the server dies or takes too long.
  local waited=0
  while ! nc -z 127.0.0.1 "$port" 2>/dev/null; do
    if ! kill -0 "$server" 2>/dev/null; then
      kill "$tailer" 2>/dev/null
      echo "dshweb: server exited before it was ready — last output:"
      tail -5 "$log" 2>/dev/null | sed 's/^/  /'
      wait "$server" 2>/dev/null
      return 1
    fi
    sleep 0.3
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then   # ~60s
      echo "dshweb: timed out waiting for ${url}"
      kill "$tailer" 2>/dev/null; kill "$server" 2>/dev/null
      return 1
    fi
  done

  # The port is open slightly before the URL is printed; give it a moment.
  local tries=0 target=""
  while [ "$tries" -lt 40 ]; do
    target=$(_dshweb_token_url "$log") && [ -n "$target" ] && break
    sleep 0.25
    tries=$((tries + 1))
  done

  if [ -n "$target" ]; then
    open -a "Google Chrome" "$target"
  else
    # A server that prints no token (a plain dev server) still works bare.
    echo "dshweb: no token in output; opening ${url}"
    open -a "Google Chrome" "$url"
  fi

  wait "$server"              # foreground, so Ctrl-C stops the server
  kill "$tailer" 2>/dev/null  # and stop echoing the log
}

# Stop a DSH server that outlived its terminal (orphaned to launchd).
dshkill() {
  local port="${DSH_WEB_PORT:-3080}"
  local pids
  pids="$(lsof -ti tcp:${port} -sTCP:LISTEN 2>/dev/null)"
  if [ -z "$pids" ]; then echo "dshkill: nothing listening on ${port}"; return 0; fi
  echo "dshkill: killing $pids"
  echo "$pids" | xargs kill 2>/dev/null
  while lsof -ti "tcp:${port}" -sTCP:LISTEN >/dev/null 2>&1; do sleep 0.3; done
  echo "dshkill: port ${port} is free"
}
