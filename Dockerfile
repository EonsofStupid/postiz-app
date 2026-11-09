# fuqn.ai base image. Built from this fork's source, which already contains
# upstream Postiz through the fork commit. The latest GitHub release tag is
# v2.25.3; version.txt in that tag and in this tree still says v1.47.0 and is
# not the release identifier. The official ghcr.io/gitroomhq image is not the
# base: it is built by Dockerfile.dev with an unfrozen install and a root
# process supervisor, and it lags this fork.
#
# Build secrets do not belong in this file.

ARG NODE_IMAGE=node:22.23.4-bookworm-slim@sha256:5ec23b7c622b00547753bc6ffd78085dd868a68aeb41c8e0a1418f033e13d96d

FROM ${NODE_IMAGE} AS build

ARG NEXT_PUBLIC_VERSION=fuqn-base-0.2.0

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
    NEXT_PUBLIC_BACKEND_URL=http://fuqn-runtime-backend.invalid/api \
    NEXT_PUBLIC_POLOTNO=fuqnrt_NEXT_PUBLIC_POLOTNO \
    NEXT_PUBLIC_DISCORD_SUPPORT=fuqnrt_NEXT_PUBLIC_DISCORD_SUPPORT \
    NEXT_PUBLIC_POSTIZ_OAUTH_LOGO_URL=fuqnrt_NEXT_PUBLIC_POSTIZ_OAUTH_LOGO_URL \
    NEXT_PUBLIC_POSTIZ_OAUTH_DISPLAY_NAME=fuqnrt_NEXT_PUBLIC_POSTIZ_OAUTH_DISPLAY_NAME \
    NEXT_PUBLIC_UPLOAD_STATIC_DIRECTORY=fuqnrt_NEXT_PUBLIC_UPLOAD_STATIC_DIRECTORY \
    NEXT_PUBLIC_FACEBOOK_PIXEL=fuqnrt_NEXT_PUBLIC_FACEBOOK_PIXEL \
    NEXT_PUBLIC_SENTRY_DSN=fuqnrt_NEXT_PUBLIC_SENTRY_DSN \
    NEXT_PUBLIC_GTM_ID=fuqnrt_NEXT_PUBLIC_GTM_ID \
    NEXT_PUBLIC_TRACKING_TRIAL=fuqnrt_NEXT_PUBLIC_TRACKING_TRIAL \
    NODE_ENV=production \
    NODE_OPTIONS=--max-old-space-size=4096

RUN apt-get update \
 && apt-get upgrade -y \
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
 && pnpm run build \
 && find apps/frontend/.next apps/backend/dist apps/orchestrator/dist -name '*.map' -delete \
 && rm -rf apps/frontend/.next/cache node_modules/.cache \
 && mv apps/frontend/.next apps/frontend/.next-source \
 && tar -C node_modules -cf /tmp/prisma-keep.tar prisma \
 && pnpm prune --prod \
 && tar -C node_modules -xf /tmp/prisma-keep.tar \
 && rm -f /tmp/prisma-keep.tar \
 && node node_modules/prisma/build/index.js --version \
 && test -f node_modules/next/dist/bin/next

FROM ${NODE_IMAGE} AS runtime

ARG FUQN_VERSION=0.2.0
ARG UPSTREAM_RELEASE=v2.25.3
ARG UPSTREAM_VERSION_FILE=v1.47.0
ARG GIT_SHA=unknown
ARG NEXT_PUBLIC_VERSION=fuqn-base-0.2.0

LABEL org.opencontainers.image.title="fuqn.ai Postiz base image" \
      org.opencontainers.image.description="Base application image for isolated fuqn.ai instances of Postiz. Built from this fork. Postiz is AGPL-3.0. This is not a proprietary white-label build." \
      org.opencontainers.image.source="https://github.com/EonsofStupid/postiz-app" \
      org.opencontainers.image.url="https://github.com/EonsofStupid/postiz-app" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.version="${FUQN_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.vendor="EonsofStupid" \
      org.fuqn.upstream.latest-release="${UPSTREAM_RELEASE}" \
      org.fuqn.version-txt="${UPSTREAM_VERSION_FILE}" \
      org.fuqn.public-backend-placeholder="http://fuqn-runtime-backend.invalid/api"

ENV NODE_ENV=production \
    TZ=UTC \
    HOME=/www \
    UPLOAD_DIRECTORY=/uploads \
    NEXT_TELEMETRY_DISABLED=1 \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NEXT_PUBLIC_VERSION=${NEXT_PUBLIC_VERSION} \
    PRISMA_HIDE_UPDATE_MESSAGE=1

RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      nginx \
      tini \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 1001 www \
 && useradd --system --uid 1001 --gid 1001 --home-dir /www --create-home --shell /usr/sbin/nologin www \
 && mkdir -p /uploads /config /www \
 && dpkg-query -W -f '${Package}=${Version}\n' bash ca-certificates nginx tini > /etc/fuqn-os-packages.txt

WORKDIR /app
COPY --from=build --chown=www:www /app /app
COPY --chown=www:www deploy/fuqn/NOTICE /app/NOTICE
COPY deploy/fuqn/nginx.conf /etc/nginx/nginx.conf

RUN chown www:www /app \
 && chmod 755 /app/deploy/fuqn/entrypoint.sh \
 && chown -R www:www /uploads /config /www \
 && rm -rf /root/.npm /tmp/* /usr/local/lib/node_modules /opt/yarn-v1.22.22 /usr/local/bin/yarn /usr/local/bin/yarnpkg

USER www

EXPOSE 5000

HEALTHCHECK --interval=15s --timeout=5s --start-period=240s --retries=10 \
  CMD node --input-type=module -e "const r=await fetch('http://127.0.0.1:5000/readyz'); if(!r.ok) process.exit(1); const t=await r.text(); if(!t.includes('App is running')) process.exit(1);"

ENTRYPOINT ["/usr/bin/tini", "--", "/app/deploy/fuqn/entrypoint.sh"]
