#!/bin/bash
# The dev layer on Ubuntu, all through apt: Git, the build basics agents
# would otherwise install in every lease, Chrome (Google's apt repository,
# which the package adds) and Bazelisk (its release's .deb). A lease then
# builds without apt, which the computer's DNS can't always reach (Manager,
# 11 Nov: Apple Cross's gcc install failed on it).
set -euo pipefail
# The build basics: compilers (gcc, g++, clang, lld), make, CMake and Ninja,
# pkg-config, the headers native modules and Swift on Linux link against
# (OpenSSL, zlib, SQLite, curl, libxml2), Python's venv and pip, and the
# command-line tools agents reach for (jq, ripgrep, rsync, zip).
PACKAGES=(
    git curl ca-certificates openssh-client patch
    build-essential clang lld cmake ninja-build pkg-config
    libssl-dev zlib1g-dev libsqlite3-dev libcurl4-openssl-dev libxml2-dev
    python3 python3-venv python3-pip
    jq ripgrep rsync unzip zip file less tmux
)
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${PACKAGES[@]}" >/dev/null
cd /tmp
curl -fsSLO https://dl.google.com/linux/direct/google-chrome-stable_current_arm64.deb
curl -fsSL -o bazelisk.deb https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-arm64.deb
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ./google-chrome-stable_current_arm64.deb ./bazelisk.deb >/dev/null
rm -f google-chrome-stable_current_arm64.deb bazelisk.deb
# Chrome run from a shell (an agent's over SSH, headless) keeps its secrets
# in its profile, not the GNOME keyring: the keyring is locked or out of
# reach there, and Chrome's cookie store waits for it, so every http(s) page
# hangs until its load times out (only data: URLs load). These wrappers,
# ahead of /usr/bin on PATH, pass --password-store=basic; the desktop's
# launcher (its .desktop file names /usr/bin's) is unchanged.
for name in google-chrome google-chrome-stable; do
    printf '#!/bin/sh\nexec /opt/google/chrome/google-chrome --password-store=basic "$@"\n' | sudo tee "/usr/local/bin/$name" >/dev/null
    sudo chmod 755 "/usr/local/bin/$name"
done
echo "dev: $(git --version); $(gcc --version | head -1); $(clang --version | head -1); $(cmake --version | head -1); $(python3 --version); $(google-chrome --version); bazel $(cd /tmp && bazel --version 2>/dev/null)"
