#!/usr/bin/env bash

set -Eeuo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly API_IMAGE="${PISTON_API_IMAGE:-piston-api:local-arm64}"
readonly REPO_IMAGE="${PISTON_REPO_IMAGE:-piston-repo:local-arm64}"
readonly RUN_ID="$$-$(date +%s)"
readonly NETWORK="piston-arm64-acceptance-${RUN_ID}"
readonly API_CONTAINER="piston-arm64-acceptance-api-${RUN_ID}"
readonly REPO_CONTAINER="piston-arm64-acceptance-repo-${RUN_ID}"
readonly BUILDER_CONTAINER="piston-arm64-acceptance-builder-${RUN_ID}"
readonly TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/piston-arm64-acceptance.XXXXXX")"
readonly DATA_DIR="${TEMP_DIR}/data"
readonly BUILD_ROOT="${TEMP_DIR}/build"
readonly MAX_CONCURRENT_JOBS="${PISTON_MAX_CONCURRENT_JOBS:-3}"
readonly SANDBOX_SLOT_SIZE_MB="${PISTON_SANDBOX_SLOT_SIZE_MB:-32}"
readonly SANDBOX_SLOT_INODES="${PISTON_SANDBOX_SLOT_INODES:-256}"
readonly SANDBOX_SCRATCH_SIZE_MB="${PISTON_SANDBOX_SCRATCH_SIZE_MB:-256}"

NETWORK_CREATED=0
BASE_URL=''

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM

    if [[ "${KEEP_ACCEPTANCE_RESOURCES:-0}" == '1' ]]; then
        echo "Keeping acceptance resources: ${TEMP_DIR}, ${NETWORK}, ${API_CONTAINER}, ${REPO_CONTAINER}"
    else
        docker rm --force \
            "$API_CONTAINER" \
            "$REPO_CONTAINER" \
            "$BUILDER_CONTAINER" >/dev/null 2>&1 || true
        if [[ "$NETWORK_CREATED" == '1' ]]; then
            docker network rm "$NETWORK" >/dev/null 2>&1 || true
        fi
        rm -rf "$TEMP_DIR"
    fi

    exit "$exit_code"
}

trap cleanup EXIT INT TERM

wait_for_api() {
    local attempt
    for attempt in $(seq 1 60); do
        if curl --fail --silent --show-error \
            "${BASE_URL}/api/v2/runtimes" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    docker logs "$API_CONTAINER" >&2 || true
    return 1
}

assert_storage_layout() {
    docker exec \
        --env "EXPECTED_SLOTS=${MAX_CONCURRENT_JOBS}" \
        --env "EXPECTED_SLOT_BYTES=$((SANDBOX_SLOT_SIZE_MB * 1024 * 1024))" \
        --env "EXPECTED_SLOT_INODES=${SANDBOX_SLOT_INODES}" \
        --env "EXPECTED_SCRATCH_BYTES=$((SANDBOX_SCRATCH_SIZE_MB * 1024 * 1024))" \
        "$API_CONTAINER" sh -eu -c '
            ps -eo user=,args= | awk '\''$1 == "piston" && $0 ~ /node \/piston_api\/src\/index.js$/ { found = 1 } END { exit !found }'\''
            test "$(find /var/lib/piston-sandbox/pool -maxdepth 1 -type f -name "slot-*.ext4" | wc -l)" -eq "$EXPECTED_SLOTS"
            findmnt /var/lib/piston-sandbox/pool >/dev/null
            scratch_blocks="$(tune2fs -l /var/lib/piston-sandbox/scratch.ext4 2>/dev/null | awk -F: '\''$1 == "Block count" { gsub(/ /, "", $2); print $2 }'\'')"
            scratch_block_size="$(tune2fs -l /var/lib/piston-sandbox/scratch.ext4 2>/dev/null | awk -F: '\''$1 == "Block size" { gsub(/ /, "", $2); print $2 }'\'')"
            test "$((scratch_blocks * scratch_block_size))" -eq "$EXPECTED_SCRATCH_BYTES"
            for image in /var/lib/piston-sandbox/pool/slot-*.ext4; do
                block_count="$(tune2fs -l "$image" 2>/dev/null | awk -F: '\''$1 == "Block count" { gsub(/ /, "", $2); print $2 }'\'')"
                block_size="$(tune2fs -l "$image" 2>/dev/null | awk -F: '\''$1 == "Block size" { gsub(/ /, "", $2); print $2 }'\'')"
                inode_count="$(tune2fs -l "$image" 2>/dev/null | awk -F: '\''$1 == "Inode count" { gsub(/ /, "", $2); print $2 }'\'')"
                test "$((block_count * block_size))" -eq "$EXPECTED_SLOT_BYTES"
                test "$inode_count" -eq "$EXPECTED_SLOT_INODES"
            done
        '
}

assert_no_active_slot_mounts() {
    if docker exec "$API_CONTAINER" sh -c \
        "findmnt -rn -o TARGET | grep -q '^/var/local/lib/isolate/.*/box$'"; then
        echo 'A sandbox slot mount remained after job cleanup.' >&2
        return 1
    fi
}

assert_delayed_loop_release_is_safe() {
    local first_response="${TEMP_DIR}/delayed-loop-first.json"
    local second_response="${TEMP_DIR}/delayed-loop-second.json"
    local third_response="${TEMP_DIR}/delayed-loop-third.json"
    local curl_pid
    local holder_pid
    local loop_device=''
    local loop_identity=''
    local current_identity=''
    local second_started
    local second_elapsed

    curl --silent --show-error \
        --header 'Content-Type: application/json' \
        --data '{"language":"python","version":"3.12.0","run_timeout":3000,"files":[{"name":"main.py","content":"import time\ntime.sleep(1)\nprint(\"first\")"}]}' \
        "${BASE_URL}/api/v2/execute" >"$first_response" &
    curl_pid=$!

    for _ in $(seq 1 100); do
        loop_device="$(docker exec "$API_CONTAINER" sh -c \
            "findmnt -rn -o SOURCE,TARGET | awk '\$2 ~ \"^/var/local/lib/isolate/[0-9]+/box\$\" { print \$1; exit }'" 2>/dev/null || true)"
        if [[ -n "$loop_device" ]]; then
            break
        fi
        sleep 0.02
    done
    if [[ ! "$loop_device" =~ ^/dev/loop[0-9]+$ ]]; then
        wait "$curl_pid" || true
        echo 'The delayed-loop fixture did not observe a sandbox loop device.' >&2
        return 1
    fi
    loop_identity="$(docker exec "$API_CONTAINER" losetup \
        --list \
        --noheadings \
        --raw \
        --output BACK-INO,BACK-MAJ:MIN \
        "$loop_device" | xargs)"
    if [[ ! "$loop_identity" =~ ^[0-9]+\ [0-9]+:[0-9]+$ ]]; then
        wait "$curl_pid" || true
        echo "The delayed-loop fixture received invalid identity ${loop_identity}." >&2
        return 1
    fi

    docker exec "$API_CONTAINER" sh -c \
        "exec 3<'$loop_device'; touch /tmp/piston-loop-holder-ready; sleep 4" &
    holder_pid=$!
    for _ in $(seq 1 100); do
        if docker exec "$API_CONTAINER" \
            test -f /tmp/piston-loop-holder-ready >/dev/null 2>&1; then
            break
        fi
        sleep 0.01
    done
    if ! docker exec "$API_CONTAINER" \
        test -f /tmp/piston-loop-holder-ready >/dev/null 2>&1; then
        wait "$curl_pid" || true
        wait "$holder_pid" || true
        echo 'The delayed-loop fixture could not hold the loop device open.' >&2
        return 1
    fi

    wait "$curl_pid"
    grep -q '"stdout":"first\\n"' "$first_response"

    second_started="$(node -e 'console.log(Date.now())')"
    curl --fail --silent --show-error \
        --header 'Content-Type: application/json' \
        --data '{"language":"python","version":"3.12.0","files":[{"name":"main.py","content":"print(\"second\")"}]}' \
        "${BASE_URL}/api/v2/execute" >"$second_response"
    second_elapsed="$(( $(node -e 'console.log(Date.now())') - second_started ))"
    grep -q '"stdout":"second\\n"' "$second_response"
    if [[ "$second_elapsed" -ge 1500 ]] || ! kill -0 "$holder_pid" 2>/dev/null; then
        wait "$holder_pid" || true
        echo 'A delayed loop release blocked an independent sandbox slot.' >&2
        return 1
    fi

    wait "$holder_pid"
    for _ in $(seq 1 100); do
        current_identity="$(docker exec "$API_CONTAINER" losetup \
            --list \
            --noheadings \
            --raw \
            --output BACK-INO,BACK-MAJ:MIN \
            "$loop_device" 2>/dev/null | xargs || true)"
        if [[ "$current_identity" != "$loop_identity" ]]; then
            break
        fi
        sleep 0.02
    done
    current_identity="$(docker exec "$API_CONTAINER" losetup \
        --list \
        --noheadings \
        --raw \
        --output BACK-INO,BACK-MAJ:MIN \
        "$loop_device" 2>/dev/null | xargs || true)"
    if [[ "$current_identity" == "$loop_identity" ]]; then
        echo "Sandbox loop device ${loop_device} remained attached." >&2
        return 1
    fi

    curl --fail --silent --show-error \
        --header 'Content-Type: application/json' \
        --data '{"language":"python","version":"3.12.0","files":[{"name":"main.py","content":"print(\"third\")"}]}' \
        "${BASE_URL}/api/v2/execute" >"$third_response"
    grep -q '"stdout":"third\\n"' "$third_response"
    curl --fail --silent --show-error "${BASE_URL}/api/v2/runtimes" >/dev/null
}

assert_removed_slot_is_rebuilt() {
    local response_file="${TEMP_DIR}/rebuilt-slot-response.json"
    local curl_pid
    local mounted=0

    curl --silent --show-error \
        --header 'Content-Type: application/json' \
        --data '{"language":"python","version":"3.12.0","run_timeout":3000,"files":[{"name":"main.py","content":"import time\ntime.sleep(1)\nprint(\"done\")"}]}' \
        "${BASE_URL}/api/v2/execute" >"$response_file" &
    curl_pid=$!

    for _ in $(seq 1 100); do
        if docker exec "$API_CONTAINER" sh -c \
            "findmnt -rn -o TARGET | grep -q '^/var/local/lib/isolate/.*/box$'"; then
            mounted=1
            break
        fi
        sleep 0.02
    done
    if [[ "$mounted" != '1' ]]; then
        wait "$curl_pid" || true
        echo 'The slot-rebuild fixture did not observe slot 1 mounted.' >&2
        return 1
    fi

    docker exec "$API_CONTAINER" \
        rm /var/lib/piston-sandbox/pool/slot-1.ext4
    wait "$curl_pid"
    docker exec "$API_CONTAINER" \
        test -f /var/lib/piston-sandbox/pool/slot-1.ext4
    curl --fail --silent --show-error "${BASE_URL}/api/v2/runtimes" >/dev/null
}

assert_failed_reset_stops_api() {
    local response_file="${TEMP_DIR}/failed-reset-response.json"
    local curl_pid
    local mounted=0
    local stopped=0

    curl --silent --show-error \
        --header 'Content-Type: application/json' \
        --data '{"language":"python","version":"3.12.0","run_timeout":3000,"files":[{"name":"main.py","content":"import time\ntime.sleep(1)\nprint(\"done\")"}]}' \
        "${BASE_URL}/api/v2/execute" >"$response_file" &
    curl_pid=$!

    for _ in $(seq 1 100); do
        if docker exec "$API_CONTAINER" sh -c \
            "findmnt -rn -o TARGET | grep -q '^/var/local/lib/isolate/.*/box$'"; then
            mounted=1
            break
        fi
        sleep 0.02
    done
    if [[ "$mounted" != '1' ]]; then
        wait "$curl_pid" || true
        echo 'The reset-failure fixture did not observe slot 1 mounted.' >&2
        return 1
    fi

    docker exec "$API_CONTAINER" sh -c \
        'rm /var/lib/piston-sandbox/pool/slot-1.ext4 && mkdir /var/lib/piston-sandbox/pool/slot-1.ext4'
    wait "$curl_pid" || true

    for _ in $(seq 1 100); do
        if [[ "$(docker inspect "$API_CONTAINER" --format '{{.State.Running}}')" == 'false' ]]; then
            stopped=1
            break
        fi
        sleep 0.05
    done
    if [[ "$stopped" != '1' ]]; then
        echo 'Piston continued running after a sandbox reset failure.' >&2
        return 1
    fi
    if [[ "$(docker inspect "$API_CONTAINER" --format '{{.State.ExitCode}}')" == '0' ]]; then
        echo 'Piston exited successfully after a sandbox reset failure.' >&2
        return 1
    fi
    docker logs "$API_CONTAINER" 2>&1 | grep -q 'Sandbox slot 1 is quarantined'
}

assert_invalid_storage_config() {
    local size_mb="$1"
    local inodes="$2"
    local scratch_size_mb="$3"
    if docker run --rm \
        --entrypoint node \
        --env "PISTON_MAX_CONCURRENT_JOBS=${MAX_CONCURRENT_JOBS}" \
        --env "PISTON_SANDBOX_SLOT_SIZE_MB=${size_mb}" \
        --env "PISTON_SANDBOX_SLOT_INODES=${inodes}" \
        --env "PISTON_SANDBOX_SCRATCH_SIZE_MB=${scratch_size_mb}" \
        --mount "type=bind,source=${DATA_DIR},target=/piston" \
        "$API_IMAGE" \
        -e "require('/piston_api/src/config')" >/dev/null 2>&1; then
        echo "Piston accepted invalid sandbox storage configuration ${size_mb},${inodes},${scratch_size_mb}." >&2
        return 1
    fi
}

set_base_url() {
    local published_port
    published_port="$(docker port "$API_CONTAINER" 2000/tcp)"
    published_port="${published_port##*:}"
    BASE_URL="http://127.0.0.1:${published_port}"
}

start_api() {
    docker run --detach \
        --name "$API_CONTAINER" \
        --network "$NETWORK" \
        --privileged \
        --cgroupns private \
        --publish 127.0.0.1::2000 \
        --env PISTON_REPO_URL=http://repo:8000/index \
        --env PISTON_DISABLE_NETWORKING=true \
        --env "PISTON_MAX_CONCURRENT_JOBS=${MAX_CONCURRENT_JOBS}" \
        --env "PISTON_SANDBOX_SLOT_SIZE_MB=${SANDBOX_SLOT_SIZE_MB}" \
        --env "PISTON_SANDBOX_SLOT_INODES=${SANDBOX_SLOT_INODES}" \
        --env "PISTON_SANDBOX_SCRATCH_SIZE_MB=${SANDBOX_SCRATCH_SIZE_MB}" \
        --mount "type=bind,source=${DATA_DIR},target=/piston" \
        "$API_IMAGE" >/dev/null
    set_base_url
    wait_for_api
    assert_storage_layout
}

docker_arch="$(docker info --format '{{.Architecture}}')"
if [[ "$docker_arch" != 'arm64' && "$docker_arch" != 'aarch64' ]]; then
    echo 'The acceptance suite requires a native ARM64 Docker host.' >&2
    exit 1
fi

if [[ "${SKIP_IMAGE_BUILD:-0}" != '1' ]]; then
    docker build \
        --platform linux/arm64 \
        --build-arg "VCS_REF=$(git -C "$ROOT" rev-parse HEAD)-local" \
        --tag "$API_IMAGE" \
        "$ROOT/api"
    docker build \
        --platform linux/arm64 \
        --tag "$REPO_IMAGE" \
        "$ROOT/repo"
fi

if [[ "$(docker image inspect "$API_IMAGE" --format '{{.Architecture}}')" != 'arm64' ]]; then
    echo "${API_IMAGE} is not an ARM64 image." >&2
    exit 1
fi

mkdir -p "$DATA_DIR"
assert_invalid_storage_config 32 0 256
assert_invalid_storage_config 1.5 256 256
assert_invalid_storage_config -1 256 256
assert_invalid_storage_config 9007199254740991 256 9007199254740991
assert_invalid_storage_config 32 256 96

if [[ -n "${PISTON_PACKAGE_REPO_DIR:-}" ]]; then
    readonly PACKAGE_REPO_DIR="$(cd "$PISTON_PACKAGE_REPO_DIR" && pwd)"
else
    mkdir -p "$BUILD_ROOT"
    cp -R "$ROOT/packages" "$BUILD_ROOT/packages"
    cp -R "$ROOT/repo" "$BUILD_ROOT/repo"
    docker run --name "$BUILDER_CONTAINER" \
        --mount "type=bind,source=${BUILD_ROOT},target=/piston" \
        "$REPO_IMAGE" python-3.12.0 --no-server
    readonly PACKAGE_REPO_DIR="$BUILD_ROOT/repo"
fi

docker network create "$NETWORK" >/dev/null
NETWORK_CREATED=1

docker run --detach \
    --name "$REPO_CONTAINER" \
    --network "$NETWORK" \
    --network-alias repo \
    --entrypoint python3 \
    --workdir /repo \
    --mount "type=bind,source=${PACKAGE_REPO_DIR},target=/repo,readonly" \
    "$API_IMAGE" -m http.server 8000 >/dev/null

start_api

curl --fail --silent --show-error \
    --header 'Content-Type: application/json' \
    --data '{"language":"python","version":"3.12.0"}' \
    "${BASE_URL}/api/v2/packages" >/dev/null

node "$ROOT/tests/acceptance-arm64.mjs" "$BASE_URL" full
assert_no_active_slot_mounts
assert_delayed_loop_release_is_safe
assert_no_active_slot_mounts

docker stop "$API_CONTAINER" >/dev/null
docker start "$API_CONTAINER" >/dev/null
set_base_url
wait_for_api
node "$ROOT/tests/acceptance-arm64.mjs" "$BASE_URL" persistence

docker rm --force "$API_CONTAINER" >/dev/null
start_api
node "$ROOT/tests/acceptance-arm64.mjs" "$BASE_URL" persistence

assert_removed_slot_is_rebuilt
node "$ROOT/tests/acceptance-arm64.mjs" "$BASE_URL" persistence
assert_failed_reset_stops_api
docker rm --force "$API_CONTAINER" >/dev/null
start_api
node "$ROOT/tests/acceptance-arm64.mjs" "$BASE_URL" persistence

curl --fail --silent --show-error \
    --request DELETE \
    --header 'Content-Type: application/json' \
    --data '{"language":"python","version":"3.12.0"}' \
    "${BASE_URL}/api/v2/packages" >/dev/null
node "$ROOT/tests/acceptance-arm64.mjs" "$BASE_URL" deleted

echo 'Native ARM64 Piston acceptance passed.'
