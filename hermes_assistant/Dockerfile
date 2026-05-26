ARG BUILD_FROM
FROM ${BUILD_FROM}

# ─── Build args ─────────────────────────────────────────────────────────────
# Pinned hermes-webui release (https://github.com/nesquena/hermes-webui/releases).
# Bump and rebuild the addon to upgrade.
ARG HERMES_WEBUI_REF=v0.51.137
ARG TTYD_VERSION=1.7.7

# ─── Environment ────────────────────────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HERMES_HOME=/data/hermes \
    HERMES_WEBUI_AGENT_DIR=/opt/hermes-agent \
    HERMES_WEBUI_STATE_DIR=/data/hermes/webui \
    HERMES_WEBUI_HOST=127.0.0.1 \
    HERMES_WEBUI_PORT=8787 \
    PATH=/root/.local/bin:/usr/local/bin:/usr/bin:/bin

# ─── System packages ────────────────────────────────────────────────────────
# python3 (3.11 on bookworm — Hermes supports 3.10+), build deps for any
# native wheels, ttyd downloaded as static binary (not in bookworm apt).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        git \
        bash \
        jq \
        tini \
        tzdata \
        openssh-client \
        python3 \
        python3-venv \
        python3-pip \
        ripgrep \
        ffmpeg \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# ─── ttyd (web terminal) ────────────────────────────────────────────────────
# Static binary release; ARCH derived from dpkg.
RUN set -eux; \
    DPKG_ARCH="$(dpkg --print-architecture)"; \
    case "${DPKG_ARCH}" in \
      amd64)   TTYD_ARCH="x86_64" ;; \
      arm64)   TTYD_ARCH="aarch64" ;; \
      *)       echo "unsupported arch: ${DPKG_ARCH}"; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/ttyd \
      "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}"; \
    chmod +x /usr/local/bin/ttyd; \
    /usr/local/bin/ttyd --version

# ─── uv (Astral) — used by Hermes installer and bootstrap.py ────────────────
RUN curl -LsSf https://astral.sh/uv/install.sh \
      | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh \
    && uv --version

# ─── hermes-webui ───────────────────────────────────────────────────────────
RUN git clone --depth=1 --branch "${HERMES_WEBUI_REF}" \
        https://github.com/nesquena/hermes-webui.git /opt/hermes-webui \
    && echo "__version__ = '${HERMES_WEBUI_REF}'" > /opt/hermes-webui/api/_version.py

# Pre-create the webui venv with deps. Heavy hermes-agent install happens
# on first run via run.sh (cached into /data/hermes which persists).
RUN uv venv /opt/hermes-webui/.venv --python python3 \
    && /opt/hermes-webui/.venv/bin/python -m pip install --upgrade pip \
    && /opt/hermes-webui/.venv/bin/python -m pip install --no-cache-dir \
         -r /opt/hermes-webui/requirements.txt

ENV HERMES_WEBUI_PYTHON=/opt/hermes-webui/.venv/bin/python

# ─── Add-on scripts ─────────────────────────────────────────────────────────
COPY run.sh /run.sh
RUN chmod +x /run.sh

# Ports: webui on 8787 (Ingress), ttyd on 7681 (host network).
EXPOSE 8787 7681

# tini reaps zombies from the bg ttyd process and forwards signals to webui.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/run.sh"]
