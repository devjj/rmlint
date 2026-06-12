#!/bin/sh
# Wrapper: build the fully static musl rmlint binary inside an Alpine container.
#
# Usage (from anywhere):  pkg/static/build-static-musl.podman.sh
# Result:                 ./rmlint.static at the repo root.
#
# The repo is bind-mounted read-write at /src; the build writes rmlint.static
# back into the working tree. Uses podman (rootless-friendly); swap for docker
# if preferred.
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENGINE=${CONTAINER_ENGINE:-podman}

# Pass RUN_TESTS=1 through to run the behavioural suite against the static
# binary inside the container (CI does this).
exec "$ENGINE" run --rm \
    -e RUN_TESTS="${RUN_TESTS:-0}" \
    -v "$REPO_ROOT":/src:Z \
    -w /src \
    alpine:latest \
    sh /src/pkg/static/build-static-musl.sh
