# MediaGarrd stack integration test

Fully isolated, disposable Docker Compose stack that exercises the real
MediaGarrd Server <--> Client backup workflow against fake service data, so
breaking changes can be verified without touching a real deployment.

The run:

1. Gets the sources — clones [Server](https://github.com/MediaGarrd/Server)
   and [Client](https://github.com/MediaGarrd/Client) at the requested
   branches, or uses a local checkout.
2. Runs each app's unit tests (`make test`) if it ships a `Makefile`.
3. Builds both images and starts them against `./fake-services`.
4. Drives health -> server resolution -> backup run -> listing -> pickup ->
   archive validation through the client API.

## Run it locally
```bash
./run-test.sh                                        # both from main
./run-test.sh --server-branch my-feature             # Server branch, Client main
./run-test.sh --server-branch a --client-branch b
./run-test.sh --local ..                             # dir containing Server/ and Client/
make dev                                             # same as --local ..
```

Prints exactly one of:

```
TEST PASSED
TEST FAILED BECAUSE OF <reason>
```

and always tears down every container, volume, network, and clone it
created. The archive listing from the last run is written to `last_run.txt`.

With `--local`, any of `Server/` or `Client/` missing from the given path is
replaced by a temporary clone of `main` (with a warning), which is removed
after the run. Nothing is cloned into or deleted from your directory.

`sudo` is only used for Docker if the current user can't reach the Docker
daemon directly.

## Run it as a GitHub Action

From any workflow (e.g. a PR check in the Server or Client repo):

```yaml
jobs:
  integration-test:
    runs-on: ubuntu-latest
    steps:
      - uses: MediaGarrd/MediaGarrd-Stack-Testing@main
        with:
          server-branch: ${{ github.head_ref }}   # default: main
          client-branch: main                     # default: main
```

Branches must exist on the `MediaGarrd/Server` / `MediaGarrd/Client`
remotes (PRs from forks won't resolve). Because this repo is private, other
repos can only use the action once *Settings -> Actions -> General -> Access*
allows repositories in the organization.

It can also be run manually from this repo's **Actions -> Integration test ->
Run workflow**, with both branches as inputs.

## Requirements (local)
- Docker with Compose v2 (`docker compose ...`)
- `git`, `make`, `curl`, `jq`, `unzip`
- JDK 21 for the unit-test stage
