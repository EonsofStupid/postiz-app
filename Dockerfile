# fuqn.ai base image. Packages this fork of Postiz (AGPL-3.0) for one
# isolated customer instance. Build secrets do not belong in this file.
# Customer URLs and credentials are applied by deploy/fuqn/entrypoint.sh.

ARG NODE_IMAGE=node:22.23.4-bookworm-slim@sha256:5ec23b7c622b00547753bc6ffd78085dd868a68aeb41c8e0a1418f033e13d96d

FROM ${NODE_IMAGE} AS build

ARG NEXT_PUBLIC_VERSION=fuqn-base-0.1.0
ARG FUQN_PUBLIC_BACKEND_PLACEHOLDER=http://fuqn-runtime-backend.invalid/api

ENV NEXT_TELEMETRY_DISABLED=1 \
    DO_NOT_TRACK=1 \
    CHECKPOINT_DISABLE=1 \
    SCARF_ANALYTICS=false \
    DISABLE_OPENCOLLECTIVE=1 \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    COREPACK_DEFAULT_TO_LATEST=0 \
    NEXT_PUBLIC_VERSION=${NEXT_PUBLIC_VERSION} \
    NEXT_PUBLIC_BACKEND_URL=${FUQN_PUBLIC_BACKEND_PLACEHOLDER} \
    STORAGE_PROVIDER=local \
    NODE_ENV=production \
    NODE_OPTIONS=--max-old-space-size=4096

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      python3 \
      make \
      g++ \
 && rm -rf /var/lib/apt/lists/*

RUN corepack enable && corepack prepare pnpm@10.6.1 --activate

WORKDIR /app
COPY . /app

RUN if [ -e /app/.env ] || [ -e /app/.env.local ] || [ -e /app/deploy/fuqn/.env ]; then \
      echo "refusing to build: an env file is in the image context"; \
      exit 1; \
    fi \
 && pnpm install --frozen-lockfile --ignore-scripts \
 && pnpm rebuild bcrypt \
 && pnpm exec prisma generate --schema ./libraries/nestjs-libraries/src/database/prisma/schema.prisma \
 && pnpm run build

FROM ${NODE_IMAGE} AS runtime

ARG FUQN_VERSION=0.1.0
ARG UPSTREAM_VERSION=unknown
ARG GIT_SHA=unknown
ARG NEXT_PUBLIC_VERSION=fuqn-base-0.1.0

LABEL org.opencontainers.image.title="fuqn.ai Postiz base image" \
      org.opencontainers.image.description="Base application image for isolated fuqn.ai instances of Postiz. Postiz is AGPL-3.0. This is not a proprietary white-label build." \
      org.opencontainers.image.source="https://github.com/EonsofStupid/postiz-app" \
      org.opencontainers.image.url="https://github.com/EonsofStupid/postiz-app" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.version="${FUQN_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.vendor="EonsofStupid" \
      org.fuqn.upstream.version="${UPSTREAM_VERSION}" \
      org.fuqn.public-backend-placeholder="http://fuqn-runtime-backend.invalid/api"

ENV NODE_ENV=production \
    TZ=UTC \
    HOME=/www \
    PM2_HOME=/www/.pm2 \
    COREPACK_HOME=/usr/local/share/corepack \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    COREPACK_DEFAULT_TO_LATEST=0 \
    NEXT_TELEMETRY_DISABLED=1 \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NEXT_PUBLIC_VERSION=${NEXT_PUBLIC_VERSION} \
    FUQN_PUBLIC_BACKEND_PLACEHOLDER=http://fuqn-runtime-backend.invalid/api \
    PRISMA_HIDE_UPDATE_MESSAGE=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      nginx \
      tini \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 1001 www \
 && useradd --system --uid 1001 --gid 1001 --home-dir /www --create-home --shell /usr/sbin/nologin www \
 && mkdir -p /uploads /config /www/.pm2 /usr/local/share/corepack \
 && corepack enable \
 && corepack prepare pnpm@10.6.1 --activate \
 && chmod -R a+rX /usr/local/share/corepack \
 && dpkg-query -W -f '${Package}=${Version}\n' bash ca-certificates nginx tini > /etc/fuqn-os-packages.txt

WORKDIR /opt/fuqn-pm2
COPY deploy/fuqn/pm2/package.json deploy/fuqn/pm2/package-lock.json ./
RUN npm ci --omit=dev \
 && ln -sf /opt/fuqn-pm2/node_modules/.bin/pm2 /usr/local/bin/pm2 \
 && ln -sf /opt/fuqn-pm2/node_modules/.bin/pm2-runtime /usr/local/bin/pm2-runtime \
 && npm cache clean --force

WORKDIR /app
COPY --from=build --chown=www:www /app /app
COPY --chown=www:www deploy/fuqn/NOTICE /app/NOTICE
COPY deploy/fuqn/nginx.conf /etc/nginx/nginx.conf

RUN chown www:www /app \
 && chmod 755 /app/deploy/fuqn/entrypoint.sh \
 && chown -R www:www /uploads /config /www \
 && rm -rf /root/.npm /tmp/*

USER www

EXPOSE 5000

HEALTHCHECK --interval=15s --timeout=5s --start-period=240s --retries=10 \
  CMD node --input-type=module -e "const r=await fetch('http://127.0.0.1:5000/readyz'); if(!r.ok) process.exit(1); const t=await r.text(); if(!t.includes('App is running')) process.exit(1);"

ENTRYPOINT ["/usr/bin/tini", "--", "/app/deploy/fuqn/entrypoint.sh"]
