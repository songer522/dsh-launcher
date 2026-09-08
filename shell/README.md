# Terminal companions

`dsh.sh` defines `dshweb` and `dshkill`, the terminal equivalents of the
launcher app. They live here so they are version-controlled and share one
implementation with anyone who clones the repo.

```sh
echo 'source ~/Workspace/dsh-launcher/shell/dsh.sh' >> ~/.zshrc
```

| Function | Effect |
|---|---|
| `dshweb` | start the server (or reuse a running one) and open the tokenized URL in Chrome |
| `dshweb -r` | restart: stop the running server first, then start fresh |
| `dshkill` | stop whatever is listening on the port |

Environment: `DSH_WEB_PORT` selects the port (default `3080`);
`DSH_WEB_REPO` overrides the project directory.

The two traps this code navigates are documented inline and in the top-level
README: DSH's auth token must be carried in the opened URL (the bare origin
answers 401), and port probes must filter for listeners (`-sTCP:LISTEN`) or
they also match the browser sitting on the port as a client.
