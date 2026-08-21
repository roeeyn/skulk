# skulkd — the relay. Spec §24 ("Dockerfile for the relay and minimal container
# configuration").
#
# This image contains the RELAY ONLY. The client is a Go binary that people
# install with Homebrew or download from a release; putting a terminal UI in a
# container would be a stunt.
#
#     docker build -t skulkd .
#     docker run --rm -p 4000:4000 skulkd
#
# Configuration is environment variables — see skulkd/skulkd.env.example, and
# entry #2 in docs/deviations.md for why they are not §7.4's flags yet.
#
# Two pins, both deliberate. The builder tag names its Elixir, Erlang AND Debian
# snapshot, so a rebuild six months from now produces the same relay rather than
# whatever is current. The runtime tag is a LATER snapshot of the same Debian
# release than the builder's: same glibc line, more security updates. Never the
# other way round — a binary built against newer glibc than it runs on does not
# start.
#
# `--build-arg` overrides either, which is how ROJ-53 will rebuild on a base
# image CVE without touching this file.
ARG BUILDER_IMAGE=hexpm/elixir:1.18.3-erlang-27.3.4.3-debian-trixie-20250929-slim
ARG RUNTIME_IMAGE=debian:trixie-20251229-slim

# ---------------------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS build

# argon2_elixir is a NIF: it compiles C at dependency-fetch time, so the builder
# needs a toolchain that the runtime image must not have.
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

# Dependencies before source, so editing lib/ does not refetch and rebuild the
# whole tree. mix.lock is what makes this layer reproducible.
COPY skulkd/mix.exs skulkd/mix.lock ./
RUN mix deps.get --only prod \
    && mix deps.compile

# config/ before lib/: compile-time configuration is read while compiling.
# config/runtime.exs is not evaluated here — it is copied into the release and
# read at boot, which is the whole point of it.
COPY skulkd/config config
COPY skulkd/lib lib

RUN mix compile && mix release

# ---------------------------------------------------------------------------
FROM ${RUNTIME_IMAGE} AS runtime

# A release carries its own Erlang runtime, so this needs the shared libraries
# that runtime links against and nothing else: no Elixir, no Erlang install, no
# build-essential, no source. openssl is the one that matters — it is what
# :crypto binds to.
#
# curl is here for HEALTHCHECK only. If you would rather not have an HTTP client
# inside the image, delete it and the HEALTHCHECK together and let whatever
# supervises the container probe /healthz from outside.
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libncurses6 \
        libstdc++6 \
        openssl \
    && rm -rf /var/lib/apt/lists/*

# The BEAM decides how to treat binaries from the locale. Without this, a room id
# or a message containing anything outside ASCII is at the mercy of whatever the
# base image happened to set.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Erlang distribution off. It would open a port and expect a shared cookie, and
# this relay has no cluster to join — `bin/skulkd remote` is not worth an extra
# listening socket on a host exposed to the internet. Set RELEASE_DISTRIBUTION
# back to `sname` if you want a remote console and can keep the port private.
ENV RELEASE_DISTRIBUTION=none

# Rooms live in memory and nothing is ever written to disk (§20), so the relay
# needs no write access to anything and does not run as root.
RUN useradd --system --create-home --uid 10001 --shell /usr/sbin/nologin skulkd

WORKDIR /app
COPY --from=build --chown=skulkd:skulkd /src/_build/prod/rel/skulkd ./

USER skulkd

# Every interface, because the container boundary is what limits reachability
# here. Override with -e SKULKD_BIND=... ; every other bound is a §8 default
# until you set it. See skulkd/skulkd.env.example.
ENV SKULKD_BIND=0.0.0.0:4000
EXPOSE 4000

# /healthz is unauthenticated and says nothing about any room — see §18.1.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -fsS http://127.0.0.1:4000/healthz || exit 1

ENTRYPOINT ["/app/bin/skulkd"]
CMD ["start"]
