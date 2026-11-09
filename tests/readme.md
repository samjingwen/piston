# Exploit Tests

This directory contains a collection of exploits which have already been patched

Write exploits in any language supported by piston.

Hopefully when running any files in this directory, piston will resist the attack.

Leave a comment in the code describing how the exploit works.

## Native ARM64 acceptance

Run `./tests/acceptance-arm64.sh` from the repository root to build and validate the local API image, package-builder image, and Python 3.12.0 package on a native ARM64 Docker host.

The harness covers the REST and WebSocket contracts, pure cgroup v2 startup, package installation and deletion, scientific imports, execution limits, network and file isolation, and package persistence across restart and container replacement.

Set `SKIP_IMAGE_BUILD=1` to reuse existing `piston-api:local-arm64` and `piston-repo:local-arm64` images.
Set `PISTON_PACKAGE_REPO_DIR` to reuse an existing package repository directory containing an `index` file and package archive.
Set `KEEP_ACCEPTANCE_RESOURCES=1` to keep the uniquely named test containers, network, and temporary directory for inspection.
