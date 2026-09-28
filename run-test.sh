#!/usr/bin/env bash
#
# End-to-end integration test for the MediaGarrd Server + Client.
#
# Builds both apps (from GitHub branches or a local checkout), starts them in
# an isolated Docker Compose stack backed by ./fake-services, drives a full
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

# Paths that must appear in the downloaded backup archive.
readonly EXPECTED_ARCHIVE_ENTRIES=(
    "jellyfin/config/"
    "radarr/"
    "sonarr/"
    "prowlarr/"
    "tdarr/"
    "qbittorrent/config/"
    "qbittorrent/saved-torrents/"
    "qbittorrent/docker-compose.yml"
)


declare -A APP_BRANCH=([Server]="" [Client]="")
declare -A APP_DIR=()
LOCAL_PATH=""
WORKDIR=""
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
    [[ -n "$WORKDIR" ]] && rm -rf "$WORKDIR"

    case "$RESULT" in
        PASS) echo; echo "TEST PASSED"; exit 0 ;;
        FAIL) echo; echo "TEST FAILED BECAUSE OF ${REASON}"; exit 1 ;;
        *)    exit "$exit_code" ;;
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
        grep -q -- "$entry" <<<"$listing" || missing+=("$entry")
    done
    (( ${#missing[@]} == 0 )) \
        || fail_with_logs "archive is missing expected entries: ${missing[*]} (see ${LAST_RUN_FILE})"
}

run_workflow() {
    local start steps=(
        "step_server_healthy:confirming server health payload"
        "step_client_resolves_server:waiting for client to resolve the test server"
        "step_trigger_backup:triggering a backup run through the client"
        "step_backup_listed:verifying the server lists the new backup"
        "step_pickup_latest:fetching the latest backup via client pickup"
        "step_verify_archive:validating the downloaded archive contents"
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
    trap on_exit EXIT INT TERM

    stage_sources

    # Clear out anything left behind by a previously interrupted run.
    compose down -v --remove-orphans >/dev/null 2>&1 || true

    run_unit_tests
    start_stack
    run_workflow
    pass
}

main "$@"
