#!/usr/bin/env bash

set -Eeuo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_IMAGE="${PISTON_REPO_IMAGE:-piston-repo:local-arm64}"
readonly TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/piston-reproducible-package.XXXXXX")"
readonly FIRST_ROOT="${TEMP_DIR}/first"
readonly SECOND_ROOT="${TEMP_DIR}/second"
readonly PACKAGE_FILE='python-3.12.0.pkg.tar.gz'

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM
    rm -rf "$TEMP_DIR"
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

copy_tracked_sources() {
    local destination="$1"

    mkdir -p "$destination"
    git -C "$ROOT" ls-files -z packages repo |
        tar --create --null --files-from=- --file=- --directory="$ROOT" |
        tar --extract --file=- --directory="$destination"
}

build_package_repository() {
    local build_root="$1"

    docker run --rm \
        --mount "type=bind,source=${build_root},target=/piston" \
        "$REPO_IMAGE" python-3.12.0 --no-server
}

docker_arch="$(docker info --format '{{.Architecture}}')"
if [[ "$docker_arch" != 'arm64' && "$docker_arch" != 'aarch64' ]]; then
    echo 'The reproducibility check requires a native ARM64 Docker host.' >&2
    exit 1
fi
if [[ "${SKIP_IMAGE_BUILD:-0}" != '1' ]]; then
    docker build \
        --platform linux/arm64 \
        --tag "$REPO_IMAGE" \
        "$ROOT/repo"
fi
if [[ "$(docker image inspect "$REPO_IMAGE" --format '{{.Architecture}}')" != 'arm64' ]]; then
    echo "${REPO_IMAGE} is not an ARM64 image." >&2
    exit 1
fi

copy_tracked_sources "$FIRST_ROOT"
copy_tracked_sources "$SECOND_ROOT"
build_package_repository "$FIRST_ROOT"
build_package_repository "$SECOND_ROOT"

cmp \
    "${FIRST_ROOT}/packages/${PACKAGE_FILE}" \
    "${SECOND_ROOT}/packages/${PACKAGE_FILE}"
cmp "${FIRST_ROOT}/repo/index" "${SECOND_ROOT}/repo/index"
cmp \
    "${FIRST_ROOT}/repo/${PACKAGE_FILE}" \
    "${SECOND_ROOT}/repo/${PACKAGE_FILE}"

if [[ "$(wc -l < "${SECOND_ROOT}/repo/index" | tr -d ' ')" != '1' ]]; then
    echo 'The repository index must contain exactly one package record.' >&2
    exit 1
fi

package_checksum="$(sha256sum "${SECOND_ROOT}/packages/${PACKAGE_FILE}" | awk '{print $1}')"
index_checksum="$(sha256sum "${SECOND_ROOT}/repo/index" | awk '{print $1}')"

if [[ -n "${PISTON_REPRODUCIBILITY_OUTPUT_DIR:-}" ]]; then
    mkdir -p "$PISTON_REPRODUCIBILITY_OUTPUT_DIR"
    cp \
        "${SECOND_ROOT}/repo/${PACKAGE_FILE}" \
        "${SECOND_ROOT}/repo/index" \
        "$PISTON_REPRODUCIBILITY_OUTPUT_DIR/"
fi

echo "Reproducible package SHA-256: ${package_checksum}"
echo "Reproducible index SHA-256: ${index_checksum}"
