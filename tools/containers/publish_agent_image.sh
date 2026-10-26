#!/bin/bash
# Visor's agent image (tools/containers/visor-agent), which sessions'
# containers are made from, built (Apple's container: arm64 Linux, layers
# unchanged since the last build from the builder's cache) and pushed to
# GitHub's registry as this build's version and as its MAJOR.MINOR: a Visor
# server of that version asks OS Server for the one (a build CI did not
# number, for the other). CI's agent-image job runs it on the release Mac.
#
#   GHCR_USER=<user> GHCR_TOKEN=<token> tools/containers/publish_agent_image.sh 0.40.12
set -euo pipefail
version="${1:?the version, MAJOR.MINOR.BUILD}"
repository="ghcr.io/attilathefun/visor-agent"
minor="${version%.*}"
cd "$(dirname "$0")/visor-agent"
container build --tag "$repository:$version" --file Dockerfile .
container image tag "$repository:$version" "$repository:$minor"
printf '%s' "${GHCR_TOKEN:?a token that writes packages}" | container registry login --username "${GHCR_USER:?the registry user}" --password-stdin ghcr.io
container image push "$repository:$version"
container image push "$repository:$minor"
echo "pushed $repository:$version and :$minor"
