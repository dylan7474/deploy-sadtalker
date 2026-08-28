#!/usr/bin/env bash
# Deploys yungang/sadtalker-api via docker compose on host port 9090.
# Run this script from the same directory as docker-compose.yml.
set -euo pipefail

REPO_URL="https://github.com/yungang/sadtalker-api.git"
REPO_DIR="sadtalker-api"
HOST_PORT=9090

echo "==> Checking prerequisites"
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found. Install Docker first."; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: 'docker compose' (v2 plugin) not found."; exit 1; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git not found."; exit 1; }

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "WARNING: nvidia-smi not found on host. Confirm your NVIDIA driver is installed."
else
  echo "==> Host GPU:"
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
fi

echo "==> Testing NVIDIA Container Toolkit / GPU passthrough"
if docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
  echo "GPU passthrough OK."
else
  echo "WARNING: GPU passthrough test failed."
  echo "  Install/configure the NVIDIA Container Toolkit before continuing:"
  echo "  https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
  echo "  Continuing anyway - the image will still build, but the container may not see the 4060 Ti."
fi

echo "==> Cleaning up previous deployment"
docker compose down --remove-orphans >/dev/null 2>&1 || true

if docker image inspect sadtalker-api:local >/dev/null 2>&1; then
  echo "  Removing previous sadtalker-api:local image"
  docker rmi sadtalker-api:local >/dev/null 2>&1 || true
fi

echo "  Pruning BuildKit cache mounts (this is where corrupted apt state from"
echo "  earlier failed builds against broken mirrors actually lives - plain"
echo "  '--no-cache' does NOT clear these, only layer cache)"
if docker builder prune -f --filter type=exec.cachemount >/dev/null 2>&1; then
  echo "  Cache mounts pruned."
else
  echo "  WARNING: targeted cache-mount prune not supported by this buildx version."
  echo "  Falling back requires a full 'docker builder prune -f', which clears build"
  echo "  cache for ALL images on this host, not just sadtalker-api."
  read -rp "  Continue with a full prune? [y/N] " REPLY
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    docker builder prune -f
  else
    echo "  Skipped. If the build fails again with 'unexpected size' errors, this stale cache is why."
  fi
fi

echo "==> Fetching sadtalker-api source"
if [ ! -d "$REPO_DIR" ]; then
  git clone "$REPO_URL" "$REPO_DIR"
else
  echo "  $REPO_DIR already exists - skipping clone (run 'git -C $REPO_DIR pull' manually for updates)."
fi

echo "==> Preparing .env"
if [ ! -f "$REPO_DIR/.env" ]; then
  cp "$REPO_DIR/.env.example" "$REPO_DIR/.env"
  echo "  Created $REPO_DIR/.env from .env.example - review its contents before continuing."
  read -rp "  Press enter once you've reviewed it (or edited it) to continue... " _
fi

echo "==> Patching Dockerfile for apt mirror reliability"
# The default archive.ubuntu.com geo-mirror can be flaky (400/408 errors mid-build).
# Swap it to us.archive.ubuntu.com, a single Canonical-run mirror that serves
# packages directly (no redirect hop), disable HTTP pipelining (the actual cause
# of the sporadic single-package "400 Bad Request" errors - a well-known apt/
# Ubuntu-mirror interaction, confirmed here by curl succeeding against the exact
# URL and backend IP apt got a 400 from), add retry/timeout tolerance on top for
# genuine transient failures, and make the install step tolerant of a single bad
# package fetch. Idempotent - safe to re-run.
#
# NOTE: an earlier version of this patch pointed at mirrors.kernel.org. That
# host 301-redirects every request to mirrors.edge.kernel.org, a multi-backend
# CDN whose replicas are inconsistently synced - in testing it 404'd on the
# vast majority of packages in this install (masked by --fix-missing until the
# whole install collapsed). Do not reintroduce it.
#
# security.ubuntu.com is intentionally left untouched: it's Canonical's own
# security CDN, not the flaky geo-mirror, and most non-canonical mirrors don't
# carry the focal-security pocket at all.
DOCKERFILE="$REPO_DIR/Dockerfile"
PATCH_MARKER="# deploy-sadtalker.sh: apt mirror patch"
JUST_PATCHED=0

if [ -f "$DOCKERFILE" ] && ! grep -qF "$PATCH_MARKER" "$DOCKERFILE"; then
  PATCH_FILE=$(mktemp)
  cat > "$PATCH_FILE" <<'EOF'

# deploy-sadtalker.sh: apt mirror patch
RUN sed -i 's|http://archive.ubuntu.com/ubuntu|http://us.archive.ubuntu.com/ubuntu|g' /etc/apt/sources.list
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries \
    && echo 'Acquire::http::Timeout "30";' >> /etc/apt/apt.conf.d/80-retries \
    && echo 'Acquire::http::Pipeline-Depth "0";' >> /etc/apt/apt.conf.d/80-retries
ENV PIP_DEFAULT_TIMEOUT=120
ENV PIP_RETRIES=5
EOF
  sed -i "/ENV DEBCONF_NONINTERACTIVE_SEEN true/r $PATCH_FILE" "$DOCKERFILE"
  rm -f "$PATCH_FILE"

  sed -i 's/apt-get install -y python3-pip wget ffmpeg/apt-get install -y --fix-missing python3-pip wget ffmpeg/' "$DOCKERFILE"

  # The checkpoint/weights download step chains 8 large (up to ~700MB) wget
  # fetches across several external CDNs (GitHub releases, Azure blob storage)
  # with plain `&&` and no retry handling - one transient blip on any single
  # file aborts the whole multi-GB layer. Observed in testing: a bare
  # "Unable to establish SSL connection" against github.com/githubusercontent.com,
  # not reproducible moments later against the same host. wget's own --tries
  # does NOT cover this - wget treats a TLS handshake failure as fatal and
  # exits immediately without retrying, regardless of --tries. So wrap each
  # fetch in a shell-level retry loop (5 attempts, 10s backoff) instead.
  FETCH_FN_FILE=$(mktemp)
  cat > "$FETCH_FN_FILE" <<'EOF'
    && fetch() { for i in 1 2 3 4 5; do rm -f "$2"; wget --timeout=60 "$1" -O "$2" && return 0; echo "  fetch of $1 failed (attempt $i/5), retrying in 10s..." >&2; sleep 10; done; return 1; } \
EOF
  sed -i "/mkdir \.\/checkpoints \\\\/r $FETCH_FN_FILE" "$DOCKERFILE"
  rm -f "$FETCH_FN_FILE"
  sed -i -E 's/wget -nc ([^ ]+) -O +([^ ]+)/fetch \1 \2/' "$DOCKERFILE"

  echo "  Dockerfile patched (mirror swap, apt retries, --fix-missing, pip timeout/retries, wget->fetch retries)."
  JUST_PATCHED=1
else
  echo "  Dockerfile already patched (or patch already applied) - skipping."
fi

echo "==> Building image (bakes in several GB of model checkpoints - first build will take a while)"
if [ "$JUST_PATCHED" -eq 1 ]; then
  echo "  Dockerfile was just patched - building with --no-cache to clear any stale apt"
  echo "  state left over from earlier failed attempts against the old mirror."
  DOCKER_BUILDKIT=1 docker compose build --no-cache
else
  DOCKER_BUILDKIT=1 docker compose build
fi

echo "==> Starting container on host port $HOST_PORT"
docker compose up -d

echo "==> Waiting for the API to come up"
for i in $(seq 1 30); do
  if curl -fs "http://localhost:${HOST_PORT}/docs" >/dev/null 2>&1; then
    echo ""
    echo "SadTalker API is up: http://localhost:${HOST_PORT}/docs"
    echo "Test with:"
    echo "  curl -X POST \"http://localhost:${HOST_PORT}/generate/\" \\"
    echo "    -H \"Content-Type: application/json\" \\"
    echo "    -d '{\"image_link\": \"<url to your photo>\", \"audio_link\": \"<url to your audio>\"}'"
    exit 0
  fi
  sleep 5
done

echo "The API did not respond after 150s. Check logs with: docker compose logs -f sadtalker"
echo "If you see a CUDA kernel error, it's likely the pinned torch 1.12.1+cu113 build not"
echo "including precompiled kernels for the 4060 Ti's Ada Lovelace architecture (sm_89) -"
echo "try bumping the torch version pinned in sadtalker-api/requirements.txt and rebuilding."
exit 1
