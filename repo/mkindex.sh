#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C

readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PACKAGES_DIR="${PISTON_PACKAGES_DIR:-${REPO_DIR}/../packages}"
readonly BASEURL="${PISTON_REPO_BASE_URL:-http://repo:8000/}"
readonly STAGING_DIR="$(mktemp -d "${REPO_DIR}/.mkindex.XXXXXX")"
readonly ARCHIVES_FILE="${STAGING_DIR}/archives"
readonly PACKAGE_LIST_FILE="${STAGING_DIR}/package-list"
readonly RECORDS_FILE="${STAGING_DIR}/records"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if [[ ! -d "$PACKAGES_DIR" ]]; then
    echo "Package directory does not exist: ${PACKAGES_DIR}" >&2
    exit 1
fi
if [[ "$BASEURL" != */ || "$BASEURL" == *','* || "$BASEURL" == *$'\r'* || "$BASEURL" == *$'\n'* ]]; then
    echo 'PISTON_REPO_BASE_URL must end with a slash and contain no comma or newline.' >&2
    exit 1
fi

declare -A package_identities=()
find "$PACKAGES_DIR" -type f -name '*.pkg.tar.gz' -print0 | sort -z > "$ARCHIVES_FILE"
mapfile -d '' package_archives < "$ARCHIVES_FILE"
: > "$RECORDS_FILE"

for package_archive in "${package_archives[@]}"; do
    package_file="$(basename "$package_archive")"
    if ! tar --list --gzip --file="$package_archive" > "$PACKAGE_LIST_FILE"; then
        echo "Package is not a valid gzip-compressed tar archive: ${package_archive}" >&2
        exit 1
    fi
    package_info_count="$(grep --count --fixed-strings --line-regexp './pkg-info.json' "$PACKAGE_LIST_FILE" || true)"
    if [[ "$package_info_count" != '1' ]]; then
        echo "Package must contain exactly one ./pkg-info.json: ${package_archive}" >&2
        exit 1
    fi

    package_info="$(tar --extract --gzip --to-stdout --file="$package_archive" ./pkg-info.json)"
    package_name="$(jq --exit-status --raw-output '.language | strings | select(length > 0)' <<< "$package_info")"
    package_version="$(jq --exit-status --raw-output '.version | strings | select(length > 0)' <<< "$package_info")"
    expected_file="${package_name}-${package_version}.pkg.tar.gz"
    package_identity="${package_name},${package_version}"

    if [[ ! "$package_name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ || ! "$package_version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
        echo "Package identity contains unsupported characters: ${package_identity}" >&2
        exit 1
    fi
    if [[ "$package_file" != "$expected_file" ]]; then
        echo "Package filename ${package_file} does not match ${expected_file}." >&2
        exit 1
    fi
    if [[ -n "${package_identities[$package_identity]:-}" ]]; then
        echo "Duplicate package identity: ${package_identity}" >&2
        exit 1
    fi
    package_identities[$package_identity]=1

    cp "$package_archive" "${STAGING_DIR}/${package_file}"
    package_checksum="$(sha256sum "${STAGING_DIR}/${package_file}" | awk '{print $1}')"
    printf '%s,%s,%s,%s%s\n' \
        "$package_name" \
        "$package_version" \
        "$package_checksum" \
        "$BASEURL" \
        "$package_file" >> "$RECORDS_FILE"
    echo "Adding package ${package_name}-${package_version}"
done

sort --field-separator=, --key=1,1 --key=2,2 "$RECORDS_FILE" > "${STAGING_DIR}/index"

find "$REPO_DIR" -maxdepth 1 -type f -name '*.pkg.tar.gz' -delete
for staged_archive in "${STAGING_DIR}"/*.pkg.tar.gz; do
    if [[ -e "$staged_archive" ]]; then
        mv "$staged_archive" "$REPO_DIR/"
    fi
done
mv "${STAGING_DIR}/index" "${REPO_DIR}/index"
