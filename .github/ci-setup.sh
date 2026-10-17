#!/bin/sh
# Installs tmux $TMUX_VERSION (apt, apk, brew, master or a release tag) and pinned bats-core.
set -eu

case $TMUX_VERSION in
apt)
	sudo apt-get update -qq
	sudo apt-get install -y -qq tmux
	;;
apk)
	apk add -q tmux bash git ncurses-terminfo-base
	;;
brew)
	brew install tmux
	;;
*)
	sudo apt-get update -qq
	sudo apt-get install -y -qq libevent-dev libncurses-dev bison pkg-config autoconf automake
	src=$(mktemp -d)
	if [ "$TMUX_VERSION" = master ]; then
		git clone -q --depth 1 https://github.com/tmux/tmux.git "$src"
		(cd "$src" && sh autogen.sh)
	else
		curl -fsSL "https://github.com/tmux/tmux/releases/download/$TMUX_VERSION/tmux-$TMUX_VERSION.tar.gz" |
			tar -xz -C "$src" --strip-components 1
	fi
	(cd "$src" && ./configure --prefix=/usr/local && make -j"$(nproc)" && sudo make install)
	;;
esac

git clone -q --depth 1 --branch "$BATS_VERSION" https://github.com/bats-core/bats-core.git "$RUNNER_TEMP/bats"
[ "$(git -C "$RUNNER_TEMP/bats" rev-parse HEAD)" = "$BATS_COMMIT" ]
echo "$RUNNER_TEMP/bats/bin" >>"$GITHUB_PATH"
command -v tmux
tmux -V
