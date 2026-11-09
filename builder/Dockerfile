# syntax=docker/dockerfile:1

ARG PISTON_IMAGE=piston-api:local-arm64
FROM ${PISTON_IMAGE}

# Preserve the API image's root entrypoint so it can initialize cgroup v2.
COPY --link . /piston/packages/
