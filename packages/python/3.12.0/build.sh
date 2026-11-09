#!/usr/bin/env bash

set -euo pipefail

readonly PYTHON_VERSION=3.12.0
readonly PYTHON_SHA256=51412956d24a1ef7c97f1cb5f70e185c13e3de1f50d131c0aac6338080687afb
readonly PREFIX="$(realpath "$(dirname "$0")")"
readonly REPRODUCIBLE_TIMESTAMP=1696204800
readonly REQUIREMENTS_LOCK="${PREFIX}/requirements.lock"

export PYTHONHASHSEED=0
export SOURCE_DATE_EPOCH="$REPRODUCIBLE_TIMESTAMP"
umask 022

rm -rf \
    "$PREFIX/bin" \
    "$PREFIX/build" \
    "$PREFIX/include" \
    "$PREFIX/lib" \
    "$PREFIX/lib64" \
    "$PREFIX/share"
mkdir "$PREFIX/build"
cd "$PREFIX/build"

curl --fail --location --silent --show-error \
    "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz" \
    --output python.tar.gz
echo "${PYTHON_SHA256}  python.tar.gz" | sha256sum --check --strict
tar xzf python.tar.gz --strip-components=1
rm python.tar.gz

./configure --prefix "$PREFIX" --with-ensurepip=install
make -j"$(nproc)"
make install -j"$(nproc)"

cd "$PREFIX"
rm -rf build

bin/pip3 install \
    --disable-pip-version-check \
    --no-cache-dir \
    --only-binary=:all: \
    --require-hashes \
    --requirement "$REQUIREMENTS_LOCK"

bin/python3.12 -m pip check
