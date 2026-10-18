# Image for tests/run.sh, installed by the same script CI uses.
FROM ubuntu:24.04
ARG TMUX_VERSION=apt
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8 RUNNER_TEMP=/opt GITHUB_PATH=/tmp/github-path
RUN apt-get update -qq && apt-get install -y -qq sudo git curl ca-certificates build-essential procps >/dev/null
COPY ci-setup.sh /tmp/ci-setup.sh
RUN TMUX_VERSION="$TMUX_VERSION" sh /tmp/ci-setup.sh
ENV PATH=/opt/bats/bin:$PATH
