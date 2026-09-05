# MediaGarrd local test harness

Fully isolated, disposable Docker Compose stack that exercises the real
MediaGarrd server ⇄ client backup workflow against fake service data, so
breaking changes can be verified without touching a real deployment.

This directory is **not** part of the `MediaGarrd` repo and never modifies
it — it only builds images from `../MediaGarrd` (the actual source tree)
and mounts fake data into throwaway containers.

## Run it

```bash
cd testing
./run-test.sh
```

Prints exactly one of:

```
TEST PASSED
```

or

```
TEST FAILED BECAUSE OF <reason>
```

and always tears down every container, image tag, volume, and network it
created, whether the test passes or fails.

Note: the first run has to build both Gradle images from scratch (Docker
layer caching makes subsequent runs much faster). The ~30s budget applies
to the actual test workflow (trigger backup → list → fetch latest →
validate archive contents) once both containers report healthy — not to
the initial image build.

## What it does

1. Builds `mediagarrd-server:test` and `mediagarrd-client:test` from
   `../MediaGarrd` (same Dockerfiles used in production).
2. Mounts small dummy config/db files from `./fake-services/` into the
   server container at the exact paths its `application.yml` expects for
   Jellyfin, Radarr, Sonarr, Prowlarr, Tdarr, and QBittorrent — no real
   media-server instances required.
3. Waits for both containers' HTTP endpoints to come up.
4. Lets the client auto-resolve the server via `MEDIAGARRD_SERVER_IP`
   (container DNS name), same auto-resolve path the real client uses.
5. Triggers a real backup run through the client
   (`POST /api/client/backups/run`), confirms the server produced a
   listable archive with a non-zero size.
6. Triggers the client's pickup workflow
   (`POST /api/client/pickup` → poll `GET
   /api/client/pickup/progress/{taskId}`), confirms it reaches `COMPLETED`.
7. Copies the downloaded archive out of the client container and inspects
   it with `unzip -l`, asserting every enabled service's data made it into
   the zip under the expected path.

## Isolation from a real deployment

- Compose project name `mediagarrd-test`, network `mediagarrd-test-net`,
  named volumes prefixed `mediagarrd-test-*`, and images tagged `:test` —
  nothing here can collide with a production `docker-compose.yml` running
  on the same host, even if it uses the default `:latest` tag.
- Host ports `18080`/`18081` are used instead of the real deployment's
  `38471`/`8081` to avoid any port clash.
- All state lives in Docker-managed volumes removed by `down -v` at the end
  of every run — nothing is written under `../MediaGarrd/data/`.

## Requirements

- Docker with Compose v2 (`docker compose ...`)
- `curl`, `jq`, `unzip` on the host running `run-test.sh`
