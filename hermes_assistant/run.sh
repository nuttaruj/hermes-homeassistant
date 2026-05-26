#!/usr/bin/with-contenv bashio
# Hermes Assistant — Home Assistant add-on entrypoint
#   1. Validate options
#   2. Resolve HA token (SUPERVISOR_TOKEN auto-fallback)
#   3. Write secrets to /data/hermes/.env (mode 600)
#   4. Materialise initial Hermes config.yaml
#   5. Mirror pre-baked agent into /data/hermes on first run (so it persists
#      and is user-editable via the terminal)
#   6. Start ttyd in background — gated on bootstrap completion
#   7. Exec hermes-webui in foreground (bound 127.0.0.1:8787 → Ingress)
set -e

WEBUI_PORT=8787
TERMINAL_PORT=7681

# ─── Read options ───────────────────────────────────────────────────────────
WEBUI_PASSWORD=$(bashio::config 'webui_password')
TERMINAL_PASSWORD=$(bashio::config 'terminal_password')
HA_TOKEN_USER=$(bashio::config 'homeassistant_token')
TZNAME=$(bashio::config 'timezone')
ENABLE_TERMINAL=$(bashio::config 'enable_terminal')
ANTHROPIC_API_KEY=$(bashio::config 'anthropic_api_key')

# ─── Validate required ──────────────────────────────────────────────────────
if [ -z "${WEBUI_PASSWORD}" ]; then
    bashio::log.fatal "webui_password is required (open Configuration tab)"
    exit 1
fi
if bashio::var.true "${ENABLE_TERMINAL}" && [ -z "${TERMINAL_PASSWORD}" ]; then
    bashio::log.fatal "terminal_password is required when enable_terminal=true"
    exit 1
fi

# ─── Resolve HA token: user option > SUPERVISOR_TOKEN ───────────────────────
# homeassistant_api: true in config.yaml causes Supervisor to inject
# SUPERVISOR_TOKEN into the container env and route http://supervisor/core
# to the HA Core API. This means the user does NOT need to create a
# Long-Lived Access Token — the supervisor proxy handles auth.
if [ -n "${HA_TOKEN_USER}" ]; then
    HA_TOKEN="${HA_TOKEN_USER}"
    HASS_URL="http://homeassistant.local:8123"
    bashio::log.info "Using user-supplied homeassistant_token (LLA)"
elif [ -n "${SUPERVISOR_TOKEN:-}" ]; then
    HA_TOKEN="${SUPERVISOR_TOKEN}"
    HASS_URL="http://supervisor/core"
    bashio::log.info "Using auto-injected SUPERVISOR_TOKEN (via Supervisor proxy)"
else
    HA_TOKEN=""
    HASS_URL=""
    bashio::log.warning "No HA token available — HA integration will be disabled"
fi

# ─── Timezone ────────────────────────────────────────────────────────────────
export TZ="${TZNAME}"
if [ -f "/usr/share/zoneinfo/${TZNAME}" ]; then
    cp "/usr/share/zoneinfo/${TZNAME}" /etc/localtime
    echo "${TZNAME}" > /etc/timezone
fi

# ─── Persistent dirs ────────────────────────────────────────────────────────
mkdir -p /data/hermes /data/hermes/webui

# ─── .env (mode 600 — secrets) ──────────────────────────────────────────────
ENV_FILE=/data/hermes/.env
( umask 077 && : > "${ENV_FILE}" )
if [ -n "${HA_TOKEN}" ]; then
    echo "HASS_TOKEN=${HA_TOKEN}" >> "${ENV_FILE}"
    echo "HASS_URL=${HASS_URL}"   >> "${ENV_FILE}"
fi
if [ -n "${ANTHROPIC_API_KEY}" ]; then
    echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" >> "${ENV_FILE}"
fi

# Optional Claude OAuth credentials from /config
if [ -f "/config/claude_credentials.json" ]; then
    bashio::log.info "Loading Claude OAuth credentials from /config/claude_credentials.json"
    OAUTH_TOKEN=$(python3 -c "
import json, sys
try:
    d = json.load(open('/config/claude_credentials.json'))
    print(d.get('claudeAiOauth', {}).get('accessToken', ''))
except Exception:
    pass
" 2>/dev/null) || true
    if [ -n "${OAUTH_TOKEN}" ]; then
        echo "CLAUDE_CODE_OAUTH_TOKEN=${OAUTH_TOKEN}" >> "${ENV_FILE}"
        bashio::log.info "Claude OAuth token loaded"
    else
        bashio::log.warning "claude_credentials.json present but no accessToken extracted"
    fi
fi
chmod 600 "${ENV_FILE}"

# ─── Hermes config.yaml (created once, user-editable via WebUI) ─────────────
HERMES_CONFIG=/data/hermes/config.yaml
if [ ! -f "${HERMES_CONFIG}" ]; then
    bashio::log.info "Creating initial Hermes config.yaml"
    {
        echo "platforms:"
        echo "  homeassistant:"
        echo "    enabled: true"
        echo "    extra:"
        echo "      cooldown_seconds: 60"
        if bashio::config.has_value 'watch_entities'; then
            echo "      watch_entities:"
            for entity in $(bashio::config 'watch_entities'); do
                echo "        - ${entity}"
            done
        fi
    } > "${HERMES_CONFIG}"
fi

# ─── First-run: mirror pre-baked agent into /data/hermes ────────────────────
# /opt/hermes-agent ships in the image (pre-baked at build time). On first
# start we copy the venv + state into /data/hermes so it persists across
# container rebuilds and the user can edit /data/hermes/config.yaml.
BOOTSTRAP_LOCK=/data/hermes/.bootstrap-lock
BOOTSTRAP_DONE=/data/hermes/.bootstrap-done

if [ ! -f "${BOOTSTRAP_DONE}" ]; then
    touch "${BOOTSTRAP_LOCK}"
    if [ -d /opt/hermes-agent/venv ]; then
        bashio::log.info "First run — mirroring pre-baked Hermes agent into /data/hermes"
        # rsync would be ideal but we don't ship it; cp -a preserves modes
        if [ ! -d /data/hermes/venv ]; then
            cp -a /opt/hermes-agent/venv /data/hermes/venv
        fi
        # Copy any agent-side default config files
        for f in /opt/hermes-agent/*.yaml /opt/hermes-agent/*.toml; do
            [ -f "$f" ] && cp -n "$f" /data/hermes/ || true
        done
        bashio::log.info "Agent mirrored"
    else
        bashio::log.warning "Pre-bake missing — bootstrap.py will install on first webui start (5-10 min)"
    fi
    touch "${BOOTSTRAP_DONE}"
    rm -f "${BOOTSTRAP_LOCK}"
fi

# ─── Export envs for hermes-webui ───────────────────────────────────────────
export HERMES_HOME=/data/hermes
export HERMES_WEBUI_STATE_DIR=/data/hermes/webui
export HERMES_WEBUI_HOST=127.0.0.1
export HERMES_WEBUI_PORT="${WEBUI_PORT}"
export HERMES_WEBUI_PASSWORD="${WEBUI_PASSWORD}"
export HERMES_CONFIG_PATH=/data/hermes/config.yaml
export HERMES_WEBUI_PRESERVE_ENV=1

# ─── ttyd (background, gated on bootstrap) ──────────────────────────────────
if bashio::var.true "${ENABLE_TERMINAL}"; then
    bashio::log.info "Starting setup terminal on port ${TERMINAL_PORT}"
    /usr/local/bin/ttyd \
        --port "${TERMINAL_PORT}" \
        --interface 0.0.0.0 \
        --credential "hermes:${TERMINAL_PASSWORD}" \
        --writable \
        --check-origin \
        bash -l -c "
            # Wait for bootstrap to finish so user shells start in a sane state
            while [ -f ${BOOTSTRAP_LOCK} ]; do
                echo 'Waiting for Hermes bootstrap…'; sleep 2;
            done
            export HERMES_HOME=/data/hermes
            export PATH=\"\${HERMES_HOME}/venv/bin:/opt/hermes-webui/.venv/bin:\${PATH}\"
            cd \${HERMES_HOME}
            echo ''
            echo '=================================================='
            echo '  Hermes Setup Terminal'
            echo '  Run:  hermes setup     (configure LLM provider)'
            echo '        hermes status    (verify install)'
            echo '        hermes --help'
            echo '=================================================='
            exec bash
        " \
        &
    bashio::log.info "ttyd PID=$!"
fi

# ─── Start hermes-webui (foreground) ────────────────────────────────────────
bashio::log.info "Starting Hermes Web UI on 127.0.0.1:${WEBUI_PORT} (HA Ingress)"
cd /opt/hermes-webui
exec "${HERMES_WEBUI_PYTHON}" /opt/hermes-webui/bootstrap.py --no-browser
