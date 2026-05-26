# Changelog

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
