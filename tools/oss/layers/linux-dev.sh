#!/bin/bash
# The dev layer on Ubuntu, all through apt: Git, Chrome (Google's apt
# repository, which the package adds) and Bazelisk (its release's .deb).
set -euo pipefail
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl >/dev/null
cd /tmp
curl -fsSLO https://dl.google.com/linux/direct/google-chrome-stable_current_arm64.deb
curl -fsSL -o bazelisk.deb https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-arm64.deb
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ./google-chrome-stable_current_arm64.deb ./bazelisk.deb >/dev/null
rm -f google-chrome-stable_current_arm64.deb bazelisk.deb
echo "dev: $(git --version); $(google-chrome --version); bazel $(cd /tmp && bazel --version 2>/dev/null)"
