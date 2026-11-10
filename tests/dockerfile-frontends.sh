#!/usr/bin/env bash

set -Eeuo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly EXPECTED='# syntax=docker/dockerfile:1.28.0@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b'

for dockerfile in api/Dockerfile builder/Dockerfile repo/Dockerfile; do
    IFS= read -r actual < "${ROOT}/${dockerfile}"
    if [[ "$actual" != "$EXPECTED" ]]; then
        echo "${dockerfile} must use the reviewed Dockerfile frontend." >&2
        exit 1
    fi
done

echo 'Dockerfile frontend identities passed'
