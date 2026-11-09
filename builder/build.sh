#!/usr/bin/env bash

set -Eeuo pipefail

# Build a container using the spec file provided.

readonly START_DIR="$PWD"
readonly BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILD_DIR="${BUILDER_DIR}/build"
readonly PISTON_IMAGE="${PISTON_IMAGE:-piston-api:local-arm64}"
readonly CONTAINER_NAME="builder_piston_instance_$$"

cd "$BUILDER_DIR"

help_msg() {
    echo "Usage: $0 [specfile] [tag]"
    echo
    echo "$1"
    exit 1
}

cleanup() {
    docker rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

fetch_packages() {
    local spec_file="$1"
    local published_port
    local -a docker_args=(
        --privileged
        --cgroupns private
        --mount "type=bind,source=${BUILD_DIR},target=/piston/packages"
        --detach
        --publish 127.0.0.1::2000
        --name "$CONTAINER_NAME"
    )

    if [[ -n "${PISTON_REPO_URL:-}" ]]; then
        docker_args+=(--env "PISTON_REPO_URL=${PISTON_REPO_URL}")
    fi
    if [[ -n "${PISTON_DOCKER_NETWORK:-}" ]]; then
        docker_args+=(--network "$PISTON_DOCKER_NETWORK")
    fi

    mkdir -p "$BUILD_DIR"
    docker run "${docker_args[@]}" "$PISTON_IMAGE" >/dev/null

    published_port="$(docker port "$CONTAINER_NAME" 2000/tcp)"
    published_port="${published_port##*:}"

    for _ in $(seq 1 60); do
        if curl --fail --silent --show-error \
            "http://127.0.0.1:${published_port}/api/v2/runtimes" \
            >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    curl --fail --silent --show-error \
        "http://127.0.0.1:${published_port}/api/v2/runtimes" \
        >/dev/null

    npm --prefix ../cli ci --ignore-scripts
    ../cli/index.js \
        --piston-url "http://127.0.0.1:${published_port}" \
        ppman spec "$spec_file"
}

build_container() {
    local tag="$1"
    docker build \
        --build-arg "PISTON_IMAGE=${PISTON_IMAGE}" \
        --tag "$tag" \
        --file Dockerfile \
        "$BUILD_DIR"
}

if [[ $# -ne 2 ]]; then
    help_msg 'specfile and tag are required'
fi

if [[ "$1" = /* ]]; then
    readonly SPEC_FILE="$1"
else
    readonly SPEC_FILE="$START_DIR/$1"
fi
readonly TAG="$2"

[[ -f "$SPEC_FILE" ]] || help_msg "specfile does not exist: $SPEC_FILE"
command -v node >/dev/null || help_msg 'nodejs is required'
command -v npm >/dev/null || help_msg 'npm is required'
command -v curl >/dev/null || help_msg 'curl is required'

trap cleanup EXIT

fetch_packages "$SPEC_FILE"
build_container "$TAG"

echo 'Start your custom Piston container with:'
echo "docker run --privileged --cgroupns private -dit -p 127.0.0.1:2000:2000 $TAG"
