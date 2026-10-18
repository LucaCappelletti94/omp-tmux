#!/bin/sh
# Runs the tests in a container with its own processes, tmux sockets and no network, so a test
# can never signal or reach the host's tmux sessions.
# usage: [TMUX_VERSION=3.8] [BASE_IMAGE=ubuntu:22.04] tests/run.sh [BATS ARGS]
# tmux 3.2a built from source on Ubuntu 24.04 misparses commands, so test it as Ubuntu 22.04's package.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmux_version=${TMUX_VERSION:-apt}
base_image=${BASE_IMAGE:-ubuntu:24.04}
image=omp-tmux-tests:$tmux_version-$(echo "$base_image" | tr ':/' '--')

docker build -q -t "$image" --build-arg TMUX_VERSION="$tmux_version" --build-arg BASE_IMAGE="$base_image" \
	-f "$root/tests/Dockerfile" "$root/.github" >/dev/null
[ $# -gt 0 ] || set -- tests/
exec docker run --rm --init --network none --pids-limit 1024 -v "$root:/src:ro" "$image" \
	sh -c 'cp -r /src /w && cd /w && exec bats "$@"' sh "$@"
