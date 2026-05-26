# Hermes Assistant — Home Assistant Add-on

Runs the [Hermes Agent](https://hermes-agent.nousresearch.com/) (NousResearch)
with [hermes-webui](https://github.com/nesquena/hermes-webui) inside Home
Assistant. Includes a setup terminal (ttyd) so you can run `hermes setup` and
authenticate any supported LLM provider (Anthropic, OpenAI, OAuth flows, …)
directly from the browser.

---

## First-time setup

1. **Install** the add-on from the store.
2. Open the **Configuration** tab and set:
   - `webui_password` — used to log into the Web UI (required)
   - `terminal_password` — protects the setup terminal (required if
     `enable_terminal` is on)
   - `homeassistant_token` — paste a Long-Lived Access Token from your HA
     profile (Profile → Security → Create Token)
3. **Start** the add-on. Watch the log — first start downloads and installs
   the Hermes agent (5–10 min depending on bandwidth and architecture).
4. Open the **Web UI** from the sidebar (or `Open Web UI` button).
5. Open the **Setup Terminal** at `http://HOMEASSISTANT_IP:7681`
   (user `hermes`, password = `terminal_password`).
   In the terminal run:
   ```
   hermes setup
   ```
   Follow the prompts to authenticate your LLM provider (Anthropic API key,
   Claude OAuth, OpenAI, etc.). Credentials are saved under `/data/hermes/`
   and persist across add-on restarts.

---

## Configuration options

| Option | Required | Description |
|---|---|---|
| `webui_password` | yes | Web UI login password |
| `terminal_password` | when terminal on | Basic-auth password for ttyd |
| `homeassistant_token` | recommended | LLA token — enables the HA toolset |
| `timezone` | yes | IANA TZ, e.g. `Asia/Bangkok` |
| `enable_terminal` | yes | `true` to expose setup terminal on port 7681 |
| `terminal_port` | yes | Default `7681` |
| `webui_port` | yes | Internal port for the Web UI (Ingress-served). Default `8787` |
| `anthropic_api_key` | no | Bake into `.env`. Skip if you'll set via `hermes setup` |
| `hass_url` | no | Override HA URL Hermes uses. Default `http://homeassistant.local:8123` |
| `watch_entities` | no | List of entity IDs Hermes should watch for state changes |

---

## What goes where

| Path | Purpose | Persists |
|---|---|---|
| `/data/hermes/` | All Hermes state — sessions, memories, agent venv | yes |
| `/data/hermes/.env` | Credentials. Rewritten every start from add-on options | yes |
| `/data/hermes/config.yaml` | Hermes platform config (kept after first create) | yes |
| `/data/hermes/webui/` | WebUI sessions and workspace state | yes |
| `/config/claude_credentials.json` | Optional Claude OAuth dump | yes |

---

## Claude Max users — OAuth credentials

If you subscribe to Claude Max and want to reuse your Claude Code login
instead of paying per-token via the API, copy your credentials file into
the add-on config directory:

1. From a machine where Claude Code is logged in:
   ```
   cp ~/.claude/.credentials.json /share/claude_credentials.json
   ```
   (or copy via Samba into the `share` folder)
2. Move the file into `/config/claude_credentials.json` of this add-on
   (via the File Editor add-on or SSH).
3. Restart the add-on. The log will say `Claude OAuth token loaded`.

OAuth tokens expire periodically — you will need to refresh this file
when that happens, or use `anthropic_api_key` instead.

---

## Security notes

- The **Web UI** binds `127.0.0.1` inside the container and is reachable
  only via HA Ingress, which inherits HA's own auth.
- The **setup terminal** is exposed on the LAN via `host_network`.
  ttyd basic-auth is the only barrier — **always set a strong
  `terminal_password`**. Consider setting `enable_terminal: false` between
  setup sessions if your LAN is untrusted.

---

## Updating

The hermes-webui version is pinned in the add-on Dockerfile (build arg
`HERMES_WEBUI_REF`). Update by bumping the add-on version and reinstalling.
The Hermes agent updates itself on first run after `/data/hermes/venv` is
cleared, or via `hermes update` in the setup terminal.

---

## Troubleshooting

- **Web UI blank / 502 after install** — check the add-on log. First start
  takes several minutes to install the agent. Wait until you see
  `Hermes Web UI listening on …`.
- **`hermes setup` says no provider configured** — run it again, the
  install must complete first.
- **`HASS_TOKEN` not recognised in WebUI** — check the log for
  `Loading Hermes config`. The `.env` is regenerated on every start, so
  make sure you saved `homeassistant_token` in Configuration and
  restarted.
