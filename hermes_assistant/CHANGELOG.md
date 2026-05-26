# Changelog

## 1.0.0 — 2026-05-26

Initial release.

- Hermes Agent (NousResearch) + hermes-webui pinned to v0.51.137
- HA Ingress for Web UI panel
- Bundled `ttyd` setup terminal for `hermes setup` (any LLM provider)
- Optional Claude OAuth credentials loader (`/config/claude_credentials.json`)
- Optional `ANTHROPIC_API_KEY` baked into `.env` from add-on options
- Home Assistant platform integration with configurable `watch_entities`
- Persistent state under `/data/hermes/`
- amd64 + aarch64
