#!/usr/bin/with-contenv bashio
# Hermes Assistant — Home Assistant add-on entrypoint
#
# Lifecycle:
#   1. Validate options
#   2. Resolve HA token (SUPERVISOR_TOKEN auto-fallback)
#   3. Write secrets to /data/hermes/.env (mode 600)
#   4. First-boot: mirror agent + webui from image seed (/opt) to /data,
#      fixing venv shebangs so binaries work from the new path
#   5. Optional: auto-update agent (`hermes update`) and/or webui (`git pull`)
#   6. Start ttyd in background — gated on bootstrap completion
#   7. Exec hermes-webui in foreground (bound 127.0.0.1:8787 → Ingress)
set -e

WEBUI_PORT=8787
TERMINAL_PORT=7681

AGENT_DST=/data/hermes/agent-code
AGENT_SRC=/opt/hermes-agent-code
WEBUI_DST=/data/hermes/webui-app
WEBUI_SRC=/opt/hermes-webui

# ─── Read options ───────────────────────────────────────────────────────────
TERMINAL_PASSWORD=$(bashio::config 'terminal_password')
HA_TOKEN_USER=$(bashio::config 'homeassistant_token')
TZNAME=$(bashio::config 'timezone')
ENABLE_TERMINAL=$(bashio::config 'enable_terminal')
AUTO_UPDATE_AGENT=$(bashio::config 'auto_update_agent')
AUTO_UPDATE_WEBUI=$(bashio::config 'auto_update_webui')
ANTHROPIC_API_KEY=$(bashio::config 'anthropic_api_key')

# ─── Validate required ──────────────────────────────────────────────────────
if bashio::var.true "${ENABLE_TERMINAL}" && [ -z "${TERMINAL_PASSWORD}" ]; then
    bashio::log.fatal "terminal_password is required when enable_terminal=true"
    exit 1
fi

# ─── Resolve HA token: user option > SUPERVISOR_TOKEN ───────────────────────
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
    bashio::log.warning "No HA token available — HA integration disabled"
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
if [ -f "/config/claude_credentials.json" ]; then
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
    fi
fi
chmod 600 "${ENV_FILE}"

# ─── Hermes config.yaml (created once, preserved across updates) ────────────
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

# ─── Mirror image seed to /data (first boot only) ───────────────────────────
# Why: /opt/* is image-immutable. To let `hermes update` / `git pull` persist,
# we mirror once into /data and run from there. Subsequent rebuilds (after
# bumping the add-on) DO NOT overwrite /data — user keeps their version.
BOOTSTRAP_LOCK=/data/hermes/.bootstrap-lock

mirror_with_shebang_fix() {
    local src=$1 dst=$2
    bashio::log.info "Mirroring ${src} → ${dst} (this may take ~30s on slow storage)"
    cp -a "${src}" "${dst}"
    # Rewrite uv-generated absolute-path shebangs in venv binaries so they
    # resolve under the new location. python/python3/python3.X symlinks point
    # at /usr/bin/python3.X (system) and don't need touching.
    for venv_bin in "${dst}/venv/bin" "${dst}/.venv/bin"; do
        if [ -d "${venv_bin}" ]; then
            find "${venv_bin}" -type f -exec sed -i \
                "s|${src}|${dst}|g" {} \; 2>/dev/null || true
        fi
    done
    bashio::log.info "Mirror of $(basename ${dst}) complete ($(du -sh ${dst} | cut -f1))"
}

touch "${BOOTSTRAP_LOCK}"
if [ ! -d "${AGENT_DST}" ] && [ -d "${AGENT_SRC}" ]; then
    mirror_with_shebang_fix "${AGENT_SRC}" "${AGENT_DST}"
fi
if [ ! -d "${WEBUI_DST}" ] && [ -d "${WEBUI_SRC}" ]; then
    mirror_with_shebang_fix "${WEBUI_SRC}" "${WEBUI_DST}"
fi
rm -f "${BOOTSTRAP_LOCK}"

# Determine effective install dirs (mirror if present, else image seed)
[ -d "${AGENT_DST}/venv" ] && AGENT_DIR="${AGENT_DST}" || AGENT_DIR="${AGENT_SRC}"
[ -d "${WEBUI_DST}/.venv" ] && WEBUI_DIR="${WEBUI_DST}" || WEBUI_DIR="${WEBUI_SRC}"
bashio::log.info "Agent dir: ${AGENT_DIR}"
bashio::log.info "WebUI dir: ${WEBUI_DIR}"

# ─── Optional auto-updates ──────────────────────────────────────────────────
if bashio::var.true "${AUTO_UPDATE_AGENT}" && [ -d "${AGENT_DST}/.git" ]; then
    bashio::log.info "auto_update_agent=true — running hermes update"
    HERMES_HOME=/data/hermes /usr/local/bin/hermes update 2>&1 \
        | sed 's/^/  [hermes update] /' || \
        bashio::log.warning "hermes update failed — continuing with current version"
fi

if bashio::var.true "${AUTO_UPDATE_WEBUI}" && [ -d "${WEBUI_DST}/.git" ]; then
    bashio::log.info "auto_update_webui=true — git pull hermes-webui"
    (cd "${WEBUI_DST}" && git pull --ff-only 2>&1 | sed 's/^/  [webui pull] /') || \
        bashio::log.warning "webui git pull failed — continuing with current version"
fi

# ─── Export envs for hermes-webui ───────────────────────────────────────────
export HERMES_HOME=/data/hermes
export HERMES_INSTALL_DIR="${AGENT_DIR}"
export HERMES_WEBUI_AGENT_DIR="${AGENT_DIR}"
export HERMES_WEBUI_STATE_DIR=/data/hermes/webui
# Bind 0.0.0.0 inside the container. HA Ingress reaches the container
# via its bridge-network IP (loopback inside the container is not
# reachable from Supervisor). The port is NOT in `ports:` so the addon
# does NOT expose 8787 to the LAN — only the Ingress proxy can reach it.
export HERMES_WEBUI_HOST=0.0.0.0
export HERMES_WEBUI_PORT="${WEBUI_PORT}"
# NO HERMES_WEBUI_PASSWORD: HA Ingress is the only auth layer. The webui
# post-login redirect bounces to '/' (relative), which the browser inside
# the Ingress iframe resolves against the HA host root — landing the user
# on the HA dashboard instead of the webui. Disabling webui auth removes
# the redirect path entirely. The Ingress panel itself is gated by HA's
# own login + panel_admin: true (admin-only).
export HERMES_WEBUI_PYTHON="${WEBUI_DIR}/.venv/bin/python"
export HERMES_CONFIG_PATH=/data/hermes/config.yaml
export HERMES_WEBUI_PRESERVE_ENV=1

# ─── ttyd (background) ──────────────────────────────────────────────────────
if bashio::var.true "${ENABLE_TERMINAL}"; then
    bashio::log.info "Starting setup terminal on port ${TERMINAL_PORT}"
    /usr/local/bin/ttyd \
        --port "${TERMINAL_PORT}" \
        --interface 0.0.0.0 \
        --credential "hermes:${TERMINAL_PASSWORD}" \
        --writable \
        --check-origin \
        bash -l -c "
            while [ -f ${BOOTSTRAP_LOCK} ]; do
                echo 'Waiting for Hermes bootstrap…'; sleep 2;
            done
            export HERMES_HOME=/data/hermes
            export HERMES_INSTALL_DIR=${AGENT_DIR}
            export PATH=\"${AGENT_DIR}/venv/bin:${WEBUI_DIR}/.venv/bin:/usr/local/bin:\${PATH}\"
            cd \${HERMES_HOME}
            echo ''
            echo '=================================================='
            echo '  Hermes Setup Terminal'
            echo '  Agent: ${AGENT_DIR}'
            echo ''
            echo '  hermes setup      configure LLM provider (one-time)'
            echo '  hermes status     verify install'
            echo '  hermes update     pull latest agent (persists in /data)'
            echo '  hermes --help     all commands'
            echo '=================================================='
            exec bash
        " \
        &
    bashio::log.info "ttyd PID=$!"
fi

# ─── Start hermes-webui (foreground, PID 1) ─────────────────────────────────
# Do NOT use bootstrap.py here — it forks the server to the background and
# exits, which makes PID 1 in the container terminate and triggers an
# HA Supervisor restart loop. server.py is the long-running webui process
# we actually want as PID 1.
bashio::log.info "Starting Hermes Web UI on 0.0.0.0:${WEBUI_PORT} (HA Ingress)"
cd "${WEBUI_DIR}"
exec "${HERMES_WEBUI_PYTHON}" "${WEBUI_DIR}/server.py"
