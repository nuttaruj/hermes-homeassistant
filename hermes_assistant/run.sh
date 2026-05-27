#!/usr/bin/with-contenv bashio
# Hermes Assistant — Home Assistant add-on entrypoint
#
# Process tree (PID 1 = nginx):
#   nginx :8787      (Ingress target, multiplexes:)
#     ├── /          → webui at 127.0.0.1:8788
#     └── /terminal/ → ttyd  at 127.0.0.1:7681 (--base-path /terminal/)
#   webui-server.py  (bg, bound 127.0.0.1:8788)
#   ttyd             (bg, bound 127.0.0.1:7681)
#
# First boot mirrors the agent + webui from /opt seeds into /data so user
# updates ('hermes update', git pull) persist across image rebuilds.
set -e

WEBUI_PORT=8788
TERMINAL_PORT=7681
INGRESS_PORT=8787

AGENT_DST=/data/hermes/agent-code
AGENT_SRC=/opt/hermes-agent-code
WEBUI_DST=/data/hermes/webui-app
WEBUI_SRC=/opt/hermes-webui

# ─── Read options ───────────────────────────────────────────────────────────
HA_TOKEN_USER=$(bashio::config 'homeassistant_token')
TZNAME=$(bashio::config 'timezone')
ENABLE_TERMINAL=$(bashio::config 'enable_terminal')
AUTO_UPDATE_AGENT=$(bashio::config 'auto_update_agent')
AUTO_UPDATE_WEBUI=$(bashio::config 'auto_update_webui')
AUTO_CONFIGURE_MCP=$(bashio::config 'auto_configure_mcp')

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

# ─── .env (mode 600 — secrets, MANAGED + USER lines coexist) ────────────────
# We ONLY rewrite the keys this script owns (HASS_TOKEN, HASS_URL,
# CLAUDE_CODE_OAUTH_TOKEN). Anything the user added via `hermes setup`
# (ANTHROPIC_API_KEY, OPENAI_API_KEY, custom provider configs, …) is
# preserved across boots — a previous version truncated the file each
# start and wiped those keys.
ENV_FILE=/data/hermes/.env
( umask 077 && touch "${ENV_FILE}" )
MANAGED_KEYS=(HASS_TOKEN HASS_URL CLAUDE_CODE_OAUTH_TOKEN)
for k in "${MANAGED_KEYS[@]}"; do
    sed -i "/^${k}=/d" "${ENV_FILE}"
done

if [ -n "${HA_TOKEN}" ]; then
    {
        echo "HASS_TOKEN=${HA_TOKEN}"
        echo "HASS_URL=${HASS_URL}"
    } >> "${ENV_FILE}"
fi

if [ -f "/config/claude_credentials.json" ]; then
    OAUTH_TOKEN=$(python3 -c "
import json
try:
    d = json.load(open('/config/claude_credentials.json'))
    print(d.get('claudeAiOauth', {}).get('accessToken', ''))
except Exception:
    pass
" 2>/dev/null) || true
    if [ -n "${OAUTH_TOKEN}" ]; then
        echo "CLAUDE_CODE_OAUTH_TOKEN=${OAUTH_TOKEN}" >> "${ENV_FILE}"
        bashio::log.info "Claude OAuth token loaded from /config"
    fi
    # Also mirror the file to the path Hermes' webui polls
    # (~/.claude/.credentials.json) so the "Login with Claude Code"
    # button in the onboarding wizard detects existing credentials
    # instead of waiting forever for a fresh in-container OAuth.
    mkdir -p /root/.claude
    cp /config/claude_credentials.json /root/.claude/.credentials.json
    chmod 600 /root/.claude/.credentials.json
    bashio::log.info "Mirrored credentials to ~/.claude/.credentials.json"
fi
chmod 600 "${ENV_FILE}"

# ─── Hermes config.yaml (created once) ──────────────────────────────────────
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

# ─── Auto-configure HA Core's MCP Server as a Hermes MCP source ─────────────
# Uses HA's Streamable HTTP endpoint /api/mcp (the preferred transport per
# HA core source; /mcp_server/sse still works but is the legacy path).
# Omitting `transport:` lets Hermes default to streamable_http when `url`
# is set (see hermes-agent/tools/mcp_tool.py).
#
# Idempotent: rewrites the `homeassistant` entry under mcp_servers every
# boot so the SUPERVISOR_TOKEN stays fresh (rotates between sessions).
# Other mcp_servers entries the user has added by hand are preserved.
if bashio::var.true "${AUTO_CONFIGURE_MCP}" && [ -n "${HA_TOKEN}" ]; then
    bashio::log.info "auto_configure_mcp=true — wiring HA MCP Server into config.yaml"
    /opt/hermes-webui/.venv/bin/python - "${HERMES_CONFIG}" "${HASS_URL}" "${HA_TOKEN}" <<'PY'
import sys, yaml
path, hass_url, hass_token = sys.argv[1:4]
try:
    with open(path) as f:
        cfg = yaml.safe_load(f) or {}
except FileNotFoundError:
    cfg = {}
cfg.setdefault("mcp_servers", {})
cfg["mcp_servers"]["homeassistant"] = {
    "url": f"{hass_url.rstrip('/')}/api/mcp",
    "headers": {"Authorization": f"Bearer {hass_token}"},
}
with open(path, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
print(f"[mcp] wrote homeassistant → {hass_url}/api/mcp (streamable_http)")
PY
    chmod 600 "${HERMES_CONFIG}"
fi

# ─── Mirror image seed to /data (first boot only) ───────────────────────────
BOOTSTRAP_LOCK=/data/hermes/.bootstrap-lock

mirror_with_shebang_fix() {
    local src=$1 dst=$2
    bashio::log.info "Mirroring ${src} → ${dst} (this may take ~30s on slow storage)"
    cp -a "${src}" "${dst}"
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

[ -d "${AGENT_DST}/venv" ] && AGENT_DIR="${AGENT_DST}" || AGENT_DIR="${AGENT_SRC}"
[ -d "${WEBUI_DST}/.venv" ] && WEBUI_DIR="${WEBUI_DST}" || WEBUI_DIR="${WEBUI_SRC}"
bashio::log.info "Agent dir: ${AGENT_DIR}"
bashio::log.info "WebUI dir: ${WEBUI_DIR}"

# ─── Optional auto-updates ──────────────────────────────────────────────────
if bashio::var.true "${AUTO_UPDATE_AGENT}" && [ -d "${AGENT_DST}/.git" ]; then
    bashio::log.info "auto_update_agent=true — running hermes update"
    HERMES_HOME=/data/hermes /usr/local/bin/hermes update 2>&1 \
        | sed 's/^/  [hermes update] /' || \
        bashio::log.warning "hermes update failed — continuing"
fi

if bashio::var.true "${AUTO_UPDATE_WEBUI}" && [ -d "${WEBUI_DST}/.git" ]; then
    bashio::log.info "auto_update_webui=true — git pull hermes-webui"
    (cd "${WEBUI_DST}" && git pull --ff-only 2>&1 | sed 's/^/  [webui pull] /') || \
        bashio::log.warning "webui git pull failed — continuing"
fi

# ─── Export envs for hermes-webui ───────────────────────────────────────────
export HERMES_HOME=/data/hermes
export HERMES_INSTALL_DIR="${AGENT_DIR}"
export HERMES_WEBUI_AGENT_DIR="${AGENT_DIR}"
export HERMES_WEBUI_STATE_DIR=/data/hermes/webui
# Bind 0.0.0.0 inside the container. webui prints/embeds "$HOST:$PORT" in
# the served HTML; with HOST=127.0.0.1 the browser would try to reach
# the webui's own loopback (which only exists inside the container) and
# get "refused to connect". 0.0.0.0 in those self-references causes the
# webui to fall back to window.location, which works through Ingress.
# nginx still proxies to 127.0.0.1:${WEBUI_PORT} because 0.0.0.0 bind
# accepts loopback connections.
export HERMES_WEBUI_HOST=0.0.0.0
export HERMES_WEBUI_PORT="${WEBUI_PORT}"
# Use the AGENT venv (not the webui venv) — it has hermes-agent
# installed editable plus every transitive dep webui needs at import
# time (dotenv, anthropic SDK, …). The webui-only venv was minimal
# (pyyaml + cryptography), which caused 'AIAgent not available' /
# ModuleNotFoundError: No module named 'dotenv' the moment the user
# tried to chat.
export HERMES_WEBUI_PYTHON="${AGENT_DIR}/venv/bin/python"
export HERMES_CONFIG_PATH=/data/hermes/config.yaml
export HERMES_WEBUI_PRESERVE_ENV=1

# ─── Start webui (background, loopback only — nginx fronts it) ──────────────
bashio::log.info "Starting Hermes Web UI bg on 0.0.0.0:${WEBUI_PORT} (nginx fronts via loopback)"
cd "${WEBUI_DIR}"
"${HERMES_WEBUI_PYTHON}" "${WEBUI_DIR}/server.py" &
WEBUI_PID=$!
bashio::log.info "webui PID=${WEBUI_PID}"

# ─── Start ttyd (background, loopback only — nginx fronts it) ───────────────
if bashio::var.true "${ENABLE_TERMINAL}"; then
    # No --credential: ttyd binds 127.0.0.1 and is reachable only through
    # HA Ingress (panel_admin: true). The HA admin who can open the panel
    # is already trusted; a second password prompt would just slow them
    # down to no security benefit.
    bashio::log.info "Starting ttyd bg on 127.0.0.1:${TERMINAL_PORT} (/terminal/, no auth — HA Ingress gates access)"
    /usr/local/bin/ttyd \
        --port "${TERMINAL_PORT}" \
        --interface 127.0.0.1 \
        --base-path /terminal \
        --writable \
        --check-origin \
        bash -l -c "
            while [ -f ${BOOTSTRAP_LOCK} ]; do
                echo 'Waiting for Hermes bootstrap…'; sleep 2;
            done
            export HERMES_HOME=/data/hermes
            export HERMES_INSTALL_DIR=${AGENT_DIR}
            export PATH=\"${AGENT_DIR}/venv/bin:${WEBUI_DIR}/.venv/bin:/opt/hermes-agent/node/bin:/usr/local/bin:\${PATH}\"
            cd \${HERMES_HOME}
            echo ''
            echo '=================================================='
            echo '  Hermes Setup Terminal'
            echo '=================================================='
            echo ''
            echo '  Configure any LLM provider:'
            echo '    hermes setup     interactive wizard'
            echo '    hermes model     pick / switch provider+model'
            echo '    hermes update    pull latest agent'
            echo '    hermes --help    all commands'
            echo ''
            echo '  Start with `hermes setup` — it walks through every'
            echo '  supported provider (Anthropic, OpenAI, Google,'
            echo '  OpenRouter, Copilot, local models, …) and saves'
            echo '  credentials to /data/hermes/.env.'
            echo ''
            echo '=================================================='
            exec bash
        " &
    TTYD_PID=$!
    bashio::log.info "ttyd PID=${TTYD_PID}"
fi

# ─── nginx (foreground, PID 1) ──────────────────────────────────────────────
bashio::log.info "Starting nginx :${INGRESS_PORT} multiplex (/, /terminal/)"
exec /usr/sbin/nginx -c /etc/nginx/nginx.conf
