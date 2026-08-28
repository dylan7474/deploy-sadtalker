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

## Using the deployed application

SadTalker turns a **single portrait plus spoken audio into a talking-head video**.
It does not create a persistent 3D avatar, voice, or real-time character. For use
with another speaking-AI application, first check what that application accepts:

- If it accepts a rendered video, use the SadTalker result (normally an MP4).
- If it animates a still portrait itself, give it the original prepared portrait;
  running that portrait through SadTalker first is unnecessary.
- If it requires a 3D model, Live2D rig, or real-time avatar stream, this API does
  not produce that asset type.

### 1. Prepare the portrait and voice track

For the most lifelike result, use a sharp, front-facing, well-lit head-and-shoulders
portrait. The face should be unobstructed, with a neutral expression and some space
around the head. Avoid profile views, cropped chins/foreheads, strong shadows,
multiple people, and very small faces. Use only a person's likeness and voice when
you have their permission, and disclose the result as synthetic where appropriate.

Provide a clean speech recording with little background noise or music. WAV is a
good default. The audio supplies the timing and mouth movements, so generate or
record the final speech in the other AI app first, then send that audio to
SadTalker with the portrait.

### 2. Make both files reachable by the container

The `/generate/` endpoint accepts URLs, not local file paths or file uploads.
Public HTTPS URLs are simplest. For a private LAN, place the portrait and audio in
one directory and serve it from the machine running Docker:

```bash
cd /path/to/avatar-inputs
python3 -m http.server 8080 --bind 0.0.0.0
```

Find that machine's LAN address (for example, `192.168.1.50`) and verify that the
files open at `http://192.168.1.50:8080/portrait.png` and
`http://192.168.1.50:8080/speech.wav`. Do **not** use `localhost` in these input
URLs: inside the SadTalker container, `localhost` means the container itself.
Keep the file server running until generation finishes, and do not expose it to an
untrusted network without access controls.

### 3. Generate and download the video

Open `http://localhost:9090/docs` (or replace `localhost` with the deployment
host's address), expand `POST /generate/`, select **Try it out**, and supply:

```json
{
  "image_link": "http://192.168.1.50:8080/portrait.png",
  "audio_link": "http://192.168.1.50:8080/speech.wav"
}
```

Alternatively, call the same endpoint from a terminal. `--fail-with-body` makes
HTTP errors visible, while `--output` saves the returned video instead of printing
binary data in the terminal:

```bash
curl --fail-with-body --show-error \
  --request POST "http://localhost:9090/generate/" \
  --header "Content-Type: application/json" \
  --data '{
    "image_link": "http://192.168.1.50:8080/portrait.png",
    "audio_link": "http://192.168.1.50:8080/speech.wav"
  }' \
  --output avatar.mp4
```

Generation is not instantaneous; keep the request open while the GPU renders.
Confirm that `avatar.mp4` plays and has audio before importing it into the other
application. If the response is JSON rather than a video, inspect it (and the
response schema in `/docs`) for a result URL, then download that URL. The live
OpenAPI page is authoritative for the exact response produced by the cloned API
version.

For repeated speech, keep one approved, high-quality portrait and submit each new
audio response with it. This produces a separate video for every utterance; it is
suited to asynchronous clips, not low-latency conversation. Do not expose port
9090 directly to the public internet: this deployment has no authentication,
TLS, rate limiting, or job queue. Put it behind an authenticated reverse proxy or
keep it on a trusted network.

### 4. Monitor or stop the service

```bash
# Follow generation and error logs
docker compose logs -f sadtalker

# Check container/health status
docker compose ps

# Stop the service (the named results volume is retained)
docker compose down
```

## What the script does, in order

1. Checks for `docker`, `docker compose`, `git`, `curl`, and (optionally) `nvidia-smi`.
2. Tests GPU passthrough with a throwaway `nvidia/cuda` container.
3. **Cleanup**: `docker compose down`, removes the previous `sadtalker-api:local`
   image, and prunes BuildKit `exec.cachemount` cache (see "Known issues" below -
   this is the fix for corrupted/mismatched package downloads across retries).
4. Clones `sadtalker-api` if not already present (does not auto-update an existing clone).
5. Creates `.env` from `.env.example` on first run and pauses for you to review it.
6. Patches the cloned `Dockerfile` (idempotent, marked with a comment) to:
   - swap `archive.ubuntu.com` for `us.archive.ubuntu.com` (leaving the Ubuntu
     security repository unchanged),
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
| `400 Bad Request` / `408 Request Time-out` on specific `.deb` files | Flaky default Ubuntu geo-mirror | Pinned to `us.archive.ubuntu.com` in the Dockerfile |
| `Could not resolve 'mirror.kernel.org'` | Typo - correct host is plural: `mirrors.kernel.org` | Corrected in the script's patch |
| `File has unexpected size... Mirror sync in progress?` | Corrupted BuildKit cache mount from earlier failed builds, not cleared by `--no-cache` | Script now prunes `exec.cachemount` cache on every run |

## Changing the port

Edit the `ports:` mapping in `docker-compose.yml` (`"9090:8000"`) and the
`HOST_PORT` variable at the top of `deploy-sadtalker.sh` to match.
