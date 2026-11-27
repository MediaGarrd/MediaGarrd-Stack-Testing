# MediaGarrd stack integration test

Fully isolated, disposable Docker Compose stack that exercises the real
MediaGarrd Server <--> Client backup workflow against fake service data, so
breaking changes can be verified without touching a real deployment.

The run:

1. Gets the sources — clones [Server](https://github.com/MediaGarrd/Server)
   and [Client](https://github.com/MediaGarrd/Client) at the requested
   branches, or uses a local checkout.
2. Runs each app's unit tests (`make test`) if it ships a `Makefile`.
3. Builds both images and starts them, giving the server the host Docker
   socket.
4. Detects whether each app has authentication (pairing and a dashboard
   login): the server by probing `GET /api/v1/clients` (401 with a `Bearer`
   challenge, or 404), the client by probing `GET /api/auth/status` (200 or
   404). Two auth-enabled apps run the auth flow below; a mixed pair fails at
   once and names the side without authentication. Two apps from before the
   authentication change fail with an error naming `--legacy`; with `--legacy`
   (or `MG_LEGACY=1`) they run the legacy flow instead. `--legacy` on two
   auth-enabled apps fails the run.
5. Runs the server's first-time setup (in the auth flow it first checks that
   `POST /api/v1/pair` answers 409 before setup): reads the setup PIN from the server
   logs, unlocks setup, registers the `./fake-services` directories as
   `mgtest-*` services through `POST /api/v1/services` (host paths, so the
   Docker daemon must be able to see this directory), finishes setup, and
   checks that `/config` is disabled afterwards.
6. Auth flow only: checks that the server refuses requests without a token
   (`/api/v1/services`, `/api/v1/clients`, an invalid token) and that
   `/api/v1/health` without one returns only `healthy` and `backupInterval`;
   signs in to the client dashboard with a random per-run password
   (`CLIENT_PASSWORD`, set through the compose file) and keeps the session
   cookie in a private temp file; checks that the client refuses a request
   without a session, a write without the CSRF header, and a wrong password;
   waits for the client to find the server, reads the `Pairing PIN` from the
   server logs, checks that a wrong PIN answers 401, pairs through `POST /api/client/pairing`, and checks
   that the used PIN is refused with 403 and that pairing again while paired
   answers 409. Then it creates a pairing code through the client, pairs a
   second client with it through `POST /api/v1/pair`, confirms it with a
   bearer request, checks that `GET /api/v1/clients` lists both and that the
   code cannot be reused, unpairs the second client through the server API
   and the first through the client (`DELETE /api/client/pairing`), checks
   that the client then answers 502 with `pairing: required`, that the server
   logs a new `Pairing PIN`, and pairs the client again with it. Then it
   restarts the server (`docker restart`) and checks that it logs no new
   `Pairing PIN`, that `POST /api/v1/pair` still answers 403 and that the
   client still lists backups with its stored token, restarts the client and
   checks that the same password signs in and the pairing is still there, and
   starts a second client without `CLIENT_PASSWORD` to check that the first
   password set wins (200), a second attempt is refused (409), the first
   password signs in, and the stored password survives a restart of that
   client.
7. Drives health -> server resolution -> backup run -> listing -> pickup ->
   archive validation through the client API. The listing step records the
   backup ids before the run, requires a new newest backup afterwards, and
   the pickup must start for exactly that backup. In the auth flow every client
   call carries the session cookie and the `X-MediaGarrd-Request: 1` header,
   and the client calls the server with its own bearer token, so a passing
   backup proves token authentication end to end.

The dashboard password and session cookie are never printed. The password is
passed to Compose through a private env file and to `curl` through private
files in the run's temp directory, and bodies of the login and pairing calls
are never shown on failure. On failure the server and client log tails are
printed; they can contain the `Setup PIN` and `Pairing PIN` the server logs by
design, and never the password. `last_run.txt` only holds the archive
listing.

## Run it locally
```bash
./run-test.sh                                        # both from main
./run-test.sh --server-branch my-feature             # Server branch, Client main
./run-test.sh --server-branch a --client-branch b
./run-test.sh --local ..                             # dir containing Server/ and Client/
make dev                                             # same as --local ..
./run-test.sh --local .. --legacy                    # apps from before authentication
make dev LOCAL_DIR=/path/to/checkouts                # other location
make dev LEGACY=1                                    # same as --legacy (survives sudo make, unlike MG_LEGACY=1)
```

Prints exactly one of:

```
TEST PASSED
TEST FAILED BECAUSE OF <reason>
```

and always tears down every container (including the server's
`mediagarrd-backup-mgtest-*` helper containers), volume, network, and clone
it created. The archive listing from the last run is written to `last_run.txt`.

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
remotes (PRs from forks won't resolve). Both branches must come from the same
side of the authentication change: both with pairing and the dashboard login,
or both without. Version 0.1.0 and later have it, so the defaults (`main`)
work once both `main` branches carry 0.1.0. The action is used from `@main`,
so changes here only take effect for other repos once they are pushed to
`main`. This script expects the 0.1.0 setup contract
(`POST /api/v1/setup/complete` answers 200 with a `pairingPin`) on an
auth-enabled stack, so land it before the Server and Client 0.1.0 changes.
Allow 30 minutes for the job: it builds both images and runs both unit-test
suites.

It can also be run manually from this repo's **Actions -> Integration test ->
Run workflow**, with both branches as inputs.

## Requirements (local)
- Docker with Compose v2 (`docker compose ...`), and permission to use it
  (the user in the `docker` group, or `sudo`). The script cannot run without
  it.
- `git`, `make`, `curl`, `jq`, `unzip`
- Node.js (the Client's `make test` runs its dashboard script tests with `node --test`)
- JDK 21 for the unit-test stage
