#!/usr/bin/env bash
#
# End-to-end integration test for the MediaGarrd Server + Client.
#
# Builds both apps (from GitHub branches or a local checkout), starts them in
# an isolated Docker Compose stack, unlocks server setup with the PIN from
# the server logs, registers ./fake-services as services through the server
# API, finishes setup, and, when both apps have authentication, signs in to
# the client dashboard and pairs the client with the server using the Pairing
# PIN from the server logs. Then it drives a full
# backup -> list -> pickup -> verify cycle through the client API, and prints
# exactly one verdict:
#
#   TEST PASSED
#   TEST FAILED BECAUSE OF <reason>
#
# Everything the run creates (containers, volumes, network, clones) is torn
# down on exit.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly INVOKE_DIR="$PWD"


readonly COMPOSE_FILE="$SCRIPT_DIR/docker-compose.test.yml"
readonly LAST_RUN_FILE="$SCRIPT_DIR/last_run.txt"

readonly GITHUB_ORG_URL="https://github.com/MediaGarrd"
readonly APPS=(Server Client)

readonly SERVER_URL="http://localhost:18080"
readonly CLIENT_URL="http://localhost:18081"
readonly SERVER_CONTAINER="mediagarrd-server-test"
readonly CLIENT_CONTAINER="mediagarrd-client-test"
readonly FC_URL="http://localhost:18082"
readonly FC_CONTAINER="mediagarrd-client-fc-test"

readonly TIMEOUT_HEALTH=60  # seconds for each container to answer HTTP
readonly TIMEOUT_RESOLVE=15 # seconds for the client to resolve the server
readonly TIMEOUT_PICKUP=20  # seconds for the pickup task to complete
readonly TIMEOUT_BACKUP=60 # seconds for a backup to be listed after it was triggered
readonly TIMEOUT_RUN=300    # seconds for a client-triggered backup run (the first one may pull the helper image)
readonly TIMEOUT_PIN=10     # seconds for the pairing PIN to show up in the server logs

readonly FAKE_SERVICES_DIR="$SCRIPT_DIR/fake-services"
readonly FAKE_ROOT="${FAKE_SERVICES_DIR#/}"

# Services registered through the server API. Names are prefixed so the
# helper containers (mediagarrd-backup-<name>) never clash with a real
# deployment sharing the Docker daemon. Paths are relative to fake-services/.
readonly TEST_SERVICE_PREFIX="mgtest-"
readonly -A TEST_SERVICES=(
    [mgtest-jellyfin]="jellyfin/config"
    [mgtest-radarr]="radarr"
    [mgtest-sonarr]="sonarr"
    [mgtest-prowlarr]="prowlarr"
    [mgtest-tdarr]="tdarr"
    [mgtest-qbittorrent]="qbittorrent qbittorrent-saved-torrents/deleted_torrent.torrent.bak"
)

# Files that must appear in the downloaded backup archive, laid out by their
# absolute host path without the leading slash.
readonly EXPECTED_ARCHIVE_ENTRIES=(
    "$FAKE_ROOT/jellyfin/config/system.xml"
    "$FAKE_ROOT/jellyfin/config/plugins/plugin.dat"
    "$FAKE_ROOT/radarr/config/radarr.db"
    "$FAKE_ROOT/sonarr/config/sonarr.db"
    "$FAKE_ROOT/sonarr/config/current-config.xml"
    "$FAKE_ROOT/prowlarr/config/config.xml"
    "$FAKE_ROOT/tdarr/server/db.sqlite"
    "$FAKE_ROOT/qbittorrent/config/qBittorrent.conf"
    "$FAKE_ROOT/qbittorrent-saved-torrents/deleted_torrent.torrent.bak"
)

declare -A APP_BRANCH=([Server]="" [Client]="")
declare -A APP_DIR=()
LOCAL_PATH=""
WORKDIR=""
SETUP_COOKIES=""
CLIENT_COOKIES=""
COMPOSE_ENV_FILE=""
MGTEST_CLIENT_PASSWORD=""
AUTH_STACK=0
LEGACY=0
FC_COOKIES=""
BACKUP_IDS_BEFORE=""
NEW_BACKUP_ID=""
PAIRED_PIN=""
SECOND_ID=""
SECOND_AUTH_FILE=""
SUDO=()
RESULT=""
REASON=""


log() { echo "[test] $*" >&2; }

usage() {
    cat >&2 <<USAGE
Usage: $0 [--server-branch <name>] [--client-branch <name>] [--legacy]
       $0 --local <dir-containing-Server-and-Client> [--legacy]

Branches default to main. --local cannot be combined with the branch flags.
--legacy (or MG_LEGACY=1) runs the flow for apps from before authentication;
without it, apps without authentication fail the run, and with it, apps that
both have authentication fail the run.
USAGE
    exit "${1:-1}"
}

die() {
    echo "Error: $*" >&2
    exit 1
}

fail() {
    RESULT="FAIL"
    REASON="$1"
    exit 1
}

fail_with_logs() {
    dump_container_logs
    fail "$1"
}

pass() {
    RESULT="PASS"
    exit 0
}

interrupted() {
    fail "the run was interrupted"
}

on_exit() {
    local exit_code=$?
    trap '' INT TERM
    trap - EXIT
    log "Tearing down test environment..."
    compose down -v --remove-orphans >/dev/null 2>&1 || true
    remove_helper_containers
    [[ -n "$WORKDIR" ]] && rm -rf "$WORKDIR"

    case "$RESULT" in
        PASS) echo; echo "TEST PASSED"; exit 0 ;;
        FAIL) echo; echo "TEST FAILED BECAUSE OF ${REASON}"; exit 1 ;;
        *)    (( exit_code == 0 )) || { echo; echo "TEST FAILED BECAUSE OF an unexpected error (exit code ${exit_code})"; }
              exit "$exit_code" ;;
    esac
}

detect_docker_access() {
    if ! docker info >/dev/null 2>&1; then
        SUDO=(sudo)
    fi
}

docker_cmd() { "${SUDO[@]}" docker "$@"; }

compose() {
    local env_args=()
    if [[ -n "$COMPOSE_ENV_FILE" ]]; then
        env_args=(--env-file "$COMPOSE_ENV_FILE")
    fi
    "${SUDO[@]}" env \
        MEDIAGARRD_SERVER_DIR="${APP_DIR[Server]:-}" \
        MEDIAGARRD_CLIENT_DIR="${APP_DIR[Client]:-}" \
        docker compose --profile firstcome "${env_args[@]}" -f "$COMPOSE_FILE" "$@"
}

remove_helper_containers() {
    local ids
    ids="$(docker_cmd ps -aq --filter "name=mediagarrd-backup-${TEST_SERVICE_PREFIX}" 2>/dev/null)" || return 0
    [[ -n "$ids" ]] && docker_cmd rm -f $ids >/dev/null 2>&1 || true
}

dump_container_logs() {
    local container
    for container in "$SERVER_CONTAINER" "$CLIENT_CONTAINER" "$FC_CONTAINER"; do
        log "----- ${container} logs (tail) -----"
        compose logs --no-color --tail=60 "$container" 2>&1 | sed "s/^/[${container}] /" >&2 || true
    done
}

http_get()  { curl -fsS --max-time "${2:-5}" "$1"; }
http_post() { curl -fsS --max-time "${2:-5}" -X POST "$1"; }

client_curl() { curl -b "$CLIENT_COOKIES" -c "$CLIENT_COOKIES" -H 'X-MediaGarrd-Request: 1' "$@"; }
client_get()  { client_curl -fsS --max-time "${2:-5}" "$1"; }
client_post() { client_curl -fsS --max-time "${2:-5}" -X POST "$1"; }

extract_pairing_pin() {
    { grep -oE 'Pairing PIN: [0-9]{6}' || true; } | tail -1 | awk '{print $3}'
}

classify_server_probe() {
    local headers code
    headers="$(tr -d '\r')"
    code="$(awk 'NR == 1 {print $2}' <<<"$headers")"
    if [[ "$code" == "401" ]] && grep -qiE '^www-authenticate:[[:space:]]*bearer' <<<"$headers"; then
        echo auth
    elif [[ "$code" == "404" ]]; then
        echo pre-auth
    else
        echo "unknown ${code:-no-response}"
    fi
}

classify_client_probe() {
    case "$1" in
        200) echo auth ;;
        404) echo pre-auth ;;
        *)   echo "unknown $1" ;;
    esac
}

write_body() { printf '%s' "$1" > "$WORKDIR/body.json"; }

random_secret() {
    head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

server_up() { curl -fsS --max-time 3 -o /dev/null "${SERVER_URL}/api/v1/health"; }
client_up() { [[ "$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' "${CLIENT_URL}/api/auth/status")" != "000" ]]; }
fc_up() { [[ "$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' "${FC_URL}/api/auth/status")" != "000" ]]; }

retry_for() {
    local timeout="$1" check_fn="$2" elapsed=0
    until "$check_fn"; do
        (( elapsed >= timeout )) && return 1
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --server-branch) [[ $# -ge 2 ]] || die "--server-branch requires a value"; APP_BRANCH[Server]="$2"; shift 2 ;;
            --client-branch) [[ $# -ge 2 ]] || die "--client-branch requires a value"; APP_BRANCH[Client]="$2"; shift 2 ;;
            --local)         [[ $# -ge 2 ]] || die "--local requires a path";         LOCAL_PATH="$2";    shift 2 ;;
            --legacy)        LEGACY=1; shift ;;
            -h|--help)       usage 0 ;;
            *)               echo "Unknown argument: $1" >&2; usage ;;
        esac
    done

    if [[ -n "$LOCAL_PATH" && ( -n "${APP_BRANCH[Server]}" || -n "${APP_BRANCH[Client]}" ) ]]; then
        die "--local cannot be combined with --server-branch/--client-branch"
    fi
    [[ "${MG_LEGACY:-}" == "1" ]] && LEGACY=1
    APP_BRANCH[Server]="${APP_BRANCH[Server]:-main}"
    APP_BRANCH[Client]="${APP_BRANCH[Client]:-main}"
}

check_dependencies() {
    local cmd
    for cmd in docker curl jq unzip git make; do
        command -v "$cmd" >/dev/null || die "required command '$cmd' not found on PATH"
    done
}

# Clones live in WORKDIR, so teardown removes them.
clone_app() {
    local app="$1" branch="${APP_BRANCH[$1]}"
    APP_DIR[$app]="$WORKDIR/src/$app"
    log "Cloning ${app}@${branch}..."
    (umask 022; git clone --quiet --depth 1 --branch "$branch" "$GITHUB_ORG_URL/$app" "${APP_DIR[$app]}") \
        || fail "could not clone ${app} branch '${branch}'"
}

stage_sources() {
    local app local_root=""
    if [[ -n "$LOCAL_PATH" ]]; then
        local_root="$(cd "$INVOKE_DIR" && cd "$LOCAL_PATH" 2>/dev/null && pwd)" \
            || log "WARNING: --local path '${LOCAL_PATH}' does not exist"
    fi

    for app in "${APPS[@]}"; do
        if [[ -n "$local_root" && -d "$local_root/$app" ]]; then
            APP_DIR[$app]="$local_root/$app"
            log "Using local ${app} from ${APP_DIR[$app]}"
            continue
        fi
        if [[ -n "$LOCAL_PATH" ]]; then
            log "WARNING: no ${app} under '${LOCAL_PATH}', using a temporary clone of main instead"
        fi
        clone_app "$app"
    done
}

create_fixture_links() {
    ln -sfn config.xml "$FAKE_SERVICES_DIR/sonarr/config/current-config.xml" \
        || fail "could not create the fixture symbolic link"
}

run_unit_tests() {
    local app
    for app in "${APPS[@]}"; do
        if [[ ! -f "${APP_DIR[$app]}/Makefile" ]]; then
            log "No Makefile in ${app}, skipping its unit tests"
            continue
        fi
        log "Running ${app} unit tests (make test)..."
        (umask 022; make -C "${APP_DIR[$app]}" test >&2) || fail "${app} unit tests failed (make test)"
    done
}

start_stack() {
    log "Building and starting isolated test stack..."
    compose up -d --build "$SERVER_CONTAINER" "$CLIENT_CONTAINER" || fail_with_logs "docker compose up --build failed (see build output above)"

    log "Waiting for containers to answer HTTP..."
    retry_for "$TIMEOUT_HEALTH" server_up 2>/dev/null \
        || fail_with_logs "MediaGarrd-Server not reachable at ${SERVER_URL} after ${TIMEOUT_HEALTH}s"
    retry_for "$TIMEOUT_HEALTH" client_up 2>/dev/null \
        || fail_with_logs "MediaGarrd-Client not reachable at ${CLIENT_URL} after ${TIMEOUT_HEALTH}s"
}

step_server_healthy() {
    local body
    body="$(http_get "${SERVER_URL}/api/v1/health")" || fail_with_logs "GET /api/v1/health request failed"
    [[ "$(jq -r '.healthy // false' <<<"$body")" == "true" ]] \
        || fail_with_logs "server health payload did not report healthy=true (got: ${body})"
}

request_status() {
    curl -s --max-time 10 -o "$WORKDIR/response.txt" -w '%{http_code}' "$@" || true
}

expect_status() {
    local expected="$1" what="$2" code
    shift 2
    code="$(request_status "$@")"
    [[ "$code" == "$expected" ]] \
        || fail_with_logs "${what} returned HTTP ${code}, expected ${expected} (body: $(cat "$WORKDIR/response.txt" 2>/dev/null))"
}

expect_status_quiet() {
    local expected="$1" what="$2" code
    shift 2
    code="$(request_status "$@")"
    [[ "$code" == "$expected" ]] \
        || fail_with_logs "${what} returned HTTP ${code}, expected ${expected}"
}

post_json() {
    local expected="$1" what="$2" body="$3" url="$4"
    expect_status "$expected" "$what" -b "$SETUP_COOKIES" -c "$SETUP_COOKIES" \
        -X POST -H 'Content-Type: application/json' -d "$body" "$url"
}

step_pair_before_setup() {
    write_body '{"pin":"123456"}'
    expect_status_quiet 409 "POST /api/v1/pair before setup was finished" -X POST \
        -H 'Content-Type: application/json' --data-binary "@$WORKDIR/body.json" "${SERVER_URL}/api/v1/pair"
    rm -f "$WORKDIR/body.json"
}

step_unlock_setup() {
    local pin
    expect_status 401 "config API before setup was unlocked" "${SERVER_URL}/api/v1/services"
    pin="$(docker_cmd logs "$SERVER_CONTAINER" 2>&1 | grep -oE 'Setup PIN: [0-9]{6}' | tail -1 | awk '{print $3}')" || true
    [[ -n "$pin" ]] || fail_with_logs "server did not log a setup PIN"
    post_json 204 "POST /api/v1/setup/session" "{\"pin\": \"${pin}\"}" "${SERVER_URL}/api/v1/setup/session"
}

step_register_services() {
    local name rel count paths
    for name in "${!TEST_SERVICES[@]}"; do
        paths=()
        for rel in ${TEST_SERVICES[$name]}; do
            paths+=("$FAKE_SERVICES_DIR/$rel")
        done
        post_json 201 "POST /api/v1/services for ${name}" \
            "$(jq -n --arg name "$name" '{name: $name, paths: $ARGS.positional}' --args "${paths[@]}")" \
            "${SERVER_URL}/api/v1/services"
    done
    count="$(curl -fsS --max-time 5 -b "$SETUP_COOKIES" "${SERVER_URL}/api/v1/services" | jq 'length')" \
        || fail_with_logs "GET /api/v1/services after registering the services did not return a JSON list"
    [[ "$count" == "${#TEST_SERVICES[@]}" ]] \
        || fail_with_logs "expected ${#TEST_SERVICES[@]} registered services, server lists ${count}"
}

step_complete_setup() {
    if (( AUTH_STACK )); then
        post_json 200 "POST /api/v1/setup/complete" "{}" "${SERVER_URL}/api/v1/setup/complete"
        jq -e '.pairingPin | test("^[0-9]{6}$")' "$WORKDIR/response.txt" >/dev/null 2>&1 \
            || fail_with_logs "POST /api/v1/setup/complete did not return a 6-digit pairingPin"
        SETUP_REPLY_PIN="$(jq -r '.pairingPin' "$WORKDIR/response.txt")"
    else
        post_json 204 "POST /api/v1/setup/complete" "{}" "${SERVER_URL}/api/v1/setup/complete"
    fi
    expect_status 404 "/config after setup completed" "${SERVER_URL}/config"
    if (( AUTH_STACK )); then
        expect_status 401 "config API after setup completed, without a token" "${SERVER_URL}/api/v1/services"
    else
        expect_status 200 "config API after setup completed" "${SERVER_URL}/api/v1/services"
    fi
}

step_server_requires_token() {
    local body keys
    expect_status 401 "GET /api/v1/clients without a token" "${SERVER_URL}/api/v1/clients"
    expect_status 401 "GET /api/v1/services with an invalid token" -H 'Authorization: Bearer not-a-real-token' "${SERVER_URL}/api/v1/services"
    body="$(http_get "${SERVER_URL}/api/v1/health")" || fail_with_logs "GET /api/v1/health request failed"
    keys="$(jq -c 'keys' <<<"$body" 2>/dev/null || echo invalid)"
    [[ "$keys" == '["backupInterval","healthy"]' ]] \
        || fail_with_logs "health without a token exposed unexpected fields: ${keys}"
}

step_client_login() {
    write_body "{\"password\":\"${MGTEST_CLIENT_PASSWORD}\"}"
    expect_status_quiet 200 "dashboard login" -c "$CLIENT_COOKIES" -X POST \
        -H 'Content-Type: application/json' -H 'X-MediaGarrd-Request: 1' --data-binary "@$WORKDIR/body.json" "${CLIENT_URL}/api/auth/login"
    expect_status 401 "GET /api/client/status without a session" "${CLIENT_URL}/api/client/status"
    expect_status 403 "POST /api/client/backups/run with a session but without the CSRF header" \
        -b "$CLIENT_COOKIES" -X POST "${CLIENT_URL}/api/client/backups/run"
    write_body "{\"password\":\"wrong-$(random_secret)\"}"
    expect_status_quiet 401 "dashboard login with a wrong password" -X POST \
        -H 'Content-Type: application/json' -H 'X-MediaGarrd-Request: 1' --data-binary "@$WORKDIR/body.json" "${CLIENT_URL}/api/auth/login"
    rm -f "$WORKDIR/body.json"
}

step_client_resolves_server() {
    local active_server=""
    resolved() {
        active_server="$(client_get "${CLIENT_URL}/api/client/status" 2>/dev/null | jq -r '.activeServer // empty' 2>/dev/null)"
        [[ -n "$active_server" ]]
    }
    retry_for "$TIMEOUT_RESOLVE" resolved \
        || fail_with_logs "client never resolved an active server within ${TIMEOUT_RESOLVE}s"
    log "Client resolved active server: ${active_server}"
    [[ "$active_server" == *"$SERVER_CONTAINER"* ]] \
        || fail_with_logs "client resolved unexpected server '${active_server}' (expected ${SERVER_CONTAINER})"
}

logged_pairing_pin() {
    docker_cmd logs "$SERVER_CONTAINER" 2>&1 | extract_pairing_pin
}

step_pair_wrong_pin() {
    local pin="" wrong
    pin_logged() {
        pin="$(logged_pairing_pin)"
        [[ -n "$pin" ]]
    }
    retry_for "$TIMEOUT_PIN" pin_logged \
        || fail_with_logs "server did not log a pairing PIN within ${TIMEOUT_PIN}s"
    wrong="$(printf '%06d' $(( (10#$pin + 1) % 1000000 )))"
    write_body "{\"pin\":\"${wrong}\"}"
    expect_status_quiet 401 "POST /api/v1/pair with a wrong PIN" -X POST \
        -H 'Content-Type: application/json' --data-binary "@$WORKDIR/body.json" "${SERVER_URL}/api/v1/pair"
    rm -f "$WORKDIR/body.json"
}

pair_client_with() {
    local pin="$1" code=""
    write_body "{\"pin\":\"${pin}\",\"name\":\"mgtest-client\"}"
    paired() {
        code="$(request_status -b "$CLIENT_COOKIES" -c "$CLIENT_COOKIES" -X POST \
            -H 'Content-Type: application/json' -H 'X-MediaGarrd-Request: 1' --data-binary "@$WORKDIR/body.json" "${CLIENT_URL}/api/client/pairing")"
        [[ "$code" == "200" ]] && return 0
        if [[ "$code" == "400" ]] && jq -e '(.error // "") | startswith("No active")' "$WORKDIR/response.txt" >/dev/null 2>&1; then
            return 1
        fi
        fail_with_logs "POST /api/client/pairing returned HTTP ${code}, expected 200"
    }
    retry_for "$TIMEOUT_RESOLVE" paired \
        || fail_with_logs "client had no active server to pair with after ${TIMEOUT_RESOLVE}s"
    [[ "$(jq -r '.paired // false' "$WORKDIR/response.txt" 2>/dev/null)" == "true" ]] \
        || fail_with_logs "POST /api/client/pairing did not report paired=true"
    jq -e '.note == null' "$WORKDIR/response.txt" >/dev/null 2>&1 \
        || fail_with_logs "POST /api/client/pairing reported a note after a confirmed pairing"
    rm -f "$WORKDIR/response.txt" "$WORKDIR/body.json"
    PAIRED_PIN="$pin"
}

step_pair_client() {
    local pin=""
    pin_logged() {
        pin="$(logged_pairing_pin)"
        [[ -n "$pin" ]]
    }
    retry_for "$TIMEOUT_PIN" pin_logged \
        || fail_with_logs "server did not log a pairing PIN within ${TIMEOUT_PIN}s"
    if [[ -n "${SETUP_REPLY_PIN:-}" && "$SETUP_REPLY_PIN" != "$pin" ]]; then
        fail_with_logs "the pairingPin in the setup/complete reply (${SETUP_REPLY_PIN}) differs from the logged Pairing PIN (${pin})"
    fi

    pair_client_with "$pin"
}

step_pairing_closed() {
    local code
    write_body "{\"pin\":\"${PAIRED_PIN}\"}"
    code="$(request_status -X POST -H 'Content-Type: application/json' --data-binary "@$WORKDIR/body.json" "${SERVER_URL}/api/v1/pair")"
    [[ "$code" == "403" ]] \
        || fail_with_logs "POST /api/v1/pair with the already used PIN returned HTTP ${code}, expected 403"
}

step_repair_refused() {
    write_body "{\"pin\":\"${PAIRED_PIN}\",\"name\":\"mgtest-client\"}"
    expect_status_quiet 409 "POST /api/client/pairing while the client is paired" -b "$CLIENT_COOKIES" -X POST \
        -H 'Content-Type: application/json' -H 'X-MediaGarrd-Request: 1' --data-binary "@$WORKDIR/body.json" "${CLIENT_URL}/api/client/pairing"
    rm -f "$WORKDIR/body.json"
}

step_pair_second_client() {
    local body code
    body="$(client_post "${CLIENT_URL}/api/client/pairing/code" 10)" || fail_with_logs "POST /api/client/pairing/code request failed"
    code="$(jq -r '.code // empty' <<<"$body")" || true
    [[ -n "$code" ]] || fail_with_logs "POST /api/client/pairing/code did not return a code"

    write_body "{\"pin\":\"${code}\",\"name\":\"mgtest-second\"}"
    expect_status 200 "POST /api/v1/pair with a pairing code" -X POST \
        -H 'Content-Type: application/json' --data-binary "@$WORKDIR/body.json" "${SERVER_URL}/api/v1/pair"
    local token
    token="$(jq -r '.token // empty' "$WORKDIR/response.txt")" || true
    SECOND_ID="$(jq -r '.id // empty' "$WORKDIR/response.txt")" || true
    [[ -n "$token" && -n "$SECOND_ID" ]] || fail_with_logs "POST /api/v1/pair with a pairing code returned no token or id"
    SECOND_AUTH_FILE="$WORKDIR/second-auth.txt"
    printf 'Authorization: Bearer %s\n' "$token" > "$SECOND_AUTH_FILE"

    expect_status 200 "GET /api/v1/health with the second client's token" \
        -H "@${SECOND_AUTH_FILE}" "${SERVER_URL}/api/v1/health"
    expect_status 200 "GET /api/v1/clients with the second client's token" \
        -H "@${SECOND_AUTH_FILE}" "${SERVER_URL}/api/v1/clients"
    [[ "$(jq 'length' "$WORKDIR/response.txt")" == "2" ]] \
        || fail_with_logs "expected 2 paired clients, got: $(cat "$WORKDIR/response.txt")"
    [[ "$(jq -r --arg id "$SECOND_ID" '[.[] | select(.current == true)] | map(.id) | . == [$id]' "$WORKDIR/response.txt")" == "true" ]] \
        || fail_with_logs "GET /api/v1/clients did not mark the second client as current"

    expect_status_quiet 401 "POST /api/v1/pair with an already used pairing code" -X POST \
        -H 'Content-Type: application/json' --data-binary "@$WORKDIR/body.json" "${SERVER_URL}/api/v1/pair"
    rm -f "$WORKDIR/body.json"
}

backups_listed() { client_get "${CLIENT_URL}/api/client/backups" 10 >/dev/null 2>&1; }

step_restart_server() {
    local pins_before pins_after code
    pins_before="$(docker_cmd logs "$SERVER_CONTAINER" 2>&1 | grep -c 'Pairing PIN: ' || true)"
    docker_cmd restart "$SERVER_CONTAINER" >/dev/null || fail_with_logs "could not restart ${SERVER_CONTAINER}"
    retry_for "$TIMEOUT_HEALTH" server_up 2>/dev/null \
        || fail_with_logs "MediaGarrd-Server not reachable at ${SERVER_URL} ${TIMEOUT_HEALTH}s after a restart"

    pins_after="$(docker_cmd logs "$SERVER_CONTAINER" 2>&1 | grep -c 'Pairing PIN: ' || true)"
    [[ "$pins_after" == "$pins_before" ]] \
        || fail_with_logs "the restarted server logged a new Pairing PIN although a client is paired"

    write_body "{\"pin\":\"${PAIRED_PIN}\"}"
    code="$(request_status -X POST -H 'Content-Type: application/json' --data-binary "@$WORKDIR/body.json" "${SERVER_URL}/api/v1/pair")"
    rm -f "$WORKDIR/body.json"
    [[ "$code" == "403" ]] \
        || fail_with_logs "POST /api/v1/pair after a server restart returned HTTP ${code}, expected 403 (setup and pairing state must survive a restart)"

    retry_for "$TIMEOUT_RESOLVE" backups_listed \
        || fail_with_logs "the client could not list backups with its stored token after the server restarted"
}

login_client() {
    write_body "{\"password\":\"${MGTEST_CLIENT_PASSWORD}\"}"
    expect_status_quiet 200 "dashboard login after a restart" -c "$CLIENT_COOKIES" -X POST \
        -H 'Content-Type: application/json' -H 'X-MediaGarrd-Request: 1' --data-binary "@$WORKDIR/body.json" "${CLIENT_URL}/api/auth/login"
    rm -f "$WORKDIR/body.json"
}

step_restart_client() {
    docker_cmd restart "$CLIENT_CONTAINER" >/dev/null || fail_with_logs "could not restart ${CLIENT_CONTAINER}"
    retry_for "$TIMEOUT_HEALTH" client_up 2>/dev/null \
        || fail_with_logs "MediaGarrd-Client not reachable at ${CLIENT_URL} ${TIMEOUT_HEALTH}s after a restart"
    login_client

    retry_for "$TIMEOUT_RESOLVE" backups_listed \
        || fail_with_logs "the restarted client could not list backups: its stored pairing did not survive"
}

fc_password_request() {
    local expected="$1" what="$2" endpoint="$3" password="$4"
    write_body "{\"password\":\"${password}\"}"
    expect_status_quiet "$expected" "$what" -c "$FC_COOKIES" -X POST \
        -H 'Content-Type: application/json' -H 'X-MediaGarrd-Request: 1' --data-binary "@$WORKDIR/body.json" "${FC_URL}/api/auth/${endpoint}"
    rm -f "$WORKDIR/body.json"
}

step_first_come_password() {
    local first second
    first="$(random_secret)"
    second="$(random_secret)"
    FC_COOKIES="$WORKDIR/fc-cookies.txt"

    compose up -d --no-build "$FC_CONTAINER" || fail_with_logs "could not start ${FC_CONTAINER}"
    retry_for "$TIMEOUT_HEALTH" fc_up 2>/dev/null \
        || fail_with_logs "the client without CLIENT_PASSWORD is not reachable at ${FC_URL} after ${TIMEOUT_HEALTH}s"
    [[ "$(curl -fsS --max-time 5 "${FC_URL}/api/auth/status" | jq -r '.passwordSet')" == "false" ]] \
        || fail_with_logs "the client without CLIENT_PASSWORD already reports a password"

    fc_password_request 409 "login before any password is set" login "$first"
    fc_password_request 200 "first set-password" set-password "$first"
    fc_password_request 409 "second set-password" set-password "$second"
    fc_password_request 401 "login with the refused second password" login "$second"
    fc_password_request 200 "login with the first password" login "$first"

    docker_cmd restart "$FC_CONTAINER" >/dev/null || fail_with_logs "could not restart ${FC_CONTAINER}"
    retry_for "$TIMEOUT_HEALTH" fc_up 2>/dev/null \
        || fail_with_logs "the client without CLIENT_PASSWORD is not reachable at ${FC_URL} ${TIMEOUT_HEALTH}s after a restart"
    [[ "$(curl -fsS --max-time 5 "${FC_URL}/api/auth/status" | jq -r '.passwordSet')" == "true" ]] \
        || fail_with_logs "the stored dashboard password did not survive a client restart"
    fc_password_request 200 "login with the first password after a restart" login "$first"

    compose rm -sf "$FC_CONTAINER" >/dev/null 2>&1 || true
}

step_unpair_and_repair() {
    local new_pin="" pins_before
    pins_before="$(docker_cmd logs "$SERVER_CONTAINER" 2>&1 | grep -c 'Pairing PIN: ' || true)"
    expect_status_quiet 204 "DELETE /api/v1/clients/{id} for the second client" -X DELETE \
        -H "@${SECOND_AUTH_FILE}" "${SERVER_URL}/api/v1/clients/${SECOND_ID}"
    expect_status_quiet 401 "GET /api/v1/clients with the revoked token" \
        -H "@${SECOND_AUTH_FILE}" "${SERVER_URL}/api/v1/clients"
    rm -f "$SECOND_AUTH_FILE"

    expect_status 200 "DELETE /api/client/pairing" -b "$CLIENT_COOKIES" -X DELETE \
        -H 'X-MediaGarrd-Request: 1' "${CLIENT_URL}/api/client/pairing"
    [[ "$(jq -r '.serverRevoked' "$WORKDIR/response.txt")" == "true" ]] \
        || fail_with_logs "DELETE /api/client/pairing did not report serverRevoked=true (body: $(cat "$WORKDIR/response.txt"))"
    jq -e '.warning == null' "$WORKDIR/response.txt" >/dev/null 2>&1 \
        || fail_with_logs "DELETE /api/client/pairing returned a warning (body: $(cat "$WORKDIR/response.txt"))"

    expect_status 502 "GET /api/client/backups after unpairing" -b "$CLIENT_COOKIES" \
        -H 'X-MediaGarrd-Request: 1' "${CLIENT_URL}/api/client/backups"
    [[ "$(jq -r '.pairing // empty' "$WORKDIR/response.txt")" == "required" ]] \
        || fail_with_logs "GET /api/client/backups after unpairing did not report pairing=required (body: $(cat "$WORKDIR/response.txt"))"

    reopened_pin_logged() {
        (( $(docker_cmd logs "$SERVER_CONTAINER" 2>&1 | grep -c 'Pairing PIN: ' || true) > pins_before )) || return 1
        new_pin="$(logged_pairing_pin)"
        [[ -n "$new_pin" ]]
    }
    retry_for "$TIMEOUT_PIN" reopened_pin_logged \
        || fail_with_logs "server did not log a new pairing PIN within ${TIMEOUT_PIN}s of the last client being unpaired"

    pair_client_with "$new_pin"
}

run_backup_request() {
    client_curl -s --max-time "$TIMEOUT_RUN" -o "$WORKDIR/run-response.txt" -w '%{http_code}' -X POST "${CLIENT_URL}/api/client/backups/run" || true
}

new_backup_listed() {
    local body id size
    body="$(client_get "${CLIENT_URL}/api/client/backups" 10 2>/dev/null)" || return 1
    id="$(jq -r '.[0].id // empty' <<<"$body" 2>/dev/null)" || return 1
    [[ -n "$id" ]] || return 1
    if grep -qxF -- "$id" <<<"$BACKUP_IDS_BEFORE"; then
        return 1
    fi
    size="$(jq -r '.[0].sizeBytes' <<<"$body" 2>/dev/null)" || return 1
    [[ "$size" =~ ^[0-9]+$ ]] && (( size > 0 ))
}

step_trigger_backup() {
    local code body
    body="$(client_get "${CLIENT_URL}/api/client/backups" 10)" || fail_with_logs "GET /api/client/backups request failed before triggering a run"
    BACKUP_IDS_BEFORE="$(jq -r '.[].id' <<<"$body" 2>/dev/null)" \
        || fail_with_logs "GET /api/client/backups did not return a JSON list before triggering a run (body: ${body})"
    code="$(run_backup_request)"
    if [[ "$code" == "409" ]] && grep -qi 'already in progress' "$WORKDIR/run-response.txt" 2>/dev/null; then
        log "A scheduled backup was already running, retrying until it has finished"
        retry_run_accepted() {
            code="$(run_backup_request)"
            [[ "$code" != "409" ]]
        }
        retry_for "$TIMEOUT_BACKUP" retry_run_accepted \
            || fail_with_logs "POST /api/client/backups/run still answered 409 after ${TIMEOUT_BACKUP}s"
    fi
    [[ "$code" == "200" ]] \
        || fail_with_logs "POST /api/client/backups/run returned HTTP ${code} (body: $(cat "$WORKDIR/run-response.txt" 2>/dev/null))"
}

step_backup_listed() {
    local body size

    retry_for "$TIMEOUT_BACKUP" new_backup_listed \
        || fail_with_logs "expected a new backup with sizeBytes > 0 within ${TIMEOUT_BACKUP}s of triggering a run, but the newest listed backup was already there before it"
    body="$(client_get "${CLIENT_URL}/api/client/backups" 10)" || fail_with_logs "GET /api/client/backups request failed"
    NEW_BACKUP_ID="$(jq -r '.[0].id // empty' <<<"$body")" || true
    size="$(jq -r '.[0].sizeBytes // empty' <<<"$body")" || true
    [[ -n "$NEW_BACKUP_ID" ]] || fail_with_logs "GET /api/client/backups returned no newest backup id (body: ${body})"
    log "New backup: id=${NEW_BACKUP_ID}, sizeBytes=${size}"
}

step_pickup_latest() {
    local body task_id started_id status="" progress=""
    body="$(client_post "${CLIENT_URL}/api/client/pickup" 10)" || fail_with_logs "POST /api/client/pickup request failed"
    task_id="$(jq -r '.taskId // empty' <<<"$body")" || true
    [[ -n "$task_id" ]] || fail_with_logs "POST /api/client/pickup did not return a taskId (body: ${body})"
    started_id="$(jq -r '.backupId // empty' <<<"$body")" || true
    [[ -n "$NEW_BACKUP_ID" && "$started_id" == "$NEW_BACKUP_ID" ]] \
        || fail_with_logs "pickup started for backup '${started_id}', expected the backup the triggered run created (${NEW_BACKUP_ID})"

    finished() {
        progress="$(client_get "${CLIENT_URL}/api/client/pickup/progress/${task_id}" 2>/dev/null)" || return 1
        status="$(jq -r '.status // empty' <<<"$progress")"
        [[ "$status" == "COMPLETED" || "$status" == "FAILED" ]]
    }
    retry_for "$TIMEOUT_PICKUP" finished \
        || fail_with_logs "pickup task ${task_id} did not finish within ${TIMEOUT_PICKUP}s (last status: ${status:-none})"
    [[ "$status" == "COMPLETED" ]] \
        || fail_with_logs "pickup task ${task_id} FAILED: $(jq -r '.error // "unknown error"' <<<"$progress")"

    PICKUP_SAVED_PATH="$(jq -r '.savedPath // empty' <<<"$progress")" || true
    [[ -n "$PICKUP_SAVED_PATH" ]] || fail_with_logs "pickup task ${task_id} completed but reported no savedPath"
    log "Pickup saved inside client container at: ${PICKUP_SAVED_PATH}"
}

step_verify_archive() {
    local archive="$WORKDIR/downloaded-backup.zip" listing entry missing=()
    docker_cmd cp "${CLIENT_CONTAINER}:${PICKUP_SAVED_PATH}" "$archive" >/dev/null \
        || fail_with_logs "could not copy ${PICKUP_SAVED_PATH} out of ${CLIENT_CONTAINER}"
    "${SUDO[@]}" chown "$(id -u):$(id -g)" "$archive" \
        || fail_with_logs "could not take ownership of the copied archive ${archive}"
    listing="$(unzip -l "$archive" 2>"$WORKDIR/unzip-error.txt")" \
        || fail_with_logs "downloaded file at ${PICKUP_SAVED_PATH} could not be read as a zip archive: $(head -n 1 "$WORKDIR/unzip-error.txt")"
    echo "$listing" > "$LAST_RUN_FILE"

    for entry in "${EXPECTED_ARCHIVE_ENTRIES[@]}"; do
        grep -qF -- "$entry" <<<"$listing" || missing+=("$entry")
    done
    (( ${#missing[@]} == 0 )) \
        || fail_with_logs "archive is missing expected entries: ${missing[*]} (see ${LAST_RUN_FILE})"
    ! grep -qE '/qbittorrent-saved-torrents/$' <<<"$listing" \
        || fail_with_logs "single-file path was archived as a directory (see ${LAST_RUN_FILE})"
}

step_verify_restore() {
    local archive="$WORKDIR/downloaded-backup.zip" restore="$WORKDIR/restore" name rel
    mkdir -p "$restore"
    unzip -q "$archive" -d "$restore" || fail_with_logs "could not extract the downloaded archive"
    [[ -L "$restore$FAKE_SERVICES_DIR/sonarr/config/current-config.xml" ]] \
        || fail_with_logs "symbolic link was not restored as a link"
    for name in "${!TEST_SERVICES[@]}"; do
        for rel in ${TEST_SERVICES[$name]}; do
            diff -r --no-dereference "$FAKE_SERVICES_DIR/$rel" "$restore$FAKE_SERVICES_DIR/$rel" >&2 \
                || fail_with_logs "restored ${rel} differs from the original"
        done
    done
}

app_source() {
    if [[ -n "$LOCAL_PATH" && "${APP_DIR[$1]}" != "$WORKDIR/src/$1" ]]; then
        echo "local checkout"
    else
        echo "${APP_BRANCH[$1]}"
    fi
}

detect_stack_mode() {
    local server_headers server_kind client_code client_kind pre_auth_side auth_side
    server_headers="$(curl -s --max-time 5 -D - -o /dev/null "${SERVER_URL}/api/v1/clients")" || server_headers=""
    server_kind="$(classify_server_probe <<<"$server_headers")"
    client_code="$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "${CLIENT_URL}/api/auth/status")" || client_code="000"
    client_kind="$(classify_client_probe "$client_code")"

    [[ "$server_kind" != unknown* ]] \
        || fail_with_logs "cannot tell whether MediaGarrd-Server has authentication: GET /api/v1/clients answered ${server_kind#unknown } (expected 401 with a Bearer challenge, or 404)"
    [[ "$client_kind" != unknown* ]] \
        || fail_with_logs "cannot tell whether MediaGarrd-Client has authentication: GET /api/auth/status answered ${client_kind#unknown } (expected 200 or 404)"

    if [[ "$server_kind" != "$client_kind" ]]; then
        if [[ "$server_kind" == "pre-auth" ]]; then
            pre_auth_side="MediaGarrd-Server ($(app_source Server))"; auth_side="MediaGarrd-Client"
        else
            pre_auth_side="MediaGarrd-Client ($(app_source Client))"; auth_side="MediaGarrd-Server"
        fi
        fail_with_logs "${pre_auth_side} has no authentication but ${auth_side} requires it; test branches that both have authentication, or branches that both predate it"
    fi
    if [[ "$server_kind" == "auth" ]]; then
        (( LEGACY )) && fail_with_logs "--legacy was given but both apps have authentication; run without --legacy"
        AUTH_STACK=1
    elif (( ! LEGACY )); then
        fail_with_logs "neither MediaGarrd-Server nor MediaGarrd-Client has authentication; pass --legacy (or set MG_LEGACY=1) to run the pre-authentication flow"
    fi
    log "Both apps are $([[ "$server_kind" == "auth" ]] && echo "auth-enabled: sign in and pair" || echo "pre-auth: running the legacy flow")"
}

run_workflow() {
    local start steps=()
    if (( AUTH_STACK )); then
        steps+=("step_pair_before_setup:confirming pairing is refused before setup is finished")
    fi
    steps+=(
        "step_server_healthy:confirming server health payload"
        "step_unlock_setup:unlocking server setup with the logged PIN"
        "step_register_services:registering fake services through the server API"
        "step_complete_setup:finishing setup and confirming the setup page is disabled"
    )
    if (( AUTH_STACK )); then
        steps+=(
            "step_server_requires_token:confirming the server API refuses requests without a token"
            "step_client_login:signing in to the client dashboard and checking it refuses anonymous requests"
        )
    fi
    steps+=("step_client_resolves_server:waiting for client to resolve the test server")
    if (( AUTH_STACK )); then
        steps+=(
            "step_pair_wrong_pin:confirming a wrong PIN is refused"
            "step_pair_client:pairing the client with the server using the logged PIN"
            "step_pairing_closed:confirming the used PIN no longer pairs"
            "step_repair_refused:confirming a paired client cannot pair again"
            "step_pair_second_client:pairing a second client with a pairing code"
            "step_unpair_and_repair:unpairing both clients and pairing the client again with the reopened PIN"
            "step_restart_server:restarting the server and confirming pairing state and the client token survive"
            "step_restart_client:restarting the client and confirming its password and pairing survive"
            "step_first_come_password:confirming the first password set on a client without CLIENT_PASSWORD wins and survives a restart"
        )
    fi
    steps+=(
        "step_trigger_backup:triggering a backup run through the client"
        "step_backup_listed:verifying the server lists the new backup"
        "step_pickup_latest:fetching the latest backup via client pickup"
        "step_verify_archive:validating the downloaded archive contents"
        "step_verify_restore:restoring the archive and comparing it with the originals"
    )
    local i=0 step
    start=$(date +%s)
    for step in "${steps[@]}"; do
        i=$((i + 1))
        log "Step ${i}/${#steps[@]}: ${step#*:}..."
        "${step%%:*}"
    done
    log "Workflow completed in $(( $(date +%s) - start ))s"
}


main() {
    parse_args "$@"
    check_dependencies
    detect_docker_access

    WORKDIR="$(mktemp -d)"
    SETUP_COOKIES="$WORKDIR/setup-cookies.txt"
    CLIENT_COOKIES="$WORKDIR/client-cookies.txt"
    COMPOSE_ENV_FILE="$WORKDIR/compose.env"
    MGTEST_CLIENT_PASSWORD="$(random_secret)"
    printf 'MGTEST_CLIENT_PASSWORD=%s\n' "$MGTEST_CLIENT_PASSWORD" > "$COMPOSE_ENV_FILE"
    trap on_exit EXIT
    trap interrupted INT TERM

    stage_sources

    # Clear out anything left behind by a previously interrupted run.
    compose down -v --remove-orphans >/dev/null 2>&1 || true
    remove_helper_containers

    create_fixture_links
    run_unit_tests
    start_stack
    detect_stack_mode
    run_workflow
    pass
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
