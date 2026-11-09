#!/usr/bin/env bash

set -euo pipefail

readonly PYTHON_VERSION=3.12.0
readonly PYTHON_SHA256=51412956d24a1ef7c97f1cb5f70e185c13e3de1f50d131c0aac6338080687afb
readonly PREFIX="$(realpath "$(dirname "$0")")"

mkdir -p "$PREFIX/build"
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

bin/pip3 install --no-cache-dir --only-binary=:all: \
    base58==2.1.1 \
    bcrypt==5.0.0 \
    cffi==2.1.1 \
    cryptography==50.0.2 \
    mpmath==1.3.0 \
    networkx==3.7 \
    numpy==2.5.4 \
    pandas==3.1.1 \
    passlib==1.7.4 \
    pycparser==3.12 \
    pycryptodome==4.4.0 \
    PyNaCl==1.6.2 \
    python-dateutil==4.0.0 \
    scipy==1.18.1 \
    sympy==1.14.0 \
    tzdata==2026.6 \
    whoosh==2.7.4 \
    xxhash==4.0.2
