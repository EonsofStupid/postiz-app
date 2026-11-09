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

Next.js inlines `NEXT_PUBLIC_*` values at build time. The image is built with placeholders. On every start the entrypoint copies a pristine frontend build and replaces those placeholders from the container environment. `NEXT_PUBLIC_BACKEND_URL` is required. The optional browser values are `NEXT_PUBLIC_POLOTNO`, `NEXT_PUBLIC_DISCORD_SUPPORT`, `NEXT_PUBLIC_POSTIZ_OAUTH_LOGO_URL`, `NEXT_PUBLIC_POSTIZ_OAUTH_DISPLAY_NAME`, `NEXT_PUBLIC_UPLOAD_STATIC_DIRECTORY`, `NEXT_PUBLIC_FACEBOOK_PIXEL`, `NEXT_PUBLIC_SENTRY_DSN`, `NEXT_PUBLIC_GTM_ID`, and `NEXT_PUBLIC_TRACKING_TRIAL`. Unset optional values become empty. `NEXT_PUBLIC_VERSION` stays the image version. `FRONTEND_URL`, `MAIN_URL`, and `NEXT_PUBLIC_BACKEND_URL` must share one origin, and the backend path must be `/api`.

`STORAGE_PROVIDER` is `local` or `cloudflare` (Cloudflare R2, the S3-compatible store Postiz implements). It is read at runtime. Local files are served from `/uploads`. R2 needs `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_ACCESS_KEY`, `CLOUDFLARE_SECRET_ACCESS_KEY`, `CLOUDFLARE_BUCKETNAME`, `CLOUDFLARE_BUCKET_URL`, and `CLOUDFLARE_REGION`. Postiz has no separate generic S3 provider.

`IS_GENERAL=true` is set because the current Postiz configuration marks it required.

Required settings: `JWT_SECRET` (at least 32 characters), `DATABASE_URL`, `REDIS_URL` (with a password), `FRONTEND_URL`, `MAIN_URL`, `NEXT_PUBLIC_BACKEND_URL`, `BACKEND_INTERNAL_URL` (`http://127.0.0.1:3000` inside this container), `TEMPORAL_ADDRESS`, `IS_GENERAL`, and `STORAGE_PROVIDER`. Compose fills the internal URLs from `deploy/fuqn/.env.example`.

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
  --build-arg UPSTREAM_RELEASE=v2.25.3 \
  --build-arg UPSTREAM_VERSION_FILE="$(tr -d '[:space:]' < version.txt)" \
  --build-arg GIT_SHA="$(git rev-parse HEAD)" \
  --build-arg NEXT_PUBLIC_VERSION="fuqn-base-$(tr -d '[:space:]' < deploy/fuqn/VERSION)" \
  -t ghcr.io/eonsofstupid/postiz-app:0.2.0 \
  -t ghcr.io/eonsofstupid/postiz-app:0.2.0-amd64 \
  .
```

Repeat with `--platform linux/arm64` and the tag `ghcr.io/eonsofstupid/postiz-app:0.2.0-arm64`. `deploy/fuqn/manifest-local.sh` assembles those two tags into a local index. It does not push to GHCR.

Application dependencies install with `pnpm install --frozen-lockfile` and pnpm `10.6.1`. Prisma Client is generated with the locked `prisma@6.5.0`. The Node base is `node:22.23.4-bookworm-slim`, the current Node 22 LTS, pinned by digest. Production dependencies are pruned after the build. The process supervisor is `deploy/fuqn/supervise.mjs`. pm2 is not installed.

The image is built from this fork, not from `ghcr.io/gitroomhq/postiz-app`. Upstream's Dockerfile.dev runs an unfrozen `pnpm install` and pm2 as root, and the published release `v2.25.3` (2026-10-24) is behind this fork. `version.txt` still says `v1.47.0` on that release and here. The release identifier is the git tag. The OCI label `org.fuqn.upstream.latest-release` is `v2.25.3`. The image revision is this fork's commit, which includes that release plus the later commits already on the fork. Unreleased upstream commits after the fork sync are not merged into this change.

## Smoke test

```bash
bash deploy/fuqn/smoke-test.sh
```

The script builds the amd64 image, checks the license, source notice, placeholder, non-root user, and absence of pm2, then runs Trivy at high and critical. It boots the stack, checks health, registers a user and organization, logs in, and submits a draft post. A draft with no connected channel must return a client error and is the evidence that scheduling was exercised without a live provider. It then restarts the app container and recreates it, and logs in again, to show the database volume survives. It does not push the image.

## Registry and CI

The image name is `ghcr.io/eonsofstupid/postiz-app`.

`.github/workflows/fuqn-image.yml` builds `linux/amd64` and `linux/arm64` on pull requests, pushes to `main`, and `fuqn-v*` tags. The amd64 job also smoke-tests. Neither job logs in to a registry. Each uploads a CycloneDX SBOM.

Publishing happens only when one of these is true, and only from `EonsofStupid/postiz-app`:

1. The workflow is dispatched with the input `publish` set to `publish`.
2. A git tag named `fuqn-v<major>.<minor>.<patch>` is pushed.

The publish job builds both architectures in one Buildx invocation, attaches provenance and an SBOM, pushes the manifest list, and runs `cosign sign --yes` with GitHub OIDC. That signing step does not run unless publish is explicitly requested. `deploy/fuqn/publish-image.sh` refuses any other repository or image name. The `latest` tag moves only when the dispatch input `tag_latest` is `latest`.

The inherited upstream workflow `.github/workflows/build-containers.yml` no longer runs on tag pushes. Its jobs run only in `gitroomhq/postiz-app`, and the push scripts exit if they are ever invoked elsewhere. The extension publish workflows are limited to that upstream repository as well. `deploy-aws.yml` already had that guard. The root `docker-compose.yaml` is unchanged and still references the upstream image `ghcr.io/gitroomhq/postiz-app:latest`; use this directory for fuqn.ai.

## Known limits

- Schema setup uses `prisma db push`, which is what the upstream container already runs on start. It does not pass `--accept-data-loss`.
- Prisma may print the database URL during that sync. Treat container logs as secret.
- A local image has an image ID. It has no GHCR digest until a publish job pushes it. This pass does not push.
- Upstream main after this fork sync is not included. Those commits are not a release.
- Accepted Trivy findings, if any remain after the build, are listed in `deploy/fuqn/.trivyignore` with a reason.
