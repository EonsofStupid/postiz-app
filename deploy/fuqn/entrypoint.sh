#!/bin/bash
# Apply runtime configuration, sync the Prisma schema, then start Postiz.
# Secrets come from the container environment. Nothing here is baked into
# the image layers.

set -euo pipefail

cd /app
mkdir -p \
  /tmp/nginx/client_body \
  /tmp/nginx/proxy \
  /tmp/nginx/fastcgi \
  /tmp/nginx/uwsgi \
  /tmp/nginx/scgi \
  /www/.pm2

node /app/deploy/fuqn/prepare-runtime.mjs

attempts=0
until pnpm exec prisma db push \
  --schema ./libraries/nestjs-libraries/src/database/prisma/schema.prisma \
  --skip-generate
do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 12 ]; then
    echo "prisma db push failed after ${attempts} attempts"
    exit 1
  fi
  echo "database is not ready, retrying schema sync (${attempts}/12)"
  sleep 5
done

nginx -t -c /etc/nginx/nginx.conf
nginx -c /etc/nginx/nginx.conf

exec pm2-runtime start /app/deploy/fuqn/ecosystem.config.cjs
