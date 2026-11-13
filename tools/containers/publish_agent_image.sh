#!/bin/bash
# Visor's toolchain image (tools/containers/visor-agent/Dockerfile's build
# target), built with buildah in CI's Linux container (arm64, as the
# containers that run it) and pushed to GitHub's registry as
# ghcr.io/attilathefun/visor-agent, tagged this build's version, its
# MAJOR.MINOR and latest: what CI's containers and Shireworks' primary
# container run. A build by hand, between releases, is tagged
# `<version>-<commit>` and latest only, so a release's tags keep the image
# they were given. (Its runtime target, ghcr.io/attilathefun/visor, was for
# the session containers Visor made, which it no longer makes: no longer
# pushed.)
#
# CI's agent-image job runs it in a visor-jit container, as every job but the
# headful proofs (Logan, 8 Nov 2026); until 0.48 it ran on the mini with
# Apple's container. buildah comes from the distribution's packages when the
# image has none, and builds as the container's root, which a Shireworks server
# container's VM makes a root of its own. A package the registry hasn't had
# before is private until its owner makes it public, once.
#
#   GHCR_USER=<user> GHCR_TOKEN=<token> tools/containers/publish_agent_image.sh 0.48.1
#   tools/containers/publish_agent_image.sh 0.48.1-1a2b3c4               # by hand: that tag and latest
#   VISOR_PUBLISH=0 tools/containers/publish_agent_image.sh 0.48.1   # builds it, pushes nothing
set -euo pipefail
version="${1:?the version, MAJOR.MINOR.BUILD, or MAJOR.MINOR.BUILD-<commit> for a build by hand}"
case "$version" in
  *-*) tags=("$version" latest) ;;
  *) tags=("$version" "${version%.*}" latest) ;;
esac
here="$(cd "$(dirname "$0")" && pwd)"
publish="${VISOR_PUBLISH:-1}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Its Visor server and agents' host from this checkout's commit (fetched by
# the build from GitHub, so the commit must have been pushed).
commit="${VISOR_REF:-$(git -C "$here" rev-parse HEAD)}"

root_do() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
if ! command -v buildah > /dev/null; then
  root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends buildah > /dev/null ||
    { root_do apt-get update -qq > /dev/null &&
      root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends buildah > /dev/null; }
fi
echo "$(buildah --version)"

# The registry's credentials in a file of the run's own, gone with it.
export REGISTRY_AUTH_FILE="$work/auth.json"
if [ "$publish" = 1 ]; then
  printf '%s' "${GHCR_TOKEN:?a token that writes packages}" \
    | buildah login --username "${GHCR_USER:?the registry user}" --password-stdin ghcr.io > /dev/null
fi

# One target, built, then pushed as its repository's version, MAJOR.MINOR and
# latest. The kernel's overlay storage (a Shireworks server container is a VM, its
# disk ext4), and chroot isolation, which needs no user namespace;
# VISOR_BUILDAH_STORAGE=vfs where overlay can't be had (slower, and every
# layer a whole copy on the disk).
storage="${VISOR_BUILDAH_STORAGE:-overlay}"
publish() {
  local target="$1" repository="$2" image="localhost/visor-$1:$version"
  buildah --storage-driver "$storage" build --isolation chroot --layers --target "$target" \
    --build-arg VISOR_REF="$commit" --build-arg TARGETARCH=arm64 --platform linux/arm64 \
    --tag "$image" --file "$here/visor-agent/Dockerfile" "$here/visor-agent"
  if [ "$publish" != 1 ]; then
    echo "built $image (VISOR_PUBLISH=0: not pushed)"
    return
  fi
  for tag in "${tags[@]}"; do
    buildah --storage-driver "$storage" push --digestfile "$work/digest" "$image" "docker://$repository:$tag"
    echo "pushed $repository:$tag ($(cat "$work/digest"))"
  done
}

publish build ghcr.io/attilathefun/visor-agent
