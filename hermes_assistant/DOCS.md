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
5. Open the **Setup Terminal** at `http://HOMEASSISTANT_IP:7681`
   (user `hermes`, password = `terminal_password`).
   In the terminal run:
   ```
   hermes setup
   ```
   Follow the prompts to authenticate your LLM provider (Anthropic API key,
   Claude OAuth, OpenAI, etc.). Credentials are saved under `/data/hermes/`
   and persist across add-on restarts.

You do **not** need to create a Home Assistant Long-Lived Access Token —
the add-on uses the Supervisor proxy automatically (via `homeassistant_api`).

---

## Configuration options

| Option | Required | Description |
|---|---|---|
| `terminal_password` | when terminal on | Basic-auth password for ttyd |
| `timezone` | yes | IANA TZ, e.g. `Asia/Bangkok` |
| `enable_terminal` | yes | `true` to expose setup terminal on port 7681 |
| `auto_update_agent` | no | `true` → run `hermes update` every container start |
| `auto_update_webui` | no | `true` → `git pull` Web UI every container start |
| `homeassistant_token` | no | Override the auto SUPERVISOR_TOKEN with your own LLA |
| `anthropic_api_key` | no | Bake into `.env`. Skip if configuring via terminal |
| `watch_entities` | no | List of entity IDs Hermes should watch |

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
