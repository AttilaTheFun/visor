#!/bin/bash
# Visor's images (tools/containers/visor-agent/Dockerfile), built (Apple's
# container: arm64 Linux, layers unchanged since the last build from the
# builder's cache) and pushed to GitHub's registry, each as this build's
# version, its MAJOR.MINOR and latest:
#
# - the runtime target as ghcr.io/attilathefun/visor, the image sessions'
#   containers are made from: a Visor server of that version makes them
#   from the first (a build CI did not number, from the second; one that
#   says no version, from the last);
# - the build target as ghcr.io/attilathefun/visor-agent, with the
#   toolchains: CI's containers and the co-tenant's.
#
# CI's agent-image job runs it on the release Mac. A package the registry
# hasn't had before is private until its owner makes it public, once.
#
# It is pushed with crane (go-containerregistry, a pinned release), its
# credentials in a file of its own for the run: Apple's container keeps a
# registry's in the login keychain, where its image service then waits on a
# prompt that no one answers on a runner.
#
#   GHCR_USER=<user> GHCR_TOKEN=<token> tools/containers/publish_agent_image.sh 0.40.12
set -euo pipefail
version="${1:?the version, MAJOR.MINOR.BUILD}"
minor="${version%.*}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Its Visor server and agents' host from this checkout's commit (fetched by
# the build from GitHub, so the commit must have been pushed).
commit="${VISOR_REF:-$(git -C "$here" rev-parse HEAD)}"

crane_version="v0.22.1"
crane_sha256="2231fc8df8806d20d680ff1225db44e095a55dd6ac1ae8eced4faf4b278b78fb"
curl -sSfL -o "$work/crane.tar.gz" \
  "https://github.com/google/go-containerregistry/releases/download/$crane_version/go-containerregistry_Darwin_arm64.tar.gz"
echo "$crane_sha256  $work/crane.tar.gz" | shasum -a 256 -c - >/dev/null
tar -xzf "$work/crane.tar.gz" -C "$work" crane

export DOCKER_CONFIG="$work/docker"
printf '%s' "${GHCR_TOKEN:?a token that writes packages}" \
  | "$work/crane" auth login ghcr.io --username "${GHCR_USER:?the registry user}" --password-stdin

# One target, built and pushed as its repository's version, MAJOR.MINOR and
# latest.
publish() {
  local target="$1" repository="$2"
  container build --tag "$repository:$version" --target "$target" --build-arg VISOR_REF="$commit" \
    --file "$here/visor-agent/Dockerfile" "$here/visor-agent"
  # The image as an OCI layout. Its index names the image's own index (its
  # platforms), which becomes the layout's index: the tag then names the
  # platforms, not an index of an index.
  container image save --platform linux/arm64 --output "$work/$target.tar" "$repository:$version"
  mkdir "$work/$target"
  tar -xf "$work/$target.tar" -C "$work/$target"
  local inner
  inner="$(sed -E 's/.*"digest":"sha256:([0-9a-f]{64})".*/\1/' "$work/$target/index.json")"
  cp "$work/$target/blobs/sha256/$inner" "$work/$target/index.json"
  "$work/crane" push --index "$work/$target" "$repository:$version"
  "$work/crane" tag "$repository:$version" "$minor"
  "$work/crane" tag "$repository:$version" latest
  echo "pushed $repository:$version, :$minor and :latest"
}

publish runtime ghcr.io/attilathefun/visor
publish build ghcr.io/attilathefun/visor-agent
