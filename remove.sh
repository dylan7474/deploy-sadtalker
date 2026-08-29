#!/usr/bin/env bash
# Removes everything deployed by deploy-sadtalker.sh: container, image,
# volumes (including any generated videos), BuildKit cache, and the cloned
# source tree. Run from the same directory as docker-compose.yml.
set -euo pipefail

echo "This will permanently remove:"
echo "  - the 'sadtalker' container and its network"
echo "  - the 'sadtalker-api:local' image"
echo "  - the 'sadtalker-results' volume (any generated videos still in it)"
echo "  - BuildKit cache mounts related to this build"
echo "  - the cloned ./sadtalker-api directory (source + .env)"
echo ""
read -rp "Continue? [y/N] " REPLY
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
  echo "Aborted - nothing removed."
  exit 0
fi

echo "==> Stopping and removing container, network, and volumes"
docker compose down --remove-orphans --volumes || true

echo "==> Removing local image"
docker rmi sadtalker-api:local 2>/dev/null || echo "  (already gone)"

echo "==> Pruning BuildKit cache mounts"
docker builder prune -f --filter type=exec.cachemount 2>/dev/null || true

echo "==> Removing cloned source tree"
rm -rf sadtalker-api

echo "==> Done. Remaining Docker disk usage:"
docker system df
