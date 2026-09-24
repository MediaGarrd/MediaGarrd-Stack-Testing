# MediaGarrd local test harness

Fully isolated, disposable Docker Compose stack that exercises the real
MediaGarrd server ⇄ client backup workflow against fake service data, so
breaking changes can be verified without touching a real deployment.

This directory is **not** part of the `MediaGarrd` repo and never modifies
it — it only builds images from `../MediaGarrd` (the actual source tree)
and mounts fake data into throwaway containers.

## Run it
```bash
git clone https://github.com/MediaGarrd/MediaGarrd-Stack-Testing.git
cd MediaGarrd-Stack-Testing
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

## Requirements
- Docker with Compose v2 (`docker compose ...`)
- `curl`, `jq`, `unzip` on the host running `run-test.sh`
