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
        --mount "type=bind,source=${DATA_DIR},target=/piston" \
        "$API_IMAGE" >/dev/null
    set_base_url
    wait_for_api
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

docker stop "$API_CONTAINER" >/dev/null
docker start "$API_CONTAINER" >/dev/null
set_base_url
wait_for_api
node "$ROOT/tests/acceptance-arm64.mjs" "$BASE_URL" persistence

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
