#!/usr/bin/env bash
# Fully automated, self-contained smoke test for the MediaGarrd server/client
# workflow. Builds the real server + client images from ../MediaGarrd (never
# modifying that repo), runs an end-to-end backup -> list -> pickup cycle
# against fake service data, and prints a single definitive verdict:
#
#   TEST PASSED
# or
#   TEST FAILED BECAUSE OF <reason>
#
# The container build (first run only, or after a source change) is not
# counted against the ~30s budget below — that budget covers the actual
# workflow exercise once both containers are up and healthy. Re-runs with a
# warm Docker build cache are fast end-to-end.
#
# Usage: ./run-test.sh
# Everything this script creates (containers, images, volumes, network) is
# torn down automatically on exit, whether the test passes or fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.test.yml"
SERVER_URL="http://localhost:18080"
CLIENT_URL="http://localhost:18081"
WORKDIR="$(mktemp -d)"

STAGE_TIMEOUT_HEALTH=60      # seconds to wait for containers to come up healthy
STAGE_TIMEOUT_RESOLVE=15     # seconds to wait for client to auto-resolve the server
STAGE_TIMEOUT_PICKUP=20      # seconds to wait for the pickup task to finish

RESULT=""
REASON=""
WORKFLOW_START=""

log() {
    echo "[test] $*" >&2
}

cleanup() {
    local exit_code=$?
    log "Tearing down test environment..."
    sudo docker compose -f "$COMPOSE_FILE" down -v --remove-orphans >/dev/null 2>&1
    rm -rf "$WORKDIR"

    if [[ -n "$RESULT" ]]; then
        exit_code=0
        [[ "$RESULT" == "FAIL" ]] && exit_code=1
        echo
        if [[ "$RESULT" == "PASS" ]]; then
            echo "TEST PASSED"
        else
            echo "TEST FAILED BECAUSE OF ${REASON}"
        fi
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

fail() {
    RESULT="FAIL"
    REASON="$1"
    exit 1
}

pass() {
    RESULT="PASS"
    exit 0
}

# Polls a URL until it returns 2xx or the timeout elapses.
wait_for_http() {
    local url="$1" timeout="$2" label="$3"
    local waited=0
    while (( waited < timeout )); do
        if curl -fsS --max-time 3 -o /dev/null "$url"; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "${label} not reachable at ${url} after ${timeout}s"
}

dump_logs_on_failure() {
    log "----- mediagarrd-server-test logs (tail) -----"
    sudo docker compose -f "$COMPOSE_FILE" logs --no-color --tail=60 mediagarrd-server-test 2>&1 | sed 's/^/[server] /' >&2
    log "----- mediagarrd-client-test logs (tail) -----"
    sudo docker compose -f "$COMPOSE_FILE" logs --no-color --tail=60 mediagarrd-client-test 2>&1 | sed 's/^/[client] /' >&2
}

# Wrap fail() so we always dump recent container logs to help diagnose CI-less failures.
fail_with_logs() {
    dump_logs_on_failure
    fail "$1"
}

log "Building and starting isolated test stack (images tagged :test, network/volumes prefixed mediagarrd-test)..."
if ! sudo docker compose -f "$COMPOSE_FILE" up -d --build; then
    fail_with_logs "docker compose up --build failing (see build output above)"
fi

log "Waiting for containers to report healthy HTTP endpoints (build time excluded from workflow budget)..."
wait_for_http "${SERVER_URL}/api/v1/health" "$STAGE_TIMEOUT_HEALTH" "MediaGarrd-Server"
wait_for_http "${CLIENT_URL}/api/client/status" "$STAGE_TIMEOUT_HEALTH" "MediaGarrd-Client"

# ---- Workflow budget starts here (~30s target) ----
WORKFLOW_START=$(date +%s)

log "Step 1/6: confirming server health payload..."
server_health="$(curl -fsS --max-time 5 "${SERVER_URL}/api/v1/health")" || fail_with_logs "GET /api/v1/health request failed"
server_healthy="$(echo "$server_health" | jq -r '.healthy // false' 2>/dev/null)"
[[ "$server_healthy" == "true" ]] || fail_with_logs "server health payload did not report healthy=true (got: ${server_health})"

log "Step 2/6: waiting for client to auto-resolve the test server via MEDIAGARRD_SERVER_IP..."
active_server=""
waited=0
while (( waited < STAGE_TIMEOUT_RESOLVE )); do
    status_json="$(curl -fsS --max-time 5 "${CLIENT_URL}/api/client/status" 2>/dev/null)" || status_json=""
    active_server="$(echo "$status_json" | jq -r '.activeServer // empty' 2>/dev/null)"
    [[ -n "$active_server" ]] && break
    sleep 1
    waited=$((waited + 1))
done
[[ -n "$active_server" ]] || fail_with_logs "client never resolved an active server (checked /api/client/status for ${STAGE_TIMEOUT_RESOLVE}s)"
log "Client resolved active server: ${active_server}"
[[ "$active_server" == *"mediagarrd-server-test"* ]] || fail_with_logs "client resolved unexpected active server '${active_server}' (expected it to point at mediagarrd-server-test)"

log "Step 3/6: triggering a backup run through the client (POST /api/client/backups/run)..."
run_http_code="$(curl -s --max-time 30 -o "${WORKDIR}/run-response.txt" -w '%{http_code}' -X POST "${CLIENT_URL}/api/client/backups/run")"
[[ "$run_http_code" == "200" ]] || fail_with_logs "POST /api/client/backups/run returned HTTP ${run_http_code} (body: $(cat "${WORKDIR}/run-response.txt" 2>/dev/null))"

log "Step 4/6: verifying the server produced a listable backup archive..."
backups_json="$(curl -fsS --max-time 10 "${CLIENT_URL}/api/client/backups")" || fail_with_logs "GET /api/client/backups request failed"
backup_count="$(echo "$backups_json" | jq 'length' 2>/dev/null)"
[[ "$backup_count" =~ ^[0-9]+$ ]] && (( backup_count >= 1 )) || fail_with_logs "expected at least 1 backup after triggering a run, got: ${backups_json}"
backup_id="$(echo "$backups_json" | jq -r '.[0].id')"
backup_size="$(echo "$backups_json" | jq -r '.[0].sizeBytes')"
log "Latest backup: id=${backup_id}, sizeBytes=${backup_size}"
[[ "$backup_size" =~ ^[0-9]+$ ]] && (( backup_size > 0 )) || fail_with_logs "latest backup archive reported sizeBytes=${backup_size} (expected > 0)"

log "Step 5/6: fetching the latest backup through the client's pickup workflow..."
pickup_start="$(curl -fsS --max-time 10 -X POST "${CLIENT_URL}/api/client/pickup")" || fail_with_logs "POST /api/client/pickup request failed"
task_id="$(echo "$pickup_start" | jq -r '.taskId // empty')"
[[ -n "$task_id" ]] || fail_with_logs "POST /api/client/pickup did not return a taskId (body: ${pickup_start})"

pickup_status=""
saved_path=""
waited=0
while (( waited < STAGE_TIMEOUT_PICKUP )); do
    progress_json="$(curl -fsS --max-time 5 "${CLIENT_URL}/api/client/pickup/progress/${task_id}" 2>/dev/null)" || progress_json=""
    pickup_status="$(echo "$progress_json" | jq -r '.status // empty' 2>/dev/null)"
    if [[ "$pickup_status" == "COMPLETED" ]]; then
        saved_path="$(echo "$progress_json" | jq -r '.savedPath // empty')"
        break
    elif [[ "$pickup_status" == "FAILED" ]]; then
        pickup_error="$(echo "$progress_json" | jq -r '.error // "unknown error"')"
        fail_with_logs "pickup task ${task_id} reported status FAILED: ${pickup_error}"
    fi
    sleep 1
    waited=$((waited + 1))
done
[[ "$pickup_status" == "COMPLETED" ]] || fail_with_logs "pickup task ${task_id} did not reach COMPLETED within ${STAGE_TIMEOUT_PICKUP}s (last status: ${pickup_status:-none})"
[[ -n "$saved_path" ]] || fail_with_logs "pickup task ${task_id} completed but reported no savedPath"
log "Pickup completed, saved inside client container at: ${saved_path}"

log "Step 6/6: validating the downloaded archive contents from inside the client container..."
if ! sudo docker cp "mediagarrd-client-test:${saved_path}" "${WORKDIR}/downloaded-backup.zip" >/dev/null 2>&1; then
    fail_with_logs "failed to docker cp the downloaded archive out of mediagarrd-client-test (path: ${saved_path})"
fi

zip_listing="$(unzip -l "${WORKDIR}/downloaded-backup.zip" 2>/dev/null)" || fail_with_logs "downloaded file at ${saved_path} is not a valid zip archive"

missing_entries=()
for expected in "jellyfin/config/" "radarr/appdata/" "sonarr/appdata/" "prowlarr/appdata/" "tdarr/appdata/" "qbittorrent/appdata/" "qbittorrent/graveyard/" "qbittorrent/docker-compose.yml"; do
    if ! grep -q -- "$expected" <<<"$zip_listing"; then
        missing_entries+=("$expected")
    fi
done

if (( ${#missing_entries[@]} > 0 )); then
    fail_with_logs "downloaded archive is missing expected entries: ${missing_entries[*]} (full listing: $(echo "$zip_listing" | tr '\n' ' '))"
fi

WORKFLOW_END=$(date +%s)
log "Workflow (run -> list -> pickup -> verify) completed in $((WORKFLOW_END - WORKFLOW_START))s"

pass
