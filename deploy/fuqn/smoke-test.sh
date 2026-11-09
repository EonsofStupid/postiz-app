#!/usr/bin/env bash
# Build the fuqn.ai base image and boot the isolated stack.
# This script never pushes an image and never publishes database ports.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

repository="ghcr.io/eonsofstupid/postiz-app"
version="$(tr -d '[:space:]' < deploy/fuqn/VERSION)"
upstream="$(tr -d '[:space:]' < version.txt)"
sha="$(git rev-parse HEAD)"
short="$(git rev-parse --short=12 HEAD)"
image="${repository}:${version}"
report="/tmp/fuqn-smoke-report"
port="${FUQN_BIND_PORT:-4007}"
project="fuqn-smoke"

rm -rf "$report"
mkdir -p "$report"
chmod 700 "$report"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed"
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose is not installed"
  exit 1
fi

build_command=(
  docker build
  --platform linux/amd64
  --file Dockerfile
  --build-arg "FUQN_VERSION=${version}"
  --build-arg "UPSTREAM_RELEASE=v2.25.3"
  --build-arg "UPSTREAM_VERSION_FILE=${upstream}"
  --build-arg "GIT_SHA=${sha}"
  --build-arg "NEXT_PUBLIC_VERSION=fuqn-base-${version}"
  --tag "${image}"
  --tag "${repository}:${version}-amd64"
  --tag "${repository}:sha-${short}"
  --iidfile "${report}/image-id"
  .
)

{
  echo "build command:"
  printf ' %q' "${build_command[@]}"
  echo
} | tee "${report}/commands.txt"

if [ "${FUQN_SKIP_BUILD:-}" = "1" ] && docker image inspect "$image" >/dev/null 2>&1; then
  echo "FUQN_SKIP_BUILD=1 and ${image} already exists; not rebuilding"
  docker image inspect -f '{{.Id}}' "$image" > "${report}/image-id"
else
  "${build_command[@]}"
fi

image_id="$(cat "${report}/image-id")"
docker image inspect "$image" > "${report}/inspect.json"

python3 - "$image" "$version" "$sha" << 'PY'
import json, subprocess, sys
image, version, sha = sys.argv[1:]
inspect = json.loads(subprocess.check_output(["docker", "image", "inspect", image]))[0]
env = inspect["Config"].get("Env") or []
joined = "\n".join(env)
banned = ("JWT_SECRET", "DATABASE_URL", "REDIS_URL", "PASSWORD", "SECRET_KEY", "POSTGRES_")
found = [item for item in env if any(word in item for word in banned)]
if found:
    print("image env contains runtime secrets:")
    for item in found:
        print(item.split("=", 1)[0])
    sys.exit(1)
labels = inspect["Config"].get("Labels") or {}
expected = {
    "org.opencontainers.image.source": "https://github.com/EonsofStupid/postiz-app",
    "org.opencontainers.image.licenses": "AGPL-3.0-only",
    "org.opencontainers.image.version": version,
    "org.opencontainers.image.revision": sha,
    "org.fuqn.public-backend-placeholder": "http://fuqn-runtime-backend.invalid/api",
    "org.fuqn.upstream.latest-release": "v2.25.3",
}
for key, value in expected.items():
    if labels.get(key) != value:
        print(f"label {key} is {labels.get(key)!r}, expected {value!r}")
        sys.exit(1)
user = inspect["Config"].get("User")
if user != "www":
    print(f"image user is {user!r}")
    sys.exit(1)
if inspect.get("Architecture") != "amd64" or inspect.get("Os") != "linux":
    print(f"image platform is {inspect.get('Os')}/{inspect.get('Architecture')}")
    sys.exit(1)
print(f"image config ok user={user} platform=linux/amd64 id={inspect['Id']}")
PY

docker run --rm --entrypoint sh "$image" -c 'test ! -e /app/.env'
docker run --rm --entrypoint head "$image" -n 2 /app/LICENSE > "${report}/license-head.txt"
grep -q "GNU AFFERO GENERAL PUBLIC LICENSE" "${report}/license-head.txt"
docker run --rm --entrypoint grep "$image" -q "EonsofStupid/postiz-app" /app/NOTICE
docker run --rm --entrypoint grep "$image" -R -l "fuqn-runtime-backend.invalid" /app/apps/frontend/.next-source >/dev/null
docker run --rm --entrypoint sh "$image" -c 'if command -v pm2 >/dev/null 2>&1; then exit 1; fi'
if ! command -v trivy >/dev/null 2>&1; then
  echo "trivy is required"
  exit 1
fi
trivy image --severity HIGH,CRITICAL --exit-code 1 --ignorefile deploy/fuqn/.trivyignore --format json --output "${report}/trivy.json" "$image"
python3 - "${report}/trivy.json" << 'PY'
import json, sys
report = json.load(open(sys.argv[1]))
counts = {}
for result in report.get("Results") or []:
    for vuln in result.get("Vulnerabilities") or []:
        counts[vuln.get("Severity", "?")] = counts.get(vuln.get("Severity", "?"), 0) + 1
print("trivy high/critical", counts or "none")
PY

if docker history --no-trunc "$image" | grep -E 'JWT_SECRET=.+|DATABASE_URL=postgres|REDIS_URL=redis'; then
  echo "image history contains a runtime secret assignment"
  exit 1
fi

pg_password="$(openssl rand -hex 32)"
redis_password="$(openssl rand -hex 32)"
temporal_password="$(openssl rand -hex 32)"
jwt_secret="$(openssl rand -hex 32)"
env_file="${report}/stack.env"
umask 077
cat > "$env_file" << EOF
FUQN_VERSION=${version}
FUQN_UPSTREAM_VERSION=${upstream}
FUQN_GIT_SHA=${sha}
FUQN_BIND_PORT=${port}
FUQN_ENV_FILE=${env_file}
FUQN_POSTGRES_USER=fuqn_app
FUQN_POSTGRES_PASSWORD=${pg_password}
FUQN_POSTGRES_DB=fuqn
FUQN_REDIS_PASSWORD=${redis_password}
FUQN_TEMPORAL_POSTGRES_USER=fuqn_temporal
FUQN_TEMPORAL_POSTGRES_PASSWORD=${temporal_password}
JWT_SECRET=${jwt_secret}
FRONTEND_URL=http://127.0.0.1:${port}
MAIN_URL=http://127.0.0.1:${port}
NEXT_PUBLIC_BACKEND_URL=http://127.0.0.1:${port}/api
BACKEND_INTERNAL_URL=http://127.0.0.1:3000
TEMPORAL_ADDRESS=temporal:7233
IS_GENERAL=true
STORAGE_PROVIDER=local
DISABLE_REGISTRATION=false
EOF
chmod 600 "$env_file"

compose=(docker compose --env-file "$env_file" --project-directory "$root/deploy/fuqn" -f "$root/deploy/fuqn/docker-compose.yaml" -p "$project")

redact() {
  sed \
    -e "s#${pg_password}#[redacted]#g" \
    -e "s#${redis_password}#[redacted]#g" \
    -e "s#${temporal_password}#[redacted]#g" \
    -e "s#${jwt_secret}#[redacted]#g"
}

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    "${compose[@]}" logs --no-color > "${report}/logs.txt" 2>&1 || true
    echo "----- redacted logs (tail) -----"
    redact < "${report}/logs.txt" | tail -n 200 || true
  fi
  "${compose[@]}" down -v --remove-orphans > "${report}/down.txt" 2>&1 || true
  redact < "${report}/commands.txt" > "${report}/commands.txt.redacted" || true
  mv "${report}/commands.txt.redacted" "${report}/commands.txt"
  exit "$status"
}
trap cleanup EXIT

"${compose[@]}" up -d

assert_unpublished() {
  local service="$1" published="$2" out port_num
  out="$("${compose[@]}" port "$service" "$published" 2>/dev/null || true)"
  port_num="${out##*:}"
  if [ -n "$out" ] && [ "$port_num" != "0" ]; then
    echo "${service} publishes ${published} -> ${out}"
    exit 1
  fi
}

app_port="$("${compose[@]}" port app 5000)"
case "$app_port" in
  127.0.0.1:*) ;;
  *)
    echo "application port is not loopback-only: ${app_port}"
    exit 1
    ;;
esac
assert_unpublished postgres 5432
assert_unpublished redis 6379
assert_unpublished temporal 7233
assert_unpublished temporal-postgres 5432

wait_for() {
  local name="$1" tries="$2"
  shift 2
  local attempt=0
  until "$@"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$tries" ]; then
      echo "timed out waiting for ${name}"
      return 1
    fi
    sleep 5
  done
}

ready() {
  curl --fail --silent --show-error --output "${report}/readyz.txt" "http://127.0.0.1:${port}/readyz" \
    && grep -q "App is running" "${report}/readyz.txt"
}
wait_for "readyz" 72 ready

curl --fail --silent --show-error --output "${report}/healthz.txt" "http://127.0.0.1:${port}/healthz"
grep -q "ok" "${report}/healthz.txt"

frontend() {
  frontend_code="$(curl --silent --show-error --output "${report}/frontend.html" --write-out '%{http_code}' "http://127.0.0.1:${port}/")"
  case "$frontend_code" in
    200|301|302|307|308) return 0 ;;
    *) return 1 ;;
  esac
}
wait_for "frontend" 36 frontend

curl --fail --silent --show-error --output "${report}/can-register.json" "http://127.0.0.1:${port}/api/auth/can-register"
grep -q "register" "${report}/can-register.json"

table="$("${compose[@]}" exec -T postgres psql -U fuqn_app -d fuqn -tAc "SELECT to_regclass('public.\"Organization\"');")"
table="$(printf '%s' "$table" | tr -d '[:space:]')"
case "$table" in
  *Organization*) ;;
  *)
    echo "Organization table was not created (got ${table:-empty})"
    exit 1
    ;;
esac

wait_for "orchestrator" 48 \
  "${compose[@]}" exec -T app node --input-type=module -e "const r=await fetch('http://127.0.0.1:3002/health/status'); if(!r.ok) process.exit(1); const body=await r.text(); if(!body.includes('ok')) process.exit(1);"

bash deploy/fuqn/functional-check.sh register "http://127.0.0.1:${port}" "$report" | tee "${report}/functional-register.txt"
"${compose[@]}" restart app >/dev/null
wait_for "readyz after restart" 36 ready
bash deploy/fuqn/functional-check.sh login "http://127.0.0.1:${port}" "$report" | tee "${report}/functional-restart.txt"
"${compose[@]}" up -d --force-recreate --no-deps app >/dev/null
wait_for "readyz after recreate" 48 ready
bash deploy/fuqn/functional-check.sh login "http://127.0.0.1:${port}" "$report" | tee "${report}/functional-recreate.txt"

{
  echo "image=${image}"
  echo "image_id=${image_id}"
  echo "image_size_bytes=$(docker image inspect -f '{{.Size}}' "$image")"
  echo "platform=linux/amd64"
  echo "revision=${sha}"
  echo "upstream=${upstream}"
  echo "readyz=ok"
  echo "healthz=ok"
  echo "frontend_status=${frontend_code}"
  echo "organization_table=present"
  echo "orchestrator=ok"
  echo "functional=ok"
  echo "restart_persistence=ok"
  echo "app_port=${app_port}"
  echo "registry_digest=not_pushed"
} | tee "${report}/summary.txt"
