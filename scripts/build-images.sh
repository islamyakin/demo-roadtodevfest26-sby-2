#!/usr/bin/env bash
# Build the linux/amd64 images of both apps, ready to push to Docker Hub.
# Usage: ./scripts/build-images.sh <dockerhub-user> [tag=latest]
#   then: docker login && docker push <user>/shop-frontend:<tag> && docker push <user>/shop-backend:<tag>
# Works with docker or nerdctl (colima): set DOCKER=nerdctl to force one.
set -euo pipefail
USER_NS="${1:?usage: build-images.sh <dockerhub-user> [tag]}"; TAG="${2:-latest}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER="${DOCKER:-$(command -v docker >/dev/null && echo docker || echo nerdctl)}"

for app in frontend backend; do
  echo "== $USER_NS/shop-$app:$TAG (linux/amd64)"
  "$DOCKER" build --platform linux/amd64 -f "$ROOT/app/Dockerfile.$app" -t "$USER_NS/shop-$app:$TAG" "$ROOT/app"
done
