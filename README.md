# SadTalker API - Local Deployment

Deploys [yungang/sadtalker-api](https://github.com/yungang/sadtalker-api) via Docker
Compose, exposed on **host port 9090**. Intended as a prototyping/quality-gate step for
one-shot photoreal avatar generation - not a production deployment.

## Files

- `docker-compose.yml` - service definition, GPU reservation, port mapping, healthcheck.
- `deploy-sadtalker.sh` - orchestration script: prereq checks, cleanup, clone, patch, build, start.
- `README.md` - this file.

## Prerequisites

- Docker with the `docker compose` v2 plugin (not the legacy `docker-compose` v1 binary).
- `docker buildx` plugin installed (Arch/Garuda: `sudo pacman -S docker-buildx`).
- NVIDIA Container Toolkit configured, for GPU-accelerated inference.
- `git` and `curl` on the host.
- An NVIDIA GPU with enough VRAM (a 4060 Ti 16GB is comfortably sized for this workload).

## Usage

```bash
./deploy-sadtalker.sh
```

The script is fully repeatable - every run starts by tearing down any previous
container, removing the previous local image, and pruning BuildKit cache mounts,
so you can re-run it after any failure without manual cleanup.

On success, the API is available at:

```
http://localhost:9090/docs
```

Example request (the API takes **URLs**, not file uploads - host your source photo
and audio somewhere reachable by the container, e.g. `python -m http.server` on the host):

```bash
curl -X POST "http://localhost:9090/generate/" \
  -H "Content-Type: application/json" \
  -d '{"image_link": "<url to your photo>", "audio_link": "<url to your audio>"}'
```

## What the script does, in order

1. Checks for `docker`, `docker compose`, `git`, and (optionally) `nvidia-smi`.
2. Tests GPU passthrough with a throwaway `nvidia/cuda` container.
3. **Cleanup**: `docker compose down`, removes the previous `sadtalker-api:local`
   image, and prunes BuildKit `exec.cachemount` cache (see "Known issues" below -
   this is the fix for corrupted/mismatched package downloads across retries).
4. Clones `sadtalker-api` if not already present (does not auto-update an existing clone).
5. Creates `.env` from `.env.example` on first run and pauses for you to review it.
6. Patches the cloned `Dockerfile` (idempotent, marked with a comment) to:
   - swap `archive.ubuntu.com` / `security.ubuntu.com` for `mirrors.kernel.org`,
   - add apt retry/timeout tolerance,
   - add `--fix-missing` to the package install step.
7. Builds the image and starts it via `docker compose up -d`.
8. Polls `/docs` for up to 150s and prints a ready-to-use `curl` example.

## Known issues / caveats

- **Old CUDA/PyTorch pin**: the image pins `torch==1.12.1+cu113` (2022-era), which
  predates the RTX 40-series (Ada Lovelace, compute capability 8.9). It will very
  likely still run via driver forward-compatibility/PTX JIT, but if you hit a
  "no kernel image is available for execution" error at runtime, bump the pinned
  torch version in `sadtalker-api/requirements.txt` and rebuild.
- **BuildKit cache mounts persist through `--no-cache`**: the Dockerfile uses
  `RUN --mount=type=cache,target=/root/.cache`. `docker compose build --no-cache`
  only clears layer cache, not this mount - corrupted or partial package data from
  a failed run can silently survive a `--no-cache` rebuild. The script's cleanup
  step prunes this explicitly; if you ever bypass the script and build manually,
  remember to also run `docker builder prune -f --filter type=exec.cachemount`.
- **Model checkpoints are baked into the image at build time** (~2-3GB via `wget`
  in the Dockerfile), not downloaded at first run - expect a slow first build and
  a fairly large resulting image.
- **This is a lightly-maintained community repo** (single-digit GitHub stars), not
  an official SadTalker release. Checkpoint URLs point at GitHub Releases and could
  go stale over time.
- **No confirmed multipart file-upload endpoint** - only the URL-based `/generate/`
  request shown above was verified against the README. Check `/docs` once the
  container is up in case others exist.
- **CPU-only hosts**: this image has no CPU fallback path. Building on a non-GPU
  machine can validate that the Dockerfile/checkpoints still resolve, but
  `/generate/` will not produce working output without a GPU.

## Troubleshooting history

Issues already hit and fixed during setup, for reference if they recur:

| Symptom | Cause | Fix |
|---|---|---|
| `failed to authorize... EOF` pulling `ubuntu:20.04` | Docker daemon network/VPN MTU issue | Fixed at the network layer, unrelated to this repo |
| `--mount option requires BuildKit` | `docker-buildx` plugin not installed | `sudo pacman -S docker-buildx` (Arch/Garuda) |
| `400 Bad Request` / `408 Request Time-out` on specific `.deb` files | Flaky default Ubuntu geo-mirror | Pinned to `mirrors.kernel.org` in the Dockerfile |
| `Could not resolve 'mirror.kernel.org'` | Typo - correct host is plural: `mirrors.kernel.org` | Corrected in the script's patch |
| `File has unexpected size... Mirror sync in progress?` | Corrupted BuildKit cache mount from earlier failed builds, not cleared by `--no-cache` | Script now prunes `exec.cachemount` cache on every run |

## Changing the port

Edit the `ports:` mapping in `docker-compose.yml` (`"9090:8000"`) and the
`HOST_PORT` variable at the top of `deploy-sadtalker.sh` to match.
