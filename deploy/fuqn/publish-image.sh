#!/usr/bin/env bash
# Push a multi-arch fuqn.ai image and sign it with keyless cosign.
# Refuses every other repository and every other image name.
# Does nothing unless the workflow sets FUQN_PUBLISH=1.

set -euo pipefail

if [ "${FUQN_PUBLISH:-}" != "1" ]; then
  echo "refusing to publish without FUQN_PUBLISH=1"
  exit 1
fi

repository="${GITHUB_REPOSITORY:-}"
if [ "$repository" != "EonsofStupid/postiz-app" ]; then
  echo "refusing to publish from ${repository:-an unknown repository}"
  exit 1
fi

image="ghcr.io/eonsofstupid/postiz-app"
case "$image" in
  ghcr.io/eonsofstupid/postiz-app) ;;
  *)
    echo "refusing to publish ${image}"
    exit 1
    ;;
esac

if ! command -v cosign >/dev/null 2>&1; then
  echo "cosign is required to publish"
  exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

version="$(tr -d '[:space:]' < deploy/fuqn/VERSION)"
version_file="$(tr -d '[:space:]' < version.txt)"
sha="$(git rev-parse HEAD)"
short="$(git rev-parse --short=12 HEAD)"

tags=(
  --tag "${image}:${version}"
  --tag "${image}:sha-${short}"
)

ref_name="${GITHUB_REF_NAME:-}"
if [[ "$ref_name" == fuqn-v* ]]; then
  release="${ref_name#fuqn-v}"
  if [[ ! "$release" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "refusing tag ${ref_name}; expected fuqn-v<major>.<minor>.<patch>"
    exit 1
  fi
  tags+=(--tag "${image}:${release}")
fi

if [ "${TAG_LATEST:-}" = "latest" ]; then
  tags+=(--tag "${image}:latest")
fi

for tag in "${tags[@]}"; do
  if [ "$tag" = "--tag" ]; then
    continue
  fi
  case "$tag" in
    ghcr.io/eonsofstupid/postiz-app:*) ;;
    *)
      echo "refusing tag ${tag}"
      exit 1
      ;;
  esac
  if [[ "$tag" == *gitroomhq* ]]; then
    echo "refusing tag ${tag}"
    exit 1
  fi
done

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --file Dockerfile \
  --build-arg "FUQN_VERSION=${version}" \
  --build-arg "UPSTREAM_RELEASE=v2.25.3" \
  --build-arg "UPSTREAM_VERSION_FILE=${version_file}" \
  --build-arg "GIT_SHA=${sha}" \
  --build-arg "NEXT_PUBLIC_VERSION=fuqn-base-${version}" \
  --provenance=mode=max \
  --sbom=true \
  --push \
  "${tags[@]}" \
  .

# Keyless signing uses the GitHub OIDC token. It records the signature in the
# public Rekor log only after the image push above, and only when this script
# is invoked with FUQN_PUBLISH=1.
cosign sign --yes "${image}:${version}"
