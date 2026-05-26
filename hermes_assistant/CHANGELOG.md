# Changelog

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
