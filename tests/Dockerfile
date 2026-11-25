# Image for tests/run.sh, installed by the same script CI uses.
ARG BASE_IMAGE=ubuntu:24.04
FROM $BASE_IMAGE AS grid-tests
ARG TMUX_VERSION=apt
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8 RUNNER_TEMP=/opt GITHUB_PATH=/tmp/github-path
RUN apt-get update -qq && apt-get install -y -qq sudo git curl ca-certificates build-essential procps >/dev/null
COPY .github/ci-setup.sh /tmp/ci-setup.sh
RUN TMUX_VERSION="$TMUX_VERSION" sh /tmp/ci-setup.sh
ENV PATH=/opt/bats/bin:$PATH
WORKDIR /w
COPY omp-tmux.conf omp-tmux.tmux ./
COPY scripts/ scripts/
COPY tests/ tests/

FROM rust:1.88-alpine AS dock-build
RUN apk add --no-cache musl-dev
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src/ src/
RUN cargo build --locked --release -p omp-dock

FROM grid-tests AS dock-tests
COPY --from=dock-build /build/target/release/omp-dock /usr/local/bin/omp-dock
