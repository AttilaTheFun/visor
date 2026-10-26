#!/bin/bash
# Visor's agent image (tools/containers/visor-agent), which sessions'
# containers are made from, built (Apple's container: arm64 Linux, layers
# unchanged since the last build from the builder's cache) and pushed to
# GitHub's registry as this build's version and as its MAJOR.MINOR: a Visor
# server of that version asks OS Server for the one (a build CI did not
# number, for the other). CI's agent-image job runs it on the release Mac.
#
# It is pushed with crane (go-containerregistry, a pinned release), its
# credentials in a file of its own for the run: Apple's container keeps a
# registry's in the login keychain, where its image service then waits on a
# prompt that no one answers on a runner.
#
#   GHCR_USER=<user> GHCR_TOKEN=<token> tools/containers/publish_agent_image.sh 0.40.12
set -euo pipefail
version="${1:?the version, MAJOR.MINOR.BUILD}"
repository="ghcr.io/attilathefun/visor-agent"
minor="${version%.*}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

container build --tag "$repository:$version" --file "$here/visor-agent/Dockerfile" "$here/visor-agent"

# The image as an OCI layout. Its index names the image's own index (its
# platforms), which becomes the layout's index: the tag then names the
# platforms, not an index of an index.
container image save --platform linux/arm64 --output "$work/image.tar" "$repository:$version"
mkdir "$work/layout"
tar -xf "$work/image.tar" -C "$work/layout"
inner="$(sed -E 's/.*"digest":"sha256:([0-9a-f]{64})".*/\1/' "$work/layout/index.json")"
cp "$work/layout/blobs/sha256/$inner" "$work/layout/index.json"

crane_version="v0.22.1"
crane_sha256="2231fc8df8806d20d680ff1225db44e095a55dd6ac1ae8eced4faf4b278b78fb"
curl -sSfL -o "$work/crane.tar.gz" \
  "https://github.com/google/go-containerregistry/releases/download/$crane_version/go-containerregistry_Darwin_arm64.tar.gz"
echo "$crane_sha256  $work/crane.tar.gz" | shasum -a 256 -c - >/dev/null
tar -xzf "$work/crane.tar.gz" -C "$work" crane

export DOCKER_CONFIG="$work/docker"
printf '%s' "${GHCR_TOKEN:?a token that writes packages}" \
  | "$work/crane" auth login ghcr.io --username "${GHCR_USER:?the registry user}" --password-stdin
"$work/crane" push --index "$work/layout" "$repository:$version"
"$work/crane" tag "$repository:$version" "$minor"
echo "pushed $repository:$version and :$minor"
