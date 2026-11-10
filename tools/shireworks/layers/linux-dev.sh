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
echo "dev: $(git --version); $(google-chrome --version); bazel $(cd /tmp && bazel --version 2>/dev/null)"
