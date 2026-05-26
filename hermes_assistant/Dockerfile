# =============================================================================
# Hermes Assistant — multi-stage build
#   Stage 1 (builder): build-essential + uv + clone webui + pre-bake hermes-agent
#   Stage 2 (runtime): minimal apt, copy artefacts from builder
# Net result: ~200MB smaller than single-stage, hermes-agent pre-installed so
# first start is instant (no 5-10 min download).
# =============================================================================

ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base-debian:bookworm

# ─── Stage 1 — builder ──────────────────────────────────────────────────────
FROM ${BUILD_FROM} AS builder

ARG HERMES_WEBUI_REF=v0.51.137
ARG HERMES_AGENT_REF=main
ARG TTYD_VERSION=1.7.7

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/usr/local/bin:/usr/bin:/bin

# Build-time apt — wheels usually exist for our deps, but compiler is needed
# for hermes-agent which pulls a larger dep tree (some may need C extensions).
# ripgrep is included so install.sh stops warning about missing rg.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        python3 \
        python3-venv \
        build-essential \
        python3-dev \
        libffi-dev \
        libssl-dev \
        ripgrep \
    && rm -rf /var/lib/apt/lists/*

# ttyd static binary
RUN set -eux; \
    DPKG_ARCH="$(dpkg --print-architecture)"; \
    case "${DPKG_ARCH}" in \
      amd64)  TTYD_ARCH="x86_64"  ;; \
      arm64)  TTYD_ARCH="aarch64" ;; \
      *) echo "unsupported arch: ${DPKG_ARCH}"; exit 1 ;; \
    esac; \
    curl -fsSL -o /opt/ttyd \
      "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}"; \
    chmod +x /opt/ttyd; \
    /opt/ttyd --version

# uv
RUN curl -LsSf https://astral.sh/uv/install.sh \
      | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh \
    && uv --version

# Clone hermes-webui at pinned tag + bake version.
# Keep .git (small after gc) so `git pull` works when mirrored to /data and
# auto_update_webui=true. Use --depth=1 to minimize clone size.
RUN git clone --depth=1 --branch "${HERMES_WEBUI_REF}" \
        https://github.com/nesquena/hermes-webui.git /opt/hermes-webui \
    && echo "__version__ = '${HERMES_WEBUI_REF}'" > /opt/hermes-webui/api/_version.py

# WebUI venv with minimal deps (pyyaml + cryptography)
RUN uv venv /opt/hermes-webui/.venv --python python3 \
    && uv pip install --python /opt/hermes-webui/.venv/bin/python \
         --no-cache \
         -r /opt/hermes-webui/requirements.txt

# Pre-bake hermes-agent.
# install.sh clones the repo via git + creates a uv-managed venv. We use
# --skip-setup (no wizard) and --skip-browser (no Playwright/Chromium).
# Best-effort: if install fails, image still builds — run.sh retries at
# first runtime start. Log preserved at /opt/hermes-agent/install.log for
# debugging when something goes wrong.
RUN set +e; \
    mkdir -p /opt/hermes-agent; \
    export HERMES_HOME=/opt/hermes-agent; \
    export HERMES_INSTALL_DIR=/opt/hermes-agent-code; \
    export UV_NO_CONFIG=1; \
    export PATH="/usr/local/bin:${PATH}"; \
    curl -fsSL "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_AGENT_REF}/scripts/install.sh" \
      -o /tmp/install-hermes.sh; \
    if [ ! -s /tmp/install-hermes.sh ]; then \
        echo ">> WARN: installer download failed, skipping pre-bake"; \
        exit 0; \
    fi; \
    bash /tmp/install-hermes.sh \
        --skip-setup \
        --skip-browser \
        --branch "${HERMES_AGENT_REF}" \
        > /opt/hermes-agent/install.log 2>&1; \
    rc=$?; \
    # Locate the venv install.sh actually created — could be at any of:
    #   $HERMES_INSTALL_DIR/.venv       (uv install in repo)
    #   $HERMES_HOME/venv               (pip mode)
    #   $HERMES_INSTALL_DIR/venv
    AGENT_VENV=""; \
    for cand in /opt/hermes-agent-code/.venv /opt/hermes-agent/venv /opt/hermes-agent-code/venv; do \
        if [ -x "$cand/bin/hermes" ] || [ -x "$cand/bin/python" ]; then \
            AGENT_VENV="$cand"; break; \
        fi; \
    done; \
    if [ $rc -eq 0 ] && [ -n "$AGENT_VENV" ]; then \
        echo ">> Hermes agent pre-baked OK at $AGENT_VENV"; \
        echo "$AGENT_VENV" > /opt/hermes-agent/.venv-path; \
        touch /opt/hermes-agent/.prebaked; \
    else \
        echo ">> WARN: pre-bake failed (rc=$rc, venv=$AGENT_VENV)"; \
        echo ">> Last 60 lines of install log:"; \
        tail -60 /opt/hermes-agent/install.log || true; \
    fi; \
    rm -f /tmp/install-hermes.sh; \
    exit 0

# Strip caches + non-runtime artefacts.
# KEEP .git for both repos so user can `hermes update` / `git pull` in the
# live install (mirrored to /data on first boot).
RUN set -eux; \
    find /opt/hermes-agent /opt/hermes-webui -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true; \
    rm -rf \
        /opt/hermes-agent-code/ui-tui \
        /opt/hermes-agent-code/website \
        /opt/hermes-agent-code/tests \
        /opt/hermes-agent-code/node_modules \
        /opt/hermes-agent-code/docs \
        /opt/hermes-agent-code/RELEASE_*.md \
        /opt/hermes-webui/tests \
        /opt/hermes-webui/docs \
        /root/.cache /tmp/* /var/tmp/* 2>/dev/null || true; \
    find /opt/hermes-agent-code -type d -name "test" -prune -exec rm -rf {} + 2>/dev/null || true; \
    find /opt/hermes-agent-code -type d -name "tests" -prune -exec rm -rf {} + 2>/dev/null || true; \
    # Aggressive .git gc so the kept history doesn't bloat the seed
    for d in /opt/hermes-agent-code /opt/hermes-webui; do \
        if [ -d "$d/.git" ]; then \
            git -C "$d" gc --aggressive --prune=now 2>/dev/null || true; \
        fi; \
    done; \
    echo "size after trim:"; du -sh /opt/hermes-agent-code /opt/hermes-agent /opt/hermes-webui


# ─── Stage 2 — runtime (minimal) ────────────────────────────────────────────
FROM ${BUILD_FROM}

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HERMES_HOME=/data/hermes \
    HERMES_WEBUI_AGENT_DIR=/opt/hermes-agent \
    HERMES_WEBUI_STATE_DIR=/data/hermes/webui \
    HERMES_WEBUI_HOST=127.0.0.1 \
    HERMES_WEBUI_PORT=8787 \
    HERMES_WEBUI_PYTHON=/opt/hermes-webui/.venv/bin/python \
    PATH=/usr/local/bin:/usr/bin:/bin

# Runtime apt — no compilers, no pip, no tini, no tzdata (base has it).
# Keep: bash/curl/git/jq/python/openssh-client/ffmpeg/ripgrep — used by Hermes
# tools at runtime.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        bash \
        jq \
        python3 \
        openssh-client \
        ffmpeg \
        ripgrep \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Bring binaries + venvs from builder
COPY --from=builder /opt/ttyd                 /usr/local/bin/ttyd
COPY --from=builder /usr/local/bin/uv         /usr/local/bin/uv
COPY --from=builder /usr/local/bin/uvx        /usr/local/bin/uvx
COPY --from=builder /opt/hermes-webui         /opt/hermes-webui
COPY --from=builder /opt/hermes-agent         /opt/hermes-agent
COPY --from=builder /opt/hermes-agent-code    /opt/hermes-agent-code

# `hermes` dispatcher — prefers the user-writable mirror at /data
# (where updates persist), falls back to the pre-baked image copy at /opt
# during first boot before run.sh has mirrored.
RUN printf '%s\n' \
    '#!/bin/bash' \
    '# Prefer mirrored install at /data (persists across rebuilds);' \
    '# fall back to baked-in image copy on first boot.' \
    'if [ -x /data/hermes/agent-code/venv/bin/python ]; then' \
    '    exec /data/hermes/agent-code/venv/bin/python /data/hermes/agent-code/hermes "$@"' \
    'elif [ -x /opt/hermes-agent-code/venv/bin/python ]; then' \
    '    exec /opt/hermes-agent-code/venv/bin/python /opt/hermes-agent-code/hermes "$@"' \
    'else' \
    '    echo "hermes: agent not installed" >&2; exit 127' \
    'fi' \
    > /usr/local/bin/hermes \
    && chmod +x /usr/local/bin/hermes

# Add-on entrypoint
COPY run.sh /run.sh
RUN chmod +x /run.sh

EXPOSE 8787 7681

# HA + docker observability. Webui /health responds 200 when ready.
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8787/health || exit 1

# Defer to HA base s6-overlay ENTRYPOINT — it sets up bashio with-contenv.
CMD ["/run.sh"]
