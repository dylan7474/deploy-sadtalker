# SadTalker API - Local Deployment

Deploys [yungang/sadtalker-api](https://github.com/yungang/sadtalker-api) via Docker
Compose, exposed on **host port 9091**. Intended as a prototyping/quality-gate step for
one-shot photoreal avatar generation - not a production deployment.

## Files

- `docker-compose.yml` - service definition, GPU reservation, port mapping, healthcheck.
- `deploy-sadtalker.sh` - orchestration script: prereq checks, cleanup, clone, patch, build, start.
- `.gitignore` - excludes the cloned `sadtalker-api/` working copy and `.env` from version control.
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
http://localhost:9091/docs
```

Example request (the API takes **URLs**, not file uploads - host your source photo
and audio somewhere reachable by the container, e.g. `python -m http.server` on the host):

```bash
curl -X POST "http://localhost:9091/generate/" \
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
7. Patches the cloned `api.py` (idempotent, backs up/restores on failure) to make
S3 upload conditional on `AWS_S3_BUCKET_NAME` and serve results locally
otherwise - see "Known issues" below for why this is necessary.
8. Builds the image (with `--no-cache` if either patch was just applied, to
avoid stale layers from before the patch existed) and starts it via
`docker compose up -d`.
9. Polls `/docs` for up to 150s and prints a ready-to-use `curl` example.

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
- **S3 upload is NOT optional in the upstream repo**: `api.py` originally always
uploaded the generated video to S3 and unconditionally deleted the local copy
(`os.remove(file_path)`) before returning the S3 URL, without checking whether
the upload succeeded - blank AWS credentials would either crash the request or
silently delete the generated video. `deploy-sadtalker.sh` now patches this
automatically (idempotent, backs up and restores `api.py` if the patch can't be
applied cleanly): S3 upload only happens if `AWS_S3_BUCKET_NAME` is set in
`.env`; otherwise the video is served locally via a `/results` static mount,
backed by the same `sadtalker-results` volume. Response shape differs
accordingly - S3 configured returns a JSON string (the S3 URL), unconfigured
returns `{"local_url": "/results/<filename>.mp4"}`, fetchable at
`http://localhost:9091/results/<filename>.mp4`.
- **CPU-only hosts**: this image has no CPU fallback path. Building on a non-GPU
machine can validate that the Dockerfile/checkpoints still resolve, but
`/generate/` will not produce working output without a GPU.

## Troubleshooting history

Issues already hit and fixed during setup, for reference if they recur:

| Symptom | Cause | Fix |
|---|---|---|
| `failed to authorize... EOF` pulling `ubuntu:20.04` | Docker daemon network/VPN MTU issue | Fixed at the network layer, unrelated to this r
epo |
| `--mount option requires BuildKit` | `docker-buildx` plugin not installed | `sudo pacman -S docker-buildx` (Arch/Garuda) |
| `400 Bad Request` / `408 Request Time-out` on specific `.deb` files | Flaky default Ubuntu geo-mirror | Pinned to `mirrors.kernel.org` in t
he Dockerfile |
| `Could not resolve 'mirror.kernel.org'` | Typo - correct host is plural: `mirrors.kernel.org` | Corrected in the script's patch |
| `File has unexpected size... Mirror sync in progress?` (cascading, each `.deb` reporting the *previous* package's expected size) | Broken H
TTP pipelining - a transparent proxy/cache on the host network misaligns pipelined apt responses. Pruning the BuildKit cache mount does **not
** fix this (and the Dockerfile's `--mount=.../root/.cache` never covered apt's `/var/cache/apt/archives` anyway) | Script's Dockerfile patch
now also sets `Acquire::http::Pipeline-Depth "0"`, `No-Cache "true"`, `BrokenProxy "true"` |
| Generated video vanishes / request errors with blank AWS creds | Upstream `api.py` always uploads to S3 and deletes the local file regardle
ss of upload success | Script now patches `api.py` to serve locally when `AWS_S3_BUCKET_NAME` is unset |
| `docker compose up` fails: `failed to bind host port 0.0.0.0:9090/tcp: address already in use` | Port 9090 is the [Cockpit](https://cockpit
-project.org/) web UI default (`cockpit.socket`), running on this host | Moved this deployment to host port **9091** (`docker-compose.yml` +
`HOST_PORT`). Alternatively `sudo systemctl disable --now cockpit.socket` to free 9090 |
| Container starts, `/docs` works, but `/generate/` output is garbage / CPU-slow; logs show `CUDA unknown error ... Setting the available dev
ices to be zero` | Stale CDI spec: `/etc/cdi/nvidia.yaml` pinned an old major for `/dev/nvidia-uvm`. `nvidia-uvm` uses a *dynamic* major that
changes on module reload/reboot, so the container got a dead device node. `nvidia-smi` still works in the container (it never touches uvm),
which is why the script's passthrough test passed | `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`, then `docker compose up -d
--force-recreate`. Verify: `grep -A1 nvidia-uvm /etc/cdi/nvidia.yaml` major must equal `grep nvidia-uvm /proc/devices`. The script now checks
`torch.cuda.is_available()` inside the container after startup and warns if this is wrong |

## Changing the port

Edit the `ports:` mapping in `docker-compose.yml` (`"9091:8000"`) and the
`HOST_PORT` variable at the top of `deploy-sadtalker.sh` to match.
