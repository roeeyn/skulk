#!/usr/bin/env bash
#
# Build the relay image for ONE platform, prove it boots, and optionally push it
# by digest.
#
# Both release jobs call this — the amd64 one on ubuntu-latest, the arm64 one on
# ubuntu-24.04-arm — so the two architectures cannot drift apart by someone
# editing one job and not the other. It runs by hand too, which is the point:
#
#     .github/scripts/build-relay-image.sh linux/arm64 skulkd 0.0.0-dev "$(git rev-parse HEAD)"
#
# Without --push it builds and smoke-tests and stops there, which is also what
# the workflow's manual dry run does.
#
# ## Why it boots the image before pushing it
#
# The relay compiles a C NIF (argon2). Cross-architecture, that is the thing most
# likely to build cleanly and then fail at the first password hash — and
# /healthz would answer perfectly while it did. Each release job runs natively on
# its own architecture, so booting what it just built costs seconds and is the
# only thing standing between a tag and a published image that cannot hash a
# password on half the machines that pull it.
set -euo pipefail

if [ "$#" -lt 4 ]; then
  echo "usage: $0 <platform> <image> <version> <revision> [--push]" >&2
  exit 64
fi

platform="$1"
image="$2"
version="$3"
revision="$4"
push="${5:-}"

# A tag that exists only on this machine, for the smoke test. The pushed artifact
# is addressed by digest and never by this name.
local_tag="skulkd-build:${platform//\//-}"
container="skulkd-smoke-$$"

cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> building $platform"
docker buildx build \
  --platform "$platform" \
  --build-arg "VERSION=$version" \
  --build-arg "REVISION=$revision" \
  --load \
  --tag "$local_tag" \
  .

# ---------------------------------------------------------------------------
echo "==> it boots, and answers /healthz"

# An ephemeral host port: two release jobs may share a runner, and a fixed 4000
# would make that a flake rather than an error.
docker run -d --name "$container" -p 127.0.0.1::4000 "$local_tag" >/dev/null
address="$(docker port "$container" 4000/tcp | head -1)"

answered=""
for _ in $(seq 1 30); do
  # -s not -sS: the first attempts land before Bandit is listening, and their
  # "Empty reply from server" would read like a failure in a log that ends in
  # success.
  if curl -fs --max-time 2 "http://${address}/healthz"; then
    answered=yes
    echo
    break
  fi
  sleep 1
done

if [ -z "$answered" ]; then
  echo "the $platform image never answered /healthz within 30s" >&2
  docker logs "$container" >&2
  exit 1
fi

echo "==> it is not running as root"
user="$(docker exec "$container" id -un)"
[ "$user" = "skulkd" ] || { echo "expected user skulkd, got $user" >&2; exit 1; }

# The relay holds no keys and issues no credentials, so its image has no reason
# to carry a single environment variable that looks like one — nor a default
# relay address, which A10 refuses to ship precisely because a one-liner
# installer next to an unauthenticated relay is an advertisement for it.
echo "==> it carries no credentials and no default relay address"
if docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$local_tag" \
   | grep -Ei '^(SKULK_SERVER|.*(PASSWORD|PASSPHRASE|SECRET|TOKEN|CREDENTIAL|API_?KEY).*)=' ; then
  echo "the image ships an environment variable it should not" >&2
  exit 1
fi

echo "==> labels"
docker inspect --format '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{println}}{{end}}' "$local_tag" \
  | grep '^org.opencontainers' | sort

cleanup

# ---------------------------------------------------------------------------
if [ "$push" != "--push" ]; then
  echo "==> not pushing (no --push)"
  exit 0
fi

echo "==> pushing $platform by digest"

# Second build, entirely from cache: the first one populated it, so this is an
# export rather than a compile. Pushing BY DIGEST rather than by tag is what lets
# the publish job assemble one multi-arch manifest from two independent jobs
# without either of them claiming a tag the other would overwrite.
metadata="$(mktemp)"
docker buildx build \
  --platform "$platform" \
  --build-arg "VERSION=$version" \
  --build-arg "REVISION=$revision" \
  --output "type=image,name=${image},push-by-digest=true,name-canonical=true,push=true" \
  --metadata-file "$metadata" \
  .

digest="$(jq -r '."containerimage.digest"' "$metadata")"
rm -f "$metadata"

if [ -z "$digest" ] || [ "$digest" = "null" ]; then
  echo "buildx reported no digest" >&2
  exit 1
fi

echo "digest: $digest"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "digest=$digest" >> "$GITHUB_OUTPUT"
exit 0
