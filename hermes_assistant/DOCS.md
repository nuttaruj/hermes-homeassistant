# Hermes Assistant — Home Assistant Add-on

Runs the [Hermes Agent](https://hermes-agent.nousresearch.com/) (NousResearch)
with [hermes-webui](https://github.com/nesquena/hermes-webui) inside Home
Assistant. Includes a setup terminal (ttyd) so you can run `hermes setup` and
authenticate any supported LLM provider (Anthropic, OpenAI, OAuth flows, …)
directly from the browser.

The Hermes agent and Web UI are **pre-baked into the image** and **mirrored
to `/data` on first boot**. This means:

- First start is fast — no 5–10 min agent download.
- Updates pulled via `hermes update` (in the setup terminal) or
  `auto_update_agent: true` **persist across add-on restarts and rebuilds**.
- Bumping the add-on version is not required to follow Hermes upstream
  releases.

---

## First-time setup

1. **Install** the add-on from the store.
2. Open the **Configuration** tab and set:
   - `terminal_password` — protects the setup terminal (required if
     `enable_terminal` is on)
3. **Start** the add-on.
4. Open the **Web UI** from the sidebar (or `Open Web UI` button).
5. Open the **Setup Terminal** — either through the floating
   gold "Setup Terminal" button at the bottom-right of the Web UI
   panel, or directly at `<ingress_url>/terminal/`.

### Primary commands

| Command | Purpose |
|---|---|
| `hermes setup` | Interactive wizard for any supported LLM provider |
| `hermes model` | Pick / switch provider + model |
| `hermes update` | Pull the latest agent release |
| `hermes --help` | Full command list |

### Provider CLI helpers (optional)

These are convenience commands for using a provider's own CLI auth
flow before pointing Hermes at it. The bundled Node.js install gives
`npx` out of the box, so nothing needs to be installed globally.

| Provider | Command |
|---|---|
| Anthropic Claude (Claude Max OAuth) | `npx -y @anthropic-ai/claude-code` |
| OpenAI Codex / GPT | `npx -y @openai/codex login` |
| Google Gemini | `npx -y @google/gemini-cli auth` |
| GitHub Copilot | `gh auth login && gh extension install github/gh-copilot` |
| Aider (multi-provider pair programmer) | `pip install --user aider-chat` |
| Ollama (local models) | `curl -fsSL https://ollama.com/install.sh \| sh` |

For most users, `hermes setup` alone is enough — it talks to all
of the above providers directly via API key or OAuth device code.

Credentials are saved under `/data/hermes/.env` and persist across
add-on restarts and image rebuilds.

### Adding the terminal as a HA sidebar tab (optional)

If you don't want to remember the LAN URL, add this to your HA
`configuration.yaml` (replace the IP):

```yaml
panel_iframe:
  hermes_terminal:
    title: "Hermes Terminal"
    icon: mdi:console
    url: "http://192.168.1.10:7681"
    require_admin: true
```

Restart HA — a "Hermes Terminal" entry appears in the sidebar next to
the existing Hermes Agent panel. Both run inside the same add-on
container; the terminal is the only thing on the LAN port.

You do **not** need to create a Home Assistant Long-Lived Access Token —
the add-on uses the Supervisor proxy automatically (via `homeassistant_api`).

---

## Configuration options

| Option | Required | Description |
|---|---|---|
| `timezone` | yes | IANA TZ, e.g. `Asia/Bangkok` |
| `enable_terminal` | yes | `true` to expose setup terminal on port 7681 |
| `auto_update_agent` | no | `true` → run `hermes update` every container start |
| `auto_update_webui` | no | `true` → `git pull` Web UI every container start |
| `auto_configure_mcp` | no | `true` (default) → wire HA Core's MCP Server into Hermes config every boot. Requires the "MCP Server" integration in HA |
| `homeassistant_token` | no | Override the auto SUPERVISOR_TOKEN with your own LLA |
| `watch_entities` | no | List of entity IDs Hermes should watch |

All LLM provider credentials (Anthropic, OpenAI, Claude Max OAuth, …)
are configured via the setup terminal (`hermes setup` /
`claude setup-token`) and persist in `/data/hermes/.env`. The add-on
no longer reads provider keys from add-on options.

The Web UI is always served on internal port `8787` via HA Ingress.
The setup terminal is always served on port `7681` (LAN, port-mapped).

---

## What goes where

| Path | Purpose | Persists | In backup |
|---|---|---|---|
| `/data/hermes/` | All Hermes state — configs, sessions, memories | yes | yes |
| `/data/hermes/.env` | Credentials. Rewritten every start (mode 600) | yes | yes |
| `/data/hermes/config.yaml` | Hermes platform config (kept after first create) | yes | yes |
| `/data/hermes/agent-code/` | Hermes agent install (mirrored from image on first boot, updated in place by `hermes update`) | yes | partial |
| `/data/hermes/agent-code/venv/` | Agent Python venv (~260MB, regenerable) | yes | **no** (excluded) |
| `/data/hermes/webui-app/` | Web UI install (mirrored on first boot, `git pull`-able) | yes | partial |
| `/data/hermes/webui-app/.venv/` | Web UI Python venv | yes | **no** (excluded) |
| `/data/hermes/webui/` | Web UI sessions and workspace state | yes | yes |
| `/config/claude_credentials.json` | Optional Claude OAuth dump | yes | yes |

The `/opt/hermes-agent-code/` and `/opt/hermes-webui/` directories baked
into the image are used **only on first boot** as the seed for the mirror.
After that, the `/data` copies are the source of truth.

---

## Claude Max users — OAuth credentials

If you subscribe to Claude Max and want to reuse your Claude Code login
instead of paying per-token via the API, copy your credentials file into
the add-on config directory:

1. From a machine where Claude Code is logged in:
   ```
   cp ~/.claude/.credentials.json /share/claude_credentials.json
   ```
2. Move the file into `/config/claude_credentials.json` of this add-on
   (via the File Editor add-on or SSH).
3. Restart the add-on. The log will say `Claude OAuth token loaded`.

OAuth tokens expire — refresh this file when needed, or use
`anthropic_api_key` instead.

---

## Security

- **Web UI** binds `0.0.0.0` inside the container but is reachable only
  via HA Ingress (port 8787 is not declared in `ports:` → not LAN-exposed).
  HA's own login is the only auth layer; `panel_admin: true` restricts
  the sidebar panel to HA admin users.
- **Setup terminal** is exposed on the LAN via the Docker port mapping
  (`7681/tcp: 7681`). ttyd basic-auth is the only barrier — **set a
  strong `terminal_password`**. Disable via `enable_terminal: false`
  between setup sessions if your LAN is untrusted.
- `.env` is written with mode `600` (root-only).
- HA Supervisor watchdog auto-restarts the container if the Web UI health
  endpoint stops responding.

---

## Updating

Three update paths, in order from least to most intervention:

1. **Hermes agent / Web UI follows upstream** (recommended day-to-day)
   - Open the setup terminal, run `hermes update`
   - Or enable `auto_update_agent: true` / `auto_update_webui: true` —
     updates run on every container start
   - Persists in `/data` across add-on restarts; bumping the add-on
     version is NOT required
2. **Add-on itself** (manifest, Dockerfile, base image)
   - The repo owner bumps `version:` in `config.yaml` and pushes to
     GitHub. HA Supervisor shows the update; users click "Update"
     (or enable HA's per-add-on auto-update toggle)
3. **Force agent reinstall from image seed**
   - Setup terminal:
     ```
     rm -rf /data/hermes/agent-code
     ```
   - Restart the add-on. First boot re-mirrors the baked-in seed
     (resets to the version that shipped with the current image).

---

## Troubleshooting

- **Web UI shows nothing** — check the add-on log. After `Starting Hermes
  Web UI on 127.0.0.1:8787` the UI is ready. Watchdog will restart if not.
- **`hermes setup` says agent missing** — check
  `/data/hermes/.bootstrap-done` exists and `/data/hermes/venv/` is
  populated. If not, the pre-bake failed; run `bootstrap.py` manually:
  ```
  /opt/hermes-webui/.venv/bin/python /opt/hermes-webui/bootstrap.py --no-browser
  ```
- **HA integration fails** — log should say either
  `Using auto-injected SUPERVISOR_TOKEN` or `Using user-supplied LLA`.
  If both are missing, set `homeassistant_token` manually.
