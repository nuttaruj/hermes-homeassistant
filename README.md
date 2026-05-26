# Hermes Home Assistant Add-on

[![Add this repo](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A//github.com/nuttaruj/hermes-homeassistant)

Run the [Hermes Agent](https://hermes-agent.nousresearch.com/) (NousResearch)
with [hermes-webui](https://github.com/nesquena/hermes-webui) as a single
Home Assistant Supervisor add-on. Inspired by
[OpenClawHomeAssistant](https://github.com/techartdev/OpenClawHomeAssistant).

## What you get

- **Web UI panel** — Hermes web interface embedded in your HA sidebar
  via Ingress
- **Setup terminal** — ttyd-served terminal on port `7681` for running
  `hermes setup` to authenticate any LLM provider (Anthropic, OpenAI,
  Claude OAuth, …) interactively
- **HA toolset** — Hermes can read state and call services on your HA
  instance via a Long-Lived Access Token

## Install

1. **Add this repository** to Home Assistant:
   - Settings → Add-ons → Add-on Store → ⋮ → Repositories
   - Paste `https://github.com/nuttaruj/hermes-homeassistant`
2. Refresh the store, install **Hermes Assistant**
3. Open the **Configuration** tab and set at minimum:
   - `webui_password` — Web UI login password
   - `terminal_password` — protects the setup terminal
   - `homeassistant_token` — paste a Long-Lived Access Token
4. Start the add-on (first start installs the Hermes agent — takes 5–10 min)
5. Open the panel from the sidebar, then visit the terminal at
   `http://YOUR_HA_IP:7681` to run `hermes setup`

Full configuration reference: see [hermes_assistant/DOCS.md](hermes_assistant/DOCS.md).

## Repo layout

```
.
├── repository.yaml                # HA add-on repo manifest
└── hermes_assistant/              # the add-on
    ├── config.yaml                # add-on manifest + options schema
    ├── build.yaml                 # base image per arch
    ├── Dockerfile                 # Debian + uv + ttyd + hermes-webui
    ├── run.sh                     # entrypoint
    ├── DOCS.md                    # add-on user docs (shown in HA)
    ├── CHANGELOG.md
    ├── icon.png                   # 128x128
    └── logo.png                   # 250x100
```

## Architecture support

`amd64`, `aarch64` (HA OS on Intel NUC, Raspberry Pi 4/5, etc.).

## License

MIT
