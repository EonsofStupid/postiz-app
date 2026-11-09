#!/bin/bash
# Apply runtime configuration, sync the Prisma schema, then start Postiz.
# Secrets come from the container environment. Nothing here is baked into
# the image layers. The frontend bundle is copied from the pristine
# .next-source tree on every start so a restart picks up new public values.

set -euo pipefail

cd /app
mkdir -p \
  /tmp/nginx/client_body \
  /tmp/nginx/proxy \
  /tmp/nginx/fastcgi \
  /tmp/nginx/uwsgi \
  /tmp/nginx/scgi

rm -rf /app/apps/frontend/.next
cp -a /app/apps/frontend/.next-source /app/apps/frontend/.next

node /app/deploy/fuqn/prepare-runtime.mjs

attempts=0
until node /app/node_modules/prisma/build/index.js db push \
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
exec node /app/deploy/fuqn/supervise.mjs
