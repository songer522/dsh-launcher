/**
 * dsh-menubar-launcher — the Host half of DSH Launcher.
 *
 * The macOS app in this repository needs three facts about the server it is
 * managing: which port it bound, which process owns it, and the URL that
 * actually opens. The third one is the hard part. DSH mints a per-process
 * launch token and prints it once; the bare origin answers HTTP 401, so a tab
 * opened without the token is dead.
 *
 * Until now the app recovered that URL by grepping the server's log file. That
 * works only when the app started the server itself — a server started from a
 * terminal writes its log somewhere the app never sees, and the app is reduced
 * to opening a URL it knows will 401.
 *
 * This plugin removes the guessing. It runs inside the server process, where
 * the port and the token are not parsed but simply known, and writes them to a
 * small JSON file the app reads. The file is created when the server is ready
 * and removed when it stops, so its presence is itself the liveness signal.
 *
 * Nothing here is macOS-specific. Any supervisor that wants the authenticated
 * URL of a running harness can read the same file.
 */

import { chmodSync, mkdirSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, isAbsolute, join } from 'node:path'

/** Stable Cordis plugin name. */
export const name = 'dsh-launcher-runtime'

/**
 * Deliberately no top-level `inject`.
 *
 * `webServer` and `connection` are what this plugin needs, and declaring them
 * here would be the obvious move — but a top-level `inject` that is never
 * satisfied leaves the row PENDING, and the boot audit turns a permanently
 * pending row into a fatal error:
 *
 *   dsh: 1 entry did not activate
 *   dsh-menubar-launcher: pending (waiting for services: webServer, connection)
 *
 * Those services exist only in a profile that serves a browser UI. `dsh plugin
 * add` initializes a profile from `@deepseek-ai/dsh-base` alone, so the very
 * first boot after installing this plugin would crash the harness — and a
 * menu bar convenience has no business preventing a headless profile from
 * starting at all.
 *
 * So the row activates unconditionally and waits for its services from the
 * inside, via `ctx.inject()`. In a web profile the callback runs as soon as
 * the server has bound and the token exists; in a headless one it simply never
 * runs, and the harness boots normally. This is the same pattern the harness's
 * own web-app bundle uses for its optional dependencies.
 */

/** Schema version of the descriptor. A reader that does not know it must refuse the file. */
const DESCRIPTOR_VERSION = 1

/** Where the descriptor goes unless configured otherwise: beside the app's own config.json. */
const DEFAULT_PATH = join(homedir(), '.config', 'dsh-launcher', 'runtime.json')

/**
 * The URL host the descriptor advertises.
 *
 * Always loopback, never the configured bind host. A server bound to
 * 0.0.0.0 is still reached locally over loopback, and a descriptor is by
 * definition read by something on this machine. Publishing a LAN address here
 * would hand a local reader a needlessly network-exposed token.
 */
const LOOPBACK_HOST = '127.0.0.1'

/**
 * Minimal Standard Schema validator.
 *
 * Cordis validates a plugin's config through the Standard Schema interface
 * (`~standard.validate`). Schemastery would supply one, but taking a
 * dependency for two fields would also mean pinning a `@deepseek-ai/*` version
 * range — and a peer range that silently excludes the harness's own
 * prereleases is a well-known way to hand users an ERESOLVE they have to
 * resolve by hand. Twenty lines here keeps this package dependency-free, so it
 * installs against any harness version.
 *
 * @param {unknown} value - the raw config from the composed row.
 * @returns {{ value: { path: string, enabled: boolean } } | { issues: { message: string, path: string[] }[] }}
 */
function validateConfig(value) {
  const input = value === undefined || value === null ? {} : value
  if (typeof input !== 'object' || Array.isArray(input)) {
    return { issues: [{ message: 'expected an object', path: [] }] }
  }
  const issues = []
  const { path = DEFAULT_PATH, enabled = true } = input

  if (typeof path !== 'string' || path.trim() === '') {
    issues.push({ message: 'must be a non-empty string', path: ['path'] })
  } else if (!isAbsolute(path)) {
    // A relative path would resolve against the harness's working directory,
    // which is not a value this plugin controls or a reader could predict.
    issues.push({ message: `must be an absolute path, got ${JSON.stringify(path)}`, path: ['path'] })
  }
  if (typeof enabled !== 'boolean') {
    issues.push({ message: 'must be a boolean', path: ['enabled'] })
  }

  if (issues.length > 0) return { issues }
  return { value: { path, enabled } }
}

/**
 * Plugin config.
 *
 * - `path` — absolute location of the descriptor. Defaults to
 *   `~/.config/dsh-launcher/runtime.json`, the directory the macOS app already
 *   owns.
 * - `enabled` — set false to keep the plugin composed but write nothing.
 */
export const Config = {
  '~standard': {
    version: 1,
    vendor: 'dsh-menubar-launcher',
    validate: validateConfig,
  },
}

/**
 * Write JSON so a reader never observes a half-written file.
 *
 * The descriptor is polled by another process, so a plain write is a race: a
 * reader arriving mid-write gets truncated JSON and concludes the server is
 * broken. Writing to a sibling temporary file and renaming makes the
 * replacement atomic within the directory.
 *
 * The mode is 0600 before the rename rather than after. The file carries a
 * launch token — a credential granting full access to this harness — so it
 * must never exist, even briefly, at the default umask.
 *
 * @param {string} path - absolute destination.
 * @param {object} descriptor - JSON-serializable payload.
 */
function writeAtomic(path, descriptor) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
  const temporary = `${path}.${process.pid}.tmp`
  try {
    writeFileSync(temporary, `${JSON.stringify(descriptor, null, 2)}\n`, { mode: 0o600 })
    chmodSync(temporary, 0o600)
    renameSync(temporary, path)
  } catch (error) {
    rmSync(temporary, { force: true })
    throw error
  }
}

/**
 * Publish the descriptor for as long as this server is running.
 *
 * @param {import('@deepseek-ai/cordis').Context} ctx - plugin context carrying webServer and connection.
 * @param {{ path: string, enabled: boolean }} config - validated config.
 */
export function apply(ctx, config) {
  if (!config.enabled) return

  // Waits for the services rather than depending on them; see the note above
  // `name` for why this is not a top-level `inject`. The callback body is
  // re-run if either service is replaced, and its effect is disposed first, so
  // the descriptor always describes the current server.
  ctx.inject(['webServer', 'connection'], (serverCtx) => {
    serverCtx.effect(() => {
      const url = `http://${LOOPBACK_HOST}:${String(serverCtx.webServer.port)}`
      const descriptor = {
        version: DESCRIPTOR_VERSION,
        pid: process.pid,
        host: LOOPBACK_HOST,
        port: serverCtx.webServer.port,
        url,
        // The whole point of the file. `authenticatedUrl` appends this
        // process's launch token, so this is the URL that opens rather than
        // 401s.
        authenticatedUrl: serverCtx.connection.authenticatedUrl(url),
        startedAt: new Date().toISOString(),
      }

      try {
        writeAtomic(config.path, descriptor)
      } catch (error) {
        // A launcher convenience must never take the harness down with it. An
        // unwritable config directory is a reason for the menu bar app to fall
        // back to reading the log, not a reason for the server to fail to boot.
        serverCtx.logger.warn(
          `dsh-launcher: could not write the runtime descriptor to ${config.path}: `
          + `${error instanceof Error ? error.message : String(error)}`,
        )
        return () => {}
      }

      // Removal on dispose is what makes the file's presence meaningful: it
      // goes away on shutdown, on unload, and on an HMR reload. A descriptor
      // outliving its server would point a reader at a dead port with a dead
      // token, which is worse than no descriptor at all.
      return () => {
        try {
          rmSync(config.path, { force: true })
        } catch (error) {
          serverCtx.logger.warn(
            `dsh-launcher: could not remove the runtime descriptor at ${config.path}: `
            + `${error instanceof Error ? error.message : String(error)}`,
          )
        }
      }
    }, 'dsh-launcher: runtime descriptor')
  })
}
