#!/usr/bin/env bash
# Assemble a local multi-arch index. Does not push to a public registry.
# Requires ghcr.io/eonsofstupid/postiz-app:<version>-amd64 and -arm64
# to already exist in the local Docker engine.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
version="$(tr -d '[:space:]' < deploy/fuqn/VERSION)"
image="ghcr.io/eonsofstupid/postiz-app"
registry="127.0.0.1:5000"

docker image inspect "${image}:${version}-amd64" >/dev/null
docker image inspect "${image}:${version}-arm64" >/dev/null

docker rm -f fuqn-local-registry >/dev/null 2>&1 || true
docker run -d --name fuqn-local-registry -p 127.0.0.1:5000:5000 registry:2 >/dev/null
trap 'docker rm -f fuqn-local-registry >/dev/null' EXIT

for arch in amd64 arm64; do
  docker tag "${image}:${version}-${arch}" "${registry}/postiz-app:${version}-${arch}"
  docker push "${registry}/postiz-app:${version}-${arch}"
done

docker buildx imagetools create \
  --tag "${registry}/postiz-app:${version}" \
  "${registry}/postiz-app:${version}-amd64" \
  "${registry}/postiz-app:${version}-arm64"

docker buildx imagetools inspect "${registry}/postiz-app:${version}"
