# fuqn.ai base image

This is the first application image for fuqn.ai. Each customer gets an isolated Postiz instance built from this public fork:

https://github.com/EonsofStupid/postiz-app

Postiz is AGPL-3.0. This image does not replace that license, remove copyright notices, or grant a paid white-label license. The image carries `/app/LICENSE` and `/app/NOTICE`. The OCI revision label is the git commit that was built. That commit is the corresponding source.

The UI is still Postiz. This pass does not rebrand screens, add billing, or deploy a customer.

## What the image contains

One container runs the same three Postiz processes as the upstream image:

- NestJS API on port 3000
- Next.js frontend on port 4200
- Temporal orchestrator on port 3002

nginx listens on container port 5000 and routes `/api/` to the API, `/` to the frontend, and `/uploads/` to the upload volume. `/healthz` is nginx liveness. `/readyz` is ready when the API answers `App is running!`. The image health check uses `/readyz`. The orchestrator exposes `/health/status`, which checks Temporal.

The container runs as uid 1001 (`www`). Upload and config volumes are mounted at `/uploads` and `/config`.

## Supporting services

The application needs three services. `deploy/fuqn/docker-compose.yaml` pins them by digest:

| Service | Image | Role |
| --- | --- | --- |
| `postgres` | `postgres:17-alpine` | Application database. Same major version as the upstream compose file. |
| `redis` | `redis:7.2-alpine` | Cache and API rate-limit storage. Same Redis 7.2 line as upstream, alpine build, password required. |
| `temporal` | `temporalio/auto-setup:1.28.1` | Workflow server used by the orchestrator. Same version as upstream. |
| `temporal-postgres` | `postgres:16-alpine` | Temporal's own database. Separate from application data. Same Postgres major as the upstream Temporal database. |

Temporal uses its Postgres database for visibility. The upstream development compose also starts Elasticsearch 7 with security disabled. This stack does not. Elasticsearch is not required for Postiz scheduling, and that development setting is not part of the base image. Auto-setup's sample `Custom*Field` search attributes are skipped (`SKIP_ADD_CUSTOM_SEARCH_ATTRIBUTES=true`) so Postiz can register `organizationId` and `postId` within Temporal's default limit of three Text attributes. The dev-only dynamic config `system.forceSearchAttributesCacheRefreshOnRead` is not mounted.

None of those services publish a host port. The application publishes container port 5000 on `127.0.0.1` only. Put TLS in front of that loopback port when a customer hostname is ready. Do not put database or Redis ports on a public interface to make the stack boot.

## Runtime configuration

Secrets and customer URLs are not build arguments. Compose injects them when the container starts. The entrypoint rejects known placeholders, a JWT shorter than 32 characters, a database URL without a password, Redis without a password, and `NOT_SECURED`.

Next.js inlines `NEXT_PUBLIC_BACKEND_URL` at build time. The image is built with the placeholder `http://fuqn-runtime-backend.invalid/api`. On startup the entrypoint replaces that placeholder in the frontend build with the runtime value. `FRONTEND_URL`, `MAIN_URL`, and `NEXT_PUBLIC_BACKEND_URL` must share one origin, and the backend path must be `/api`, because nginx serves the UI and the API on the same host.

`STORAGE_PROVIDER=local` is fixed into the Next.js upload redirects at build time. This image refuses any other storage provider. Cloudflare R2 needs a later image build.

`IS_GENERAL=true` is set because the current Postiz configuration marks it required.

Copy the template and replace every placeholder with `openssl rand -hex 32`:

```bash
cp deploy/fuqn/.env.example deploy/fuqn/.env
```

Optional social, email, and billing keys use the names already documented in the repository `.env.example`. Add them to `deploy/fuqn/.env` when you need them. Leave registration open only long enough to create the first user, then set `DISABLE_REGISTRATION=true`.

SSRF protection stays at the Postiz default. Do not set `NOT_SECURED`.

## Build

From the repository root:

```bash
docker build --platform linux/amd64 -f Dockerfile \
  --build-arg FUQN_VERSION="$(tr -d '[:space:]' < deploy/fuqn/VERSION)" \
  --build-arg UPSTREAM_VERSION="$(tr -d '[:space:]' < version.txt)" \
  --build-arg GIT_SHA="$(git rev-parse HEAD)" \
  --build-arg NEXT_PUBLIC_VERSION="fuqn-base-$(tr -d '[:space:]' < deploy/fuqn/VERSION)" \
  -t ghcr.io/eonsofstupid/postiz-app:0.1.0 \
  .
```

Application dependencies install with `pnpm install --frozen-lockfile` and pnpm `10.6.1`, matching `packageManager`. Prisma Client is generated with the locked `prisma@6.5.0` rather than `pnpm dlx`. The Node base image is `node:22.23.4-bookworm-slim` pinned by digest. pm2 `6.0.14` is installed from `deploy/fuqn/pm2/package-lock.json` with `npm ci`.

`deploy/fuqn/VERSION` is this image line (`0.1.0`). `version.txt` stays the upstream Postiz version and is copied into the label `org.fuqn.upstream.version`.

## Smoke test

```bash
bash deploy/fuqn/smoke-test.sh
```

The script builds the image, checks that the license, source notice, public-URL placeholder, and non-root user are present, checks that runtime secrets are not in the image environment, then starts the compose stack with generated passwords. It requires `/healthz`, `/readyz`, a frontend response, `/api/auth/can-register`, the `Organization` table, and orchestrator `/health/status`. It also checks that Postgres, Redis, and Temporal are not published on the host. It deletes the stack and its volumes at the end. It does not push the image.

## Registry and CI

The image name is `ghcr.io/eonsofstupid/postiz-app`.

`.github/workflows/fuqn-image.yml` builds and smoke-tests on pull requests, on pushes to `main`, and on `fuqn-v*` tags. That job does not log in to a registry.

Publishing happens only when one of these is true, and only from `EonsofStupid/postiz-app`:

1. The workflow is dispatched with the input `publish` set to `publish`.
2. A git tag named `fuqn-v<major>.<minor>.<patch>` is pushed.

Published tags are the version in `deploy/fuqn/VERSION` and `sha-<12>`. A `fuqn-v*` tag also publishes that version. The `latest` tag moves only when the dispatch input `tag_latest` is `latest`. `deploy/fuqn/publish-image.sh` refuses any other repository or image name. The published platform is `linux/amd64`, which is the platform the smoke test runs.

The inherited upstream workflow `.github/workflows/build-containers.yml` no longer runs on tag pushes. Its jobs run only in `gitroomhq/postiz-app`, and the push scripts exit if they are ever invoked elsewhere. The extension publish workflows are limited to that upstream repository as well. `deploy-aws.yml` already had that guard. The root `docker-compose.yaml` is unchanged and still references the upstream image `ghcr.io/gitroomhq/postiz-app:latest`; use this directory for fuqn.ai.

## Known limits

- The linux/amd64 image is about 1.4 GB. It keeps the built monorepo and its installed dependencies. Dev tooling is not fully pruned, so a later pass can slim the runtime.
- Only `linux/amd64` is built and published. arm64 is not part of this image yet.
- Customer-specific `NEXT_PUBLIC_*` values other than the API URL and the image version are empty in the client bundle. Server-side settings such as `FRONTEND_URL` are read at runtime.
- Local disk storage is the only storage mode this image will boot.
- pm2 `6.0.14` is locked, including its AGPL agent dependency. The image does not link a PM2 Plus account. `npm audit` reports high advisories in that agent/proxy tree (`basic-ftp` and its dependents). They are not configured.
- Schema setup uses `prisma db push`, which is what the upstream container already runs on start. It does not pass `--accept-data-loss`.
- Prisma may print the database URL during that sync. Treat container logs as secret.
- A local image has an image ID. It has no registry digest until a publish job pushes it. This pass does not push.
