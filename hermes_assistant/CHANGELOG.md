# Changelog

## 1.6.4 — 2026-05-27

- Terminal welcome message simplified: leads with `hermes setup` as
  the single, platform-neutral entry point. No provider-specific
  CLI helpers, no Mac-bridge workaround — those favoured one OS and
  cluttered the message.
- DOCS: removed the "Claude Max users — OAuth credentials" Mac-bridge
  section. The bridge code path in run.sh is kept (it's harmless when
  the file isn't present) but is no longer documented as a primary
  workflow.

## 1.6.3 — 2026-05-27

- **Claude Max bridge**: when `/config/claude_credentials.json` is
  present, run.sh now mirrors it to `~/.claude/.credentials.json` —
  the path Hermes' webui onboarding wizard polls. The
  "Login with Claude Code" button picks it up immediately instead of
  waiting forever.
- Terminal welcome message rewritten: leads with the
  `hermes setup` + API-key path (works in every container), explains
  why the in-container `claude` OAuth flow doesn't work (no system
  keychain → keytar fails), and documents the Mac-bridge workaround.
- DOCS: "Claude Max users" section rewritten to match reality
  (in-container `claude login` does not work; only the bridge does).
- Confirmed via live debugging: claude-code v2.1.x on Linux requires
  libsecret/keytar to save OAuth tokens. Without it the wizard polls
  `~/.claude/.credentials.json` forever because nothing writes there.

## 1.6.2 — 2026-05-27

- Terminal welcome message + DOCS now list provider CLI helpers
  for the major options Hermes' setup wizard already supports:
  - Anthropic Claude Code (`npx -y @anthropic-ai/claude-code`)
  - OpenAI Codex (`npx -y @openai/codex login`)
  - Google Gemini (`npx -y @google/gemini-cli auth`)
  - GitHub Copilot (`gh extension install github/gh-copilot`)
  - Aider (`pip install --user aider-chat`)
  - Ollama (`curl https://ollama.com/install.sh | sh`)
  Nothing is pre-installed — `npx` from the bundled Node.js bin
  fetches whatever the user picks on demand.

## 1.6.1 — 2026-05-27

- **Dropped ttyd basic-auth + `terminal_password` option entirely**.
  The terminal binds 127.0.0.1 inside the container and is reachable
  only through HA Ingress, which is itself gated by HA login +
  `panel_admin: true`. Anyone who can open the panel is already a
  verified HA admin; the extra password prompt added zero security
  and a real UX speed bump. Setup Terminal button now drops the user
  straight into a shell.

## 1.6.0 — 2026-05-27

- **Removed pre-installed Claude Code CLI** from the image. Baking
  `@anthropic-ai/claude-code` in biased the add-on toward one
  provider; the underlying Hermes Agent supports many (Anthropic,
  OpenAI, Google, local models, …) and `hermes setup` is the
  provider-neutral entry point.
- Image shrinks by ~50 MB.
- Claude Max users can still get the OAuth flow on demand inside
  the setup terminal — the bundled Node.js install gives `npx`
  out of the box:
  ```
  npx -y @anthropic-ai/claude-code setup-token
  ```
- Terminal welcome message rewritten to lead with `hermes setup`
  and the multi-provider flow.

## 1.5.4 — 2026-05-27

- **Hotfix**: addon panel showed "refused to connect" inside the HA
  Ingress iframe even though direct access to the Ingress URL worked.
  Root cause confirmed by live browser inspection:
  HA wraps the addon iframe with `sandbox=""` (most restrictive),
  which assigns it a **null origin**. webui replies with
  `X-Frame-Options: SAMEORIGIN`, the browser then compares
  null != `http://<ha-host>:8123` → **refuses to render the frame**.
  nginx now strips `X-Frame-Options` and `Content-Security-Policy`
  from upstream responses before passing them through, so HA's
  sandboxed iframe can embed the panel normally.

## 1.5.3 — 2026-05-27

- **Hotfix**: webui rendered "127.0.0.1:8788" in its HTML
  (`host:port` startup banner echoed into the page), which the
  browser inside the HA Ingress iframe tried to load directly and
  got "192.168.x.x refused to connect" — that loopback only exists
  inside the addon container.
- Bind the webui to `0.0.0.0:8788` again. webui then falls back to
  `window.location` for self-references and Ingress proxying works
  end-to-end. nginx still talks to it through `127.0.0.1:8788`
  internally (0.0.0.0 bind accepts loopback connections too).

## 1.5.2 — 2026-05-27

- Removed `anthropic_api_key` add-on option. Provider credentials
  belong in the setup terminal (`hermes setup` / `claude setup-token`)
  which writes to `/data/hermes/.env` and persists across boots.
- **Critical fix**: `/data/hermes/.env` was being truncated on every
  start, which wiped any provider keys the user had set via
  `hermes setup`. The add-on now only rewrites the keys it owns
  (`HASS_TOKEN`, `HASS_URL`, `CLAUDE_CODE_OAUTH_TOKEN`) and leaves
  everything else intact.

## 1.5.1 — 2026-05-27

- MCP endpoint switched from the legacy SSE path
  (`/mcp_server/sse` with `transport: sse`) to the **Streamable HTTP**
  path (`/api/mcp`) — the transport HA core marks as primary
  (`STREAMABLE_API` in `homeassistant/components/mcp_server/http.py`).
  Matches the path used by OpenClaw's auto-config for HA MCP.
  Hermes defaults to `streamable_http` transport when `url:` is set
  and no `transport:` key is present (see `tools/mcp_tool.py`).

## 1.5.0 — 2026-05-27

- **Auto-configures HA Core's MCP Server as a Hermes MCP source**
  (`auto_configure_mcp: true` by default).
  Rewrites the `mcp_servers.homeassistant` entry in
  `/data/hermes/config.yaml` on every boot using the resolved
  `HASS_URL` + token, so the rotating `SUPERVISOR_TOKEN` stays
  fresh and the agent has direct access to all HA entities and
  services as MCP tools.
  Requires the "MCP Server" integration enabled in HA
  (Settings → Devices & Services → Add Integration).
  Set `auto_configure_mcp: false` to opt out and manage the
  `mcp_servers:` section by hand.
- `config.yaml` is now chmod 600 (contains the bearer token).

## 1.4.0 — 2026-05-27

- **Setup terminal moved inside the addon panel**. A floating "Setup
  Terminal" button is injected at the bottom-right of the Web UI; click
  it and the same Ingress iframe navigates to `/terminal/` — no need
  to remember an IP:port URL.
- nginx multiplexes both services behind the single Ingress port:
  - `/` → Web UI (127.0.0.1:8788)
  - `/terminal/` → ttyd (127.0.0.1:7681, `--base-path /terminal/`)
- `terminal_password` is now optional (HA Ingress + `panel_admin: true`
  is the primary auth; the password adds defense in depth).
- LAN port mapping (7681) **removed** — the terminal is reachable
  only via the HA addon panel, never from the LAN.

## 1.3.0 — 2026-05-27

- **Pre-installed `claude` CLI** (`@anthropic-ai/claude-code`) via the
  bundled Node.js install. `claude setup-token` works in the setup
  terminal out of the box — no `npx`/`npm install` required.
- Terminal welcome message lists both Hermes and Claude commands.
- DOCS: added `panel_iframe` snippet for adding the setup terminal as
  a sidebar tab in HA (user-side YAML, no addon change).

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
