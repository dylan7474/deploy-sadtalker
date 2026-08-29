#!/usr/bin/env bash
# Deploys yungang/sadtalker-api via docker compose on host port 9090.
# Run this script from the same directory as docker-compose.yml.
#
# Repeatable by design: every run tears down the previous container, prunes
# stale BuildKit cache mounts, and re-applies (idempotently) two patches to
# the upstream repo:
#   1. Dockerfile  - stable apt mirror + retry tolerance (build reliability)
#   2. api.py      - serve results locally instead of requiring AWS S3
set -euo pipefail

REPO_URL="https://github.com/yungang/sadtalker-api.git"
REPO_DIR="sadtalker-api"
HOST_PORT=9090

echo "==> Checking prerequisites"
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found. Install Docker first."; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: 'docker compose' (v2 plugin) not found."; exit 1; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git not found."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found (needed to patch api.py)."; exit 1; }

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
  echo "  Continuing anyway - the image will still build, but the container may not see the GPU."
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
  echo "  Created $REPO_DIR/.env from .env.example."
  echo "  Leave the AWS_* vars blank for a self-hosted setup - see api.py patch below,"
  echo "  which makes S3 optional instead of mandatory."
  read -rp "  Press enter once you've reviewed it (or edited it) to continue... " _
fi

NEEDS_NOCACHE=0

echo "==> Patching Dockerfile for apt mirror reliability"
# The default archive.ubuntu.com geo-mirror can be flaky (400/408 errors mid-build).
# Swap to a stable mirror, add apt retry/timeout tolerance, and make the install
# step tolerant of a single bad package fetch. Idempotent - safe to re-run.
DOCKERFILE="$REPO_DIR/Dockerfile"
DOCKERFILE_MARKER="# deploy-sadtalker.sh: apt mirror patch"

if [ -f "$DOCKERFILE" ] && ! grep -qF "$DOCKERFILE_MARKER" "$DOCKERFILE"; then
  PATCH_FILE=$(mktemp)
  cat > "$PATCH_FILE" <<'EOF'

# deploy-sadtalker.sh: apt mirror patch
RUN sed -i 's|http://archive.ubuntu.com/ubuntu|http://mirrors.kernel.org/ubuntu|g; s|http://security.ubuntu.com/ubuntu|http://mirrors.kernel.org/ubuntu|g' /etc/apt/sources.list
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries \
    && echo 'Acquire::http::Timeout "30";' >> /etc/apt/apt.conf.d/80-retries
EOF
  sed -i "/ENV DEBCONF_NONINTERACTIVE_SEEN true/r $PATCH_FILE" "$DOCKERFILE"
  rm -f "$PATCH_FILE"

  sed -i 's/apt-get install -y python3-pip wget ffmpeg/apt-get install -y --fix-missing python3-pip wget ffmpeg/' "$DOCKERFILE"

  echo "  Dockerfile patched (mirror swap, apt retries, --fix-missing)."
  NEEDS_NOCACHE=1
else
  echo "  Dockerfile already patched (or patch already applied) - skipping."
fi

echo "==> Patching api.py to serve results locally when no S3 bucket is configured"
# Upstream always uploads to S3 and unconditionally deletes the local file
# afterwards (os.remove), regardless of whether the upload succeeded. Blank
# AWS_* creds either crash the request or silently discard the generated
# video. This patch makes the S3 path conditional on AWS_S3_BUCKET_NAME being
# set, falling back to serving the file locally via a /results static mount.
# Idempotent - safe to re-run. Backs up and restores api.py automatically if
# the patch can't be applied cleanly.
API_PY="$REPO_DIR/api.py"
API_MARKER="self-hosted fallback"

if [ -f "$API_PY" ] && ! grep -qF "$API_MARKER" "$API_PY"; then
  cp "$API_PY" "$API_PY.bak"
  PATCH_PY=$(mktemp)
  cat > "$PATCH_PY" <<'PYEOF'
import re
import sys

path = "api.py"
with open(path) as f:
    content = f.read()

if "from fastapi.staticfiles import StaticFiles" not in content:
    content = content.replace(
        "from fastapi import FastAPI",
        "from fastapi import FastAPI\nfrom fastapi.staticfiles import StaticFiles",
        1,
    )

if 'app.mount("/results"' not in content:
    content = content.replace(
        "app = FastAPI()",
        'app = FastAPI()\n\n'
        'RESULT_DIR = "./results"\n'
        'os.makedirs(RESULT_DIR, exist_ok=True)\n'
        'app.mount("/results", StaticFiles(directory=RESULT_DIR), name="results")',
        1,
    )

pattern = re.compile(
    r"([ \t]*)file_path = save_dir \+ '\.mp4'.*?return s3_url\n", re.DOTALL
)
m = pattern.search(content)
if not m:
    print("PATCH_FAILED: anchor block not found")
    sys.exit(1)

indent = m.group(1)
replacement = (
    f"{indent}file_path = save_dir + '.mp4'\n"
    f"{indent}print(file_path)\n"
    f"{indent}print(os.path.exists(file_path))\n"
    f"{indent}\n"
    f"{indent}if AWS_S3_BUCKET_NAME:\n"
    f"{indent}    if item.s3_object_path[-1] != '/':\n"
    f"{indent}        item.s3_object_path += '/'\n"
    f"{indent}    object_name = item.s3_object_path + os.path.basename(file_path)\n"
    f"{indent}    upload_file_aws(file_path, object_name)\n"
    f"{indent}    s3_url = f'https://{{AWS_S3_BUCKET_NAME}}.s3.{{AWS_S3_REGION}}.amazonaws.com/{{object_name}}'\n"
    f"{indent}    os.remove(file_path)\n"
    f"{indent}    return s3_url\n"
    f"{indent}else:\n"
    f"{indent}    # self-hosted fallback: no S3 bucket configured, serve the file locally\n"
    f"{indent}    local_filename = os.path.basename(file_path)\n"
    f"{indent}    served_path = os.path.join(RESULT_DIR, local_filename)\n"
    f"{indent}    shutil.move(file_path, served_path)\n"
    f'{indent}    return {{"local_url": f"/results/{{local_filename}}"}}\n'
)
content = content[: m.start()] + replacement + content[m.end() :]

with open(path, "w") as f:
    f.write(content)

print("PATCH_OK")
PYEOF

  if ( cd "$REPO_DIR" && python3 "$OLDPWD/$PATCH_PY" ); then
    API_PATCH_OK=1
  else
    API_PATCH_OK=0
  fi
  rm -f "$PATCH_PY"

  if [ "$API_PATCH_OK" -eq 1 ] && python3 -m py_compile "$API_PY"; then
    echo "  api.py patched and syntax-checked OK."
    rm -f "$API_PY.bak" "${API_PY%.py}.cpython"*.pyc 2>/dev/null || true
    find "$(dirname "$API_PY")" -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
    NEEDS_NOCACHE=1
  else
    echo "  ERROR: api.py patch failed (anchor not found or syntax check failed)."
    echo "  Restoring original api.py from backup - S3 will remain mandatory until"
    echo "  this is patched manually (see README known issues)."
    mv "$API_PY.bak" "$API_PY"
  fi
else
  echo "  api.py already patched (or patch already applied) - skipping."
fi

echo "==> Building image (bakes in several GB of model checkpoints - first build will take a while)"
if [ "$NEEDS_NOCACHE" -eq 1 ]; then
  echo "  Dockerfile and/or api.py were just patched - building with --no-cache to"
  echo "  avoid stale layers from before the patch existed."
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
    echo ""
    echo "With AWS_S3_BUCKET_NAME left blank in .env, the response returns"
    echo "{\"local_url\": \"/results/<filename>.mp4\"}, fetchable at:"
    echo "  http://localhost:${HOST_PORT}/results/<filename>.mp4"
    exit 0
  fi
  sleep 5
done

echo "The API did not respond after 150s. Check logs with: docker compose logs -f sadtalker"
echo "If you see a CUDA kernel error, it's likely the pinned torch 1.12.1+cu113 build not"
echo "including precompiled kernels for your GPU's architecture - try bumping the torch"
echo "version pinned in sadtalker-api/requirements.txt and rebuilding."
exit 1
