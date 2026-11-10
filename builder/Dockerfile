# syntax=docker/dockerfile:1.28.0@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b

ARG PISTON_IMAGE=piston-api:local-arm64
FROM ${PISTON_IMAGE}

# Preserve the API image's root entrypoint so it can initialize cgroup v2.
COPY --link . /piston/packages/
