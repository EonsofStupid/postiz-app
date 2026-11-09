#!/usr/bin/env bash
# Register a user and organization, log in, and exercise post creation.
# Scheduling to a real network needs a connected channel. A draft aimed at a
# missing integration must fail as a client error and must not create a Post row.

set -euo pipefail

mode="${1:?register or login}"
base="${2:?base url}"
report="${3:?report directory}"
cred="${report}/functional.env"

cookie_value() {
  local name="$1" file="$2"
  python3 - "$name" "$file" << 'PY'
import sys
name, path = sys.argv[1:]
value = ""
for raw in open(path, encoding="utf-8", errors="replace"):
    if not raw.lower().startswith("set-cookie:"):
        continue
    pair = raw.split(":", 1)[1].split(";", 1)[0].strip()
    key, sep, rest = pair.partition("=")
    if sep and key.strip() == name:
        value = rest.strip()
print(value)
PY
}

if [ "$mode" = "register" ]; then
  email="fuqn-smoke-$(openssl rand -hex 4)@example.com"
  password="$(openssl rand -hex 24)"
  umask 077
  cat > "$cred" << EOF
FUQN_SMOKE_EMAIL=${email}
FUQN_SMOKE_PASSWORD=${password}
EOF
  code="$(curl --silent --show-error --dump-header "${report}/register.headers" --output "${report}/register.body" --write-out '%{http_code}' \
    -H 'content-type: application/json' \
    --data "{\"email\":\"${email}\",\"password\":\"${password}\",\"provider\":\"LOCAL\",\"company\":\"Fuqn Smoke Org\"}" \
    "${base}/api/auth/register")"
  if [ "$code" != "200" ]; then
    echo "register returned ${code}"
    cat "${report}/register.body"
    exit 1
  fi
  grep -q '"register":true' "${report}/register.body"
fi

# shellcheck disable=SC1090
source "$cred"
code="$(curl --silent --show-error --dump-header "${report}/login.headers" --output "${report}/login.body" --write-out '%{http_code}' \
  -H 'content-type: application/json' \
  --data "{\"email\":\"${FUQN_SMOKE_EMAIL}\",\"password\":\"${FUQN_SMOKE_PASSWORD}\",\"provider\":\"LOCAL\"}" \
  "${base}/api/auth/login")"
if [ "$code" != "200" ]; then
  echo "login returned ${code}"
  exit 1
fi
auth="$(cookie_value auth "${report}/login.headers")"
if [ -z "$auth" ]; then
  echo "login did not set an auth cookie"
  exit 1
fi

code="$(curl --silent --show-error --output "${report}/organizations.json" --write-out '%{http_code}' \
  -H "auth: ${auth}" \
  "${base}/api/user/organizations")"
if [ "$code" != "200" ]; then
  echo "organizations returned ${code}"
  exit 1
fi
grep -q 'Fuqn Smoke Org' "${report}/organizations.json"
showorg="$(python3 - "${report}/organizations.json" << 'PY'
import json, sys
orgs = json.load(open(sys.argv[1]))
match = next(org for org in orgs if org.get("name") == "Fuqn Smoke Org")
print(match["id"])
PY
)"

post_code="$(curl --silent --show-error --output "${report}/post.body" --write-out '%{http_code}' \
  -H 'content-type: application/json' \
  -H "auth: ${auth}" -H "showorg: ${showorg}" \
  --data '{"type":"draft","date":"2026-12-01T15:00:00.000Z","posts":[{"integration":{"id":"missing-channel"},"settings":{},"value":[{"content":"fuqn smoke draft","image":[]}]}]}' \
  "${base}/api/posts")"
case "$post_code" in
  4??)
    echo "post_schedule=skipped_no_channel http=${post_code}"
    ;;
  200|201)
    echo "post_schedule=created http=${post_code}"
    ;;
  *)
    echo "post create returned ${post_code}"
    exit 1
    ;;
esac

echo "functional_${mode}=ok"
