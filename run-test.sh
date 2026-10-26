#!/usr/bin/env bash
#
# End-to-end integration test for the MediaGarrd Server + Client.
#
# Builds both apps (from GitHub branches or a local checkout), starts them in
# an isolated Docker Compose stack, unlocks server setup with the PIN from
# the server logs, registers ./fake-services as services through the server
# API, finishes setup, drives a full
# backup -> list -> pickup -> verify cycle through the client API, and prints
# exactly one verdict:
#
#   TEST PASSED
#   TEST FAILED BECAUSE OF <reason>
#
# Everything the run creates (containers, volumes, network, clones) is torn
# down on exit.

set -euo pipefail

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

readonly TIMEOUT_HEALTH=60  # seconds for each container to answer HTTP
readonly TIMEOUT_RESOLVE=15 # seconds for the client to resolve the server
readonly TIMEOUT_PICKUP=20  # seconds for the pickup task to complete

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
SUDO=()
RESULT=""
REASON=""


log() { echo "[test] $*" >&2; }

usage() {
    cat >&2 <<USAGE
Usage: $0 [--server-branch <name>] [--client-branch <name>]
       $0 --local <dir-containing-Server-and-Client>

Branches default to main. --local cannot be combined with the branch flags.
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

on_exit() {
    local exit_code=$?
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
    "${SUDO[@]}" env \
        MEDIAGARRD_SERVER_DIR="${APP_DIR[Server]:-}" \
        MEDIAGARRD_CLIENT_DIR="${APP_DIR[Client]:-}" \
        docker compose -f "$COMPOSE_FILE" "$@"
}

remove_helper_containers() {
    local ids
    ids="$(docker_cmd ps -aq --filter "name=mediagarrd-backup-${TEST_SERVICE_PREFIX}" 2>/dev/null)" || return 0
    [[ -n "$ids" ]] && docker_cmd rm -f $ids >/dev/null 2>&1 || true
}

dump_container_logs() {
    local container
    for container in "$SERVER_CONTAINER" "$CLIENT_CONTAINER"; do
        log "----- ${container} logs (tail) -----"
        compose logs --no-color --tail=60 "$container" 2>&1 | sed "s/^/[${container}] /" >&2 || true
    done
}

http_get()  { curl -fsS --max-time "${2:-5}" "$1"; }
http_post() { curl -fsS --max-time "${2:-5}" -X POST "$1"; }

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
            -h|--help)       usage 0 ;;
            *)               echo "Unknown argument: $1" >&2; usage ;;
        esac
    done

    if [[ -n "$LOCAL_PATH" && ( -n "${APP_BRANCH[Server]}" || -n "${APP_BRANCH[Client]}" ) ]]; then
        die "--local cannot be combined with --server-branch/--client-branch"
    fi
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
    git clone --quiet --depth 1 --branch "$branch" "$GITHUB_ORG_URL/$app" "${APP_DIR[$app]}" \
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
        make -C "${APP_DIR[$app]}" test >&2 || fail "${app} unit tests failed (make test)"
    done
}

start_stack() {
    log "Building and starting isolated test stack..."
    compose up -d --build || fail_with_logs "docker compose up --build failed (see build output above)"

    log "Waiting for containers to answer HTTP..."
    server_up() { curl -fsS --max-time 3 -o /dev/null "${SERVER_URL}/api/v1/health"; }
    client_up() { curl -fsS --max-time 3 -o /dev/null "${CLIENT_URL}/api/client/status"; }
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

expect_status() {
    local expected="$1" what="$2" code
    shift 2
    code="$(curl -s --max-time 10 -o "$WORKDIR/response.txt" -w '%{http_code}' "$@")"
    [[ "$code" == "$expected" ]] \
        || fail_with_logs "${what} returned HTTP ${code}, expected ${expected} (body: $(cat "$WORKDIR/response.txt" 2>/dev/null))"
}

post_json() {
    local expected="$1" what="$2" body="$3" url="$4"
    expect_status "$expected" "$what" -b "$SETUP_COOKIES" -c "$SETUP_COOKIES" \
        -X POST -H 'Content-Type: application/json' -d "$body" "$url"
}

step_unlock_setup() {
    local pin
    expect_status 401 "config API before setup was unlocked" "${SERVER_URL}/api/v1/services"
    pin="$(docker_cmd logs "$SERVER_CONTAINER" 2>&1 | grep -oE 'Setup PIN: [0-9]{6}' | tail -1 | awk '{print $3}')"
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
    count="$(curl -fsS --max-time 5 -b "$SETUP_COOKIES" "${SERVER_URL}/api/v1/services" | jq 'length')"
    [[ "$count" == "${#TEST_SERVICES[@]}" ]] \
        || fail_with_logs "expected ${#TEST_SERVICES[@]} registered services, server lists ${count}"
}

step_complete_setup() {
    post_json 204 "POST /api/v1/setup/complete" "{}" "${SERVER_URL}/api/v1/setup/complete"
    expect_status 404 "/config after setup completed" "${SERVER_URL}/config"
    expect_status 200 "config API after setup completed" "${SERVER_URL}/api/v1/services"
}

step_client_resolves_server() {
    local active_server=""
    resolved() {
        active_server="$(http_get "${CLIENT_URL}/api/client/status" 2>/dev/null | jq -r '.activeServer // empty' 2>/dev/null)"
        [[ -n "$active_server" ]]
    }
    retry_for "$TIMEOUT_RESOLVE" resolved \
        || fail_with_logs "client never resolved an active server within ${TIMEOUT_RESOLVE}s"
    log "Client resolved active server: ${active_server}"
    [[ "$active_server" == *"$SERVER_CONTAINER"* ]] \
        || fail_with_logs "client resolved unexpected server '${active_server}' (expected ${SERVER_CONTAINER})"
}

step_trigger_backup() {
    local body_file="$WORKDIR/run-response.txt" code
    code="$(curl -s --max-time 30 -o "$body_file" -w '%{http_code}' -X POST "${CLIENT_URL}/api/client/backups/run")"
    [[ "$code" == "200" ]] \
        || fail_with_logs "POST /api/client/backups/run returned HTTP ${code} (body: $(cat "$body_file" 2>/dev/null))"
}

step_backup_listed() {
    local body count id size
    body="$(http_get "${CLIENT_URL}/api/client/backups" 10)" || fail_with_logs "GET /api/client/backups request failed"
    count="$(jq 'length' <<<"$body" 2>/dev/null || echo 0)"
    (( count >= 1 )) || fail_with_logs "expected at least 1 backup after triggering a run, got: ${body}"

    id="$(jq -r '.[0].id' <<<"$body")"
    size="$(jq -r '.[0].sizeBytes' <<<"$body")"
    log "Latest backup: id=${id}, sizeBytes=${size}"
    if ! [[ "$size" =~ ^[0-9]+$ ]] || (( size == 0 )); then
        fail_with_logs "latest backup reported sizeBytes=${size} (expected > 0)"
    fi
}

step_pickup_latest() {
    local body task_id status="" progress=""
    body="$(http_post "${CLIENT_URL}/api/client/pickup" 10)" || fail_with_logs "POST /api/client/pickup request failed"
    task_id="$(jq -r '.taskId // empty' <<<"$body")"
    [[ -n "$task_id" ]] || fail_with_logs "POST /api/client/pickup did not return a taskId (body: ${body})"

    finished() {
        progress="$(http_get "${CLIENT_URL}/api/client/pickup/progress/${task_id}" 2>/dev/null)" || return 1
        status="$(jq -r '.status // empty' <<<"$progress")"
        [[ "$status" == "COMPLETED" || "$status" == "FAILED" ]]
    }
    retry_for "$TIMEOUT_PICKUP" finished \
        || fail_with_logs "pickup task ${task_id} did not finish within ${TIMEOUT_PICKUP}s (last status: ${status:-none})"
    [[ "$status" == "COMPLETED" ]] \
        || fail_with_logs "pickup task ${task_id} FAILED: $(jq -r '.error // "unknown error"' <<<"$progress")"

    PICKUP_SAVED_PATH="$(jq -r '.savedPath // empty' <<<"$progress")"
    [[ -n "$PICKUP_SAVED_PATH" ]] || fail_with_logs "pickup task ${task_id} completed but reported no savedPath"
    log "Pickup saved inside client container at: ${PICKUP_SAVED_PATH}"
}

step_verify_archive() {
    local archive="$WORKDIR/downloaded-backup.zip" listing entry missing=()
    docker_cmd cp "${CLIENT_CONTAINER}:${PICKUP_SAVED_PATH}" "$archive" >/dev/null \
        || fail_with_logs "could not copy ${PICKUP_SAVED_PATH} out of ${CLIENT_CONTAINER}"
    listing="$(unzip -l "$archive" 2>/dev/null)" \
        || fail_with_logs "downloaded file at ${PICKUP_SAVED_PATH} is not a valid zip archive"
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

run_workflow() {
    local start steps=(
        "step_server_healthy:confirming server health payload"
        "step_unlock_setup:unlocking server setup with the logged PIN"
        "step_register_services:registering fake services through the server API"
        "step_complete_setup:finishing setup and confirming the setup page is disabled"
        "step_client_resolves_server:waiting for client to resolve the test server"
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
    trap on_exit EXIT INT TERM

    stage_sources

    # Clear out anything left behind by a previously interrupted run.
    compose down -v --remove-orphans >/dev/null 2>&1 || true
    remove_helper_containers

    create_fixture_links
    run_unit_tests
    start_stack
    run_workflow
    pass
}

main "$@"
