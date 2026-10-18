#!/bin/sh
# Runs the tests in a container with its own processes, tmux sockets and no network, so a test
# can never signal or reach the host's tmux sessions. usage: [TMUX_VERSION=3.8] tests/run.sh [BATS ARGS]
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmux_version=${TMUX_VERSION:-apt}
image=omp-tmux-tests:$tmux_version

docker build -q -t "$image" --build-arg TMUX_VERSION="$tmux_version" -f "$root/tests/Dockerfile" "$root/.github" >/dev/null
[ $# -gt 0 ] || set -- tests/
exec docker run --rm --init --network none --pids-limit 1024 -v "$root:/src:ro" "$image" \
	sh -c 'cp -r /src /w && cd /w && exec bats "$@"' sh "$@"
