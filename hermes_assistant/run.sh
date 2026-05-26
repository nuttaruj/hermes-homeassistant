#!/usr/bin/with-contenv bashio
# Hermes Assistant — Home Assistant add-on entrypoint
# Runs:
#   1. ttyd web terminal (background) → port 7681 — for `hermes setup` (OAuth/API)
#   2. hermes-webui (foreground) → bound 127.0.0.1:8787 — served via HA Ingress
set -e

# ─── Read add-on options ────────────────────────────────────────────────────
WEBUI_PASSWORD=$(bashio::config 'webui_password')
TERMINAL_PASSWORD=$(bashio::config 'terminal_password')
HA_TOKEN=$(bashio::config 'homeassistant_token')
TZNAME=$(bashio::config 'timezone')
ENABLE_TERMINAL=$(bashio::config 'enable_terminal')
TERMINAL_PORT=$(bashio::config 'terminal_port')
WEBUI_PORT=$(bashio::config 'webui_port')
ANTHROPIC_API_KEY=$(bashio::config 'anthropic_api_key')
HASS_URL=$(bashio::config 'hass_url')

# ─── Validate required ──────────────────────────────────────────────────────
if [ -z "${WEBUI_PASSWORD}" ]; then
    bashio::log.fatal "webui_password is required (open Configuration tab)"
    exit 1
fi
if bashio::var.true "${ENABLE_TERMINAL}" && [ -z "${TERMINAL_PASSWORD}" ]; then
    bashio::log.fatal "terminal_password is required when enable_terminal=true"
    exit 1
fi
if [ -z "${HA_TOKEN}" ]; then
    bashio::log.warning "homeassistant_token not set — HA integration disabled until you add it"
fi

# ─── Timezone ────────────────────────────────────────────────────────────────
export TZ="${TZNAME}"
if [ -f "/usr/share/zoneinfo/${TZNAME}" ]; then
    cp "/usr/share/zoneinfo/${TZNAME}" /etc/localtime
    echo "${TZNAME}" > /etc/timezone
fi

# ─── Persistent dirs ────────────────────────────────────────────────────────
mkdir -p /data/hermes /data/hermes/webui

# ─── .env (file mode 600 — contains secrets) ────────────────────────────────
ENV_FILE=/data/hermes/.env
( umask 077 && : > "${ENV_FILE}" )
if [ -n "${HA_TOKEN}" ]; then
    echo "HASS_TOKEN=${HA_TOKEN}" >> "${ENV_FILE}"
    echo "HASS_URL=${HASS_URL}"   >> "${ENV_FILE}"
fi
if [ -n "${ANTHROPIC_API_KEY}" ]; then
    echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" >> "${ENV_FILE}"
fi
chmod 600 "${ENV_FILE}"

# ─── Claude OAuth credentials (optional, from /config) ──────────────────────
# User can copy ~/.claude/.credentials.json into /addon_configs/<slug>/ to use
# their Claude Max subscription. Token is refreshed by Hermes/Claude SDK.
if [ -f "/config/claude_credentials.json" ]; then
    bashio::log.info "Loading Claude OAuth credentials from /config/claude_credentials.json"
    OAUTH_TOKEN=$(python3 -c "
import json, sys
try:
    d = json.load(open('/config/claude_credentials.json'))
    print(d.get('claudeAiOauth', {}).get('accessToken', ''))
except Exception as e:
    print('', file=sys.stderr)
" 2>/dev/null) || true
    if [ -n "${OAUTH_TOKEN}" ]; then
        echo "CLAUDE_CODE_OAUTH_TOKEN=${OAUTH_TOKEN}" >> "${ENV_FILE}"
        bashio::log.info "Claude OAuth token loaded into .env"
    else
        bashio::log.warning "claude_credentials.json present but no accessToken extracted"
    fi
fi

# ─── Hermes config.yaml (created once, user can edit via WebUI) ─────────────
HERMES_CONFIG=/data/hermes/config.yaml
if [ ! -f "${HERMES_CONFIG}" ]; then
    bashio::log.info "Creating initial Hermes config.yaml"
    {
        echo "platforms:"
        echo "  homeassistant:"
        echo "    enabled: true"
        echo "    extra:"
        echo "      cooldown_seconds: 60"
        # Render watch_entities from options
        if bashio::config.has_value 'watch_entities'; then
            echo "      watch_entities:"
            for entity in $(bashio::config 'watch_entities'); do
                echo "        - ${entity}"
            done
        fi
    } > "${HERMES_CONFIG}"
fi

# ─── Export envs for hermes-webui ───────────────────────────────────────────
export HERMES_HOME=/data/hermes
export HERMES_WEBUI_STATE_DIR=/data/hermes/webui
export HERMES_WEBUI_HOST=127.0.0.1
export HERMES_WEBUI_PORT="${WEBUI_PORT}"
export HERMES_WEBUI_PASSWORD="${WEBUI_PASSWORD}"
export HERMES_CONFIG_PATH=/data/hermes/config.yaml
# Tell bootstrap.py not to overwrite env vars we've set
export HERMES_WEBUI_PRESERVE_ENV=1

# ─── ttyd (background, only if enabled) ─────────────────────────────────────
if bashio::var.true "${ENABLE_TERMINAL}"; then
    bashio::log.info "Starting setup terminal on port ${TERMINAL_PORT}"
    # -W writable; -c basic auth; bind 0.0.0.0 (host_network exposes to LAN);
    # drop user into a bash shell at HERMES_HOME with PATH set so `hermes`
    # resolves to whatever bootstrap.py installed.
    /usr/local/bin/ttyd \
        --port "${TERMINAL_PORT}" \
        --interface 0.0.0.0 \
        --credential "hermes:${TERMINAL_PASSWORD}" \
        --writable \
        --check-origin \
        bash -l -c "cd /data/hermes && export HERMES_HOME=/data/hermes && export PATH=\"\${HERMES_HOME}/venv/bin:/opt/hermes-webui/.venv/bin:\${PATH}\" && exec bash" \
        &
    TTYD_PID=$!
    bashio::log.info "ttyd PID=${TTYD_PID}"
fi

# ─── First-run: bootstrap.py installs hermes-agent into ${HERMES_HOME} ──────
# Subsequent starts skip the install because bootstrap.py detects the agent.
# This can take 5–10 min the first time depending on network/arch.
if [ ! -d "${HERMES_HOME}/venv" ] && [ ! -d "/opt/hermes-agent" ]; then
    bashio::log.info "First run — installing Hermes agent into ${HERMES_HOME} (may take several minutes)"
fi

# ─── Start hermes-webui via bootstrap (foreground) ──────────────────────────
bashio::log.info "Starting Hermes Web UI on 127.0.0.1:${WEBUI_PORT} (exposed via HA Ingress)"
cd /opt/hermes-webui
exec "${HERMES_WEBUI_PYTHON}" /opt/hermes-webui/bootstrap.py --no-browser
