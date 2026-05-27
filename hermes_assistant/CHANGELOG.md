# Changelog

## 1.2.2 — 2026-05-27

- **Removed `webui_password` option**. The webui post-login redirect
  generated a `Location: /` header — relative to the Ingress iframe
  root, which the browser resolved against the HA host, bouncing the
  user to the HA dashboard inside the addon iframe.
  HA Ingress is now the only auth layer for the Web UI (panel is
  already admin-only via `panel_admin: true`). The redirect path no
  longer exists because there is no login form to redirect from.
- `terminal_password` remains required — the setup terminal is still
  exposed on LAN port 7681 via the ports mapping.

## 1.2.1 — 2026-05-27

Two bug fixes from the first real-world install — both caused a
container restart loop (~7 s per cycle):

- **Webui bound 127.0.0.1 inside the container** — Ingress and the
  HA watchdog reach the container via its bridge-network IP, not its
  loopback. Bind 0.0.0.0 now. The port is still not in `ports:`, so
  the addon does NOT expose the Web UI to the LAN — only the Ingress
  proxy can reach it.
- **bootstrap.py exits after spawning the server in the background**.
  PID 1 in the container terminated → Supervisor restarted → loop.
  Replaced with direct `server.py` invocation so the webui itself is
  PID 1 and stays in the foreground.

## 1.2.0 — 2026-05-27

- Pre-built multi-arch images published to
  `ghcr.io/nuttaruj/{arch}-hermes-assistant`
- First install drops from ~10–15 min (local Dockerfile build) to
  ~1–2 min (HA pulls the prebuilt image)
- Dockerfile + build.yaml retained as fallback when the registry image
  is unreachable

## 1.1.0 — 2026-05-26

- **In-place updates without re-pushing the add-on**:
  - First boot mirrors agent (`/opt/hermes-agent-code` →
    `/data/hermes/agent-code`) and Web UI (`/opt/hermes-webui` →
    `/data/hermes/webui-app`) with venv shebang fix-up
  - `hermes update` and `git pull` writes now persist across container
    restarts and image rebuilds
- New options: `auto_update_agent` and `auto_update_webui` —
  run upstream updates automatically on every container start
- `/usr/local/bin/hermes` dispatcher prefers the mirrored install,
  falls back to the image seed during first boot
- `.git` history retained for both repos (shallow clone for webui;
  full clone for agent — required by `hermes update`)
- `backup_exclude` paths updated to skip the new venv locations

## 1.0.0 — 2026-05-26

Initial release.

- Hermes Agent (NousResearch) + hermes-webui pinned to v0.51.137
- HA Ingress for Web UI panel, `panel_admin: true`
- Bundled `ttyd` setup terminal for `hermes setup` (any LLM provider)
- Optional Claude OAuth credentials loader (`/config/claude_credentials.json`)
- Optional `ANTHROPIC_API_KEY` baked into `.env` from add-on options
- Home Assistant platform integration via Supervisor proxy
  (`homeassistant_api: true`, auto `SUPERVISOR_TOKEN`) — no LLA token required
- Pre-baked Hermes agent (multi-stage build) — no first-run download
- HA watchdog on Web UI `/health` endpoint, container HEALTHCHECK
- `backup_exclude` for regenerable venv (~300MB saved per backup)
- Multi-stage Dockerfile, no compilers in runtime image
- Persistent state under `/data/hermes/` (`.env` mode 600)
- amd64 + aarch64
