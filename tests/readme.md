# Exploit Tests

This directory contains a collection of exploits which have already been patched

Write exploits in any language supported by piston.

Hopefully when running any files in this directory, piston will resist the attack.

Leave a comment in the code describing how the exploit works.

## Native ARM64 acceptance

Run `./tests/acceptance-arm64.sh` from the repository root to build and validate the local API image, package-builder image, and Python 3.12.0 package on a native ARM64 Docker host.

The harness covers the REST and WebSocket contracts, pure cgroup v2 startup, package installation and deletion, scientific imports, execution limits, network and file isolation, and package persistence across restart and container replacement.
It also enables bounded per-sandbox filesystems and proves aggregate storage exhaustion, inode exhaustion, three-slot independence, and clean subsequent jobs.
The suite verifies that `/tmp` is an isolated memory-backed filesystem, that slot reset waits for delayed loop-device release, and that an injected slot-reset failure stops Piston instead of returning a dirty slot to the pool.

Set `SKIP_IMAGE_BUILD=1` to reuse existing `piston-api:local-arm64` and `piston-repo:local-arm64` images.
Set `PISTON_PACKAGE_REPO_DIR` to reuse an existing package repository directory containing an `index` file and package archive.

Run `tests/reproducible-package.sh` on a native ARM64 Docker host to build the Python package twice from tracked clean inputs and require byte-identical package archives and repository indexes.
Set `PISTON_REPRODUCIBILITY_OUTPUT_DIR` to retain one verified repository for reuse through `PISTON_PACKAGE_REPO_DIR` during full acceptance.

Run `tests/dockerfile-frontends.sh` to require every maintained Dockerfile to use the reviewed immutable frontend identity.
The selected `docker/dockerfile:1.28.0` index digest is `sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b`, and its verified Linux ARM64 manifest is `sha256:da84f4c7220ca8b66b7a0be6066d5e559878c2248beb92bdc8530dd9356bd711`.
Set `KEEP_ACCEPTANCE_RESOURCES=1` to keep the uniquely named test containers, network, and temporary directory for inspection.
