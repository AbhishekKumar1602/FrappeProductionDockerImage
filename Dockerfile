# syntax=docker/dockerfile:1.6

##########################
#          BASE          #
##########################
ARG PYTHON_VERSION=3.11.6
ARG DEBIAN_BASE=bookworm
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_BASE} AS base

COPY nginx-template.conf  /templates/nginx/frappe.conf.template
COPY nginx-entrypoint.sh  /usr/local/bin/nginx-entrypoint.sh

ARG WKHTMLTOPDF_VERSION=0.12.6.1-3
ARG WKHTMLTOPDF_DISTRO=bookworm
ARG NODE_VERSION=20.19.2
ENV NVM_DIR=/home/frappe/.nvm
ENV PATH=${NVM_DIR}/versions/node/v${NODE_VERSION}/bin/:${PATH}

RUN useradd -ms /bin/bash frappe \
 && apt-get update \
 && apt-get install --no-install-recommends -y \
    curl git vim nginx gettext-base file ca-certificates \
    libpango-1.0-0 libharfbuzz0b libpangoft2-1.0-0 libpangocairo-1.0-0 \
    restic gpg \
    mariadb-client less libpq-dev postgresql-client \
    jq wget \
    tini gosu libcap2-bin \
    redis-tools \
 && mkdir -p ${NVM_DIR} \
 && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.5/install.sh | bash \
 && . ${NVM_DIR}/nvm.sh \
 && nvm install ${NODE_VERSION} \
 && nvm use v${NODE_VERSION} \
 && npm install -g yarn \
 && nvm alias default v${NODE_VERSION} \
 && rm -rf ${NVM_DIR}/.cache \
 && echo 'export NVM_DIR="/home/frappe/.nvm"' >>/home/frappe/.bashrc \
 && echo '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' >>/home/frappe/.bashrc \
 && echo '[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"' >>/home/frappe/.bashrc \
 && ln -sf ${NVM_DIR}/versions/node/v${NODE_VERSION}/bin/node /usr/local/bin/node \
 && ln -sf ${NVM_DIR}/versions/node/v${NODE_VERSION}/bin/npm  /usr/local/bin/npm  \
 && ln -sf ${NVM_DIR}/versions/node/v${NODE_VERSION}/bin/yarn /usr/local/bin/yarn \
 && chown -R frappe:frappe ${NVM_DIR} \
 && export ARCH="$( [ "$(uname -m)" = "aarch64" ] && echo arm64 || echo amd64 )" \
 && f=wkhtmltox_${WKHTMLTOPDF_VERSION}.${WKHTMLTOPDF_DISTRO}_${ARCH}.deb \
 && curl -sLO https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/${f} \
 && apt-get install -y ./${f} \
 && rm -f ${f} \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/nginx/sites-enabled/default \
 && sed -i '/^user /d' /etc/nginx/nginx.conf \
 && ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log \
 && touch /run/nginx.pid \
 && chown -R frappe:frappe /etc/nginx /var/log/nginx /var/lib/nginx /run/nginx.pid \
 && chmod 755 /usr/local/bin/nginx-entrypoint.sh \
 && chmod 644 /templates/nginx/frappe.conf.template \
 && pip3 install --no-cache-dir frappe-bench \
 && sed -i 's/listen 8080;/listen 80;/' /templates/nginx/frappe.conf.template \
 && sed -i 's/server_name .*/server_name _;/' /templates/nginx/frappe.conf.template \
 && setcap cap_net_bind_service=+ep /usr/sbin/nginx

#############################
#          BUILDER          #
#############################
FROM base AS builder

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -euo pipefail; \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
      build-essential gcc \
      libffi-dev libbz2-dev libtiff5-dev libwebp-dev tk8.6-dev \
      libldap2-dev libsasl2-dev libmariadb-dev libpq-dev \
      libcairo2-dev libpango1.0-dev libjpeg-dev libgif-dev librsvg2-dev \
      liblcms2-dev pkg-config rlwrap redis-tools cron wget \
    && rm -rf /var/lib/apt/lists/*

ARG APPS_JSON_BASE64
RUN if [ -n "${APPS_JSON_BASE64:-}" ]; then \
      mkdir -p /opt/frappe && echo "${APPS_JSON_BASE64}" | base64 -d > /opt/frappe/apps.json && chown -R frappe:frappe /opt/frappe; \
    fi

USER frappe
WORKDIR /home/frappe

ARG FRAPPE_BRANCH=version-15
ARG FRAPPE_PATH=https://github.com/frappe/frappe

RUN set -euo pipefail; \
    APP_INSTALL_ARGS=""; \
    if [ -s /opt/frappe/apps.json ]; then APP_INSTALL_ARGS="--apps_path=/opt/frappe/apps.json"; fi; \
    bench init ${APP_INSTALL_ARGS} \
      --frappe-branch="${FRAPPE_BRANCH}" \
      --frappe-path="${FRAPPE_PATH}" \
      --no-procfile --no-backups --skip-redis-config-generation --verbose \
      /home/frappe/frappe-bench; \
    cd /home/frappe/frappe-bench; \
    echo '{}' > sites/common_site_config.json; \
    bench build --production --verbose; \
    find apps -mindepth 1 -path '*/.git' -prune -exec rm -rf {} +; \
    find . -name '__pycache__' -type d -prune -exec rm -rf {} +; \
    rm -f /opt/frappe/apps.json || true

###########################
#          FINAL          #
###########################
FROM base AS backend

RUN apt-get update && apt-get install -y --no-install-recommends supervisor \
 && mkdir -p /etc/supervisor/conf.d /var/log/supervisor /var/run/supervisor \
 && chown -R frappe:frappe /var/log/supervisor /var/run/supervisor \
 && rm -rf /var/lib/apt/lists/*

USER frappe
WORKDIR /home/frappe/frappe-bench
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench

USER root
COPY supervisord.conf /etc/supervisor/conf.d/frappe.conf
COPY frappe-entrypoint.sh /usr/local/bin/frappe-entrypoint.sh
RUN chmod +x /usr/local/bin/frappe-entrypoint.sh

VOLUME [ "/home/frappe/frappe-bench/sites", "/home/frappe/frappe-bench/logs" ]

ENV BACKEND=127.0.0.1:8000 \
    SOCKETIO=127.0.0.1:9000 \
    UPSTREAM_REAL_IP_ADDRESS=127.0.0.1 \
    UPSTREAM_REAL_IP_HEADER=X-Forwarded-For \
    UPSTREAM_REAL_IP_RECURSIVE=off \
    PROXY_READ_TIMEOUT=120 \
    CLIENT_MAX_BODY_SIZE=50m

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --retries=10 CMD \
  curl -fsS -H "Host: ${SITE:-127.0.0.1}" http://127.0.0.1/api/method/ping || exit 1

ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/frappe-entrypoint.sh"]
CMD ["supervisord","-n","-c","/etc/supervisor/conf.d/frappe.conf"]
