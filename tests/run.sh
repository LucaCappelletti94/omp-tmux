#!/bin/sh
# Runs the tests in a container with its own processes, tmux sockets and no network, so a test
# can never signal or reach the host's tmux sessions.
# usage: [TMUX_VERSION=3.8] [BASE_IMAGE=ubuntu:22.04] tests/run.sh [BATS ARGS]
# tmux 3.2a built from source on Ubuntu 24.04 misparses commands, so test it as Ubuntu 22.04's package.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmux_version=${TMUX_VERSION:-apt}
base_image=${BASE_IMAGE:-ubuntu:24.04}
[ $# -gt 0 ] || set -- tests/
stage=grid-tests
for argument; do
	case $argument in
	tests/grid.bats | tests/layout.bats | tests/lifecycle.bats | tests/pickers.bats | tests/terminal.bats) ;;
	*) stage=dock-tests ;;
	esac
done
image=omp-tmux-tests:$tmux_version-$(echo "$base_image" | tr ':/' '--')-$stage

docker build -q -t "$image" --target "$stage" --build-arg TMUX_VERSION="$tmux_version" --build-arg BASE_IMAGE="$base_image" \
	-f "$root/tests/Dockerfile" "$root" >/dev/null
exec docker run --rm --init --network none --pids-limit 1024 "$image" bats "$@"
