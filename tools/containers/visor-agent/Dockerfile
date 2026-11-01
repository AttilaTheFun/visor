# Visor's agent image: the Linux a session's agent runs in when it runs in a
# container on its Visor server's Mac (leased from OS Server there), or that
# a container's own Visor server runs in (visor-server, visor-agent-host,
# this image's commit's). Claude
# Code, Codex and openrouter (OpenRouter's models), with Node (which also
# runs Visor's MCP script and `visor`), Swift
# 6.4.0 (which Bazel's Swift package rules ask for on Linux; the same as
# rules_applecross builds Apple apps with), git, ssh, tmux, Python, Bazel
# (bazelisk), and what Isomer's Linux apps link (SDL, GL, GTK, WebKitGTK).
# CI publishes it for each build (tools/containers/publish_agent_image.sh)
# as ghcr.io/attilathefun/visor-agent:<version> and :<MAJOR.MINOR>, and a
# Visor server leases each session's container from the OS Server on its
# Mac made from its own version's (its `containers image` setting names
# another).
# The container sees the session's folder at the same path and Visor's
# tools at /opt/visor (read-only, from the server); no Xcode: Apple apps
# build with rules_applecross from the SDK archive an OS Server serves, and
# Android's x86_64 build tools run under Rosetta on an arm64 Mac. Its sign-ins live with the Visor server,
# never in the image (ContainerSignIns):
#   <Visor's data>/containers/agent.env   CLAUDE_CODE_OAUTH_TOKEN=… (`claude setup-token`)
#   <Visor's data>/containers/codex/      Codex's home in every container, mounted: its own
#                                         sign-in, made once (never a copy of the Mac's):
#     container run -it --rm --mount type=bind,source="<Visor's data>/containers/codex",target=/root/.codex \
#       ghcr.io/attilathefun/visor-agent:<version> codex login --device-auth
#   <Visor's data>/containers/openrouter/ openrouter's home in every container, mounted: its key
#                                         (or OPENROUTER_API_KEY in agent.env), set once:
#     container run -it --rm --mount type=bind,source="<Visor's data>/containers/openrouter",target=/root/.openrouter \
#       ghcr.io/attilathefun/visor-agent:<version> openrouter auth login
#   <Visor's data>/containers/home/       other files, copied into each container's home

# openrouter (github.com/AttilaTheFun/open_router_cli), built from a tag (or
# any commit: OPENROUTER_REF) in a stage of its own; only the binary comes
# over.
FROM docker.io/library/swift:6.4.0-noble AS openrouter
ARG OPENROUTER_REF=v0.5.0
RUN git init -q /src && cd /src \
 && git fetch -q --depth 1 https://github.com/AttilaTheFun/open_router_cli "$OPENROUTER_REF" && git checkout -q FETCH_HEAD \
 && swift build -c release --product openrouter \
 && install -m 755 "$(swift build -c release --show-bin-path)/openrouter" /usr/local/bin/openrouter

# Visor's own server and the agents' host (visor-server, visor-agent-host),
# for a container that runs a Visor server of its own (docs/co-tenancy.md),
# built from the commit the image is published for (VISOR_REF: CI's, else
# main) in a stage of their own; only the two programs come over.
FROM docker.io/library/swift:6.4.0-noble AS visor
ARG VISOR_REF=main
RUN git init -q /src && cd /src \
 && git fetch -q --depth 1 https://github.com/AttilaTheFun/visor "$VISOR_REF" && git checkout -q FETCH_HEAD \
 && swift build -c release --product visor-server \
 && swift build -c release --product visor-agent-host \
 && install -m 755 "$(swift build -c release --show-bin-path)/visor-server" "$(swift build -c release --show-bin-path)/visor-agent-host" /usr/local/bin/

FROM docker.io/library/swift:6.4.0-noble
# libnss3: headless Chromium's (blue's web checks, tools/ci/container_blue_web.sh).
# The repository the image is published from: GitHub's registry links the
# package to it, which lets the repository's own CI token push it.
LABEL org.opencontainers.image.source="https://github.com/AttilaTheFun/visor"
LABEL org.opencontainers.image.description="Visor's agent image: the Linux a session's agent runs in, in a container."
ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git openssh-client tmux python3 unzip zip less procps ripgrep bubblewrap \
      libxml2 libgcc-13-dev lld clang pkg-config \
      libsdl2-dev libsdl2-ttf-dev libcurl4-openssl-dev libgl-dev libegl-dev libglvnd-dev libsqlite3-dev libgtk-3-dev libwebkit2gtk-4.1-dev \
      libnss3 \
 && rm -rf /var/lib/apt/lists/*
# On arm64, x86_64 glibc beside the system's own: Google's Linux Android SDK
# and NDK tools are x86_64 programs, run under Rosetta (the container's
# lease asks for it).
RUN if [ "${TARGETARCH:-arm64}" = arm64 ]; then \
      dpkg --add-architecture amd64 \
   && sed -i 's/^Types: deb$/Types: deb\nArchitectures: arm64/' /etc/apt/sources.list.d/ubuntu.sources \
   && printf '%s\n' 'Types: deb' 'URIs: http://archive.ubuntu.com/ubuntu/' 'Suites: noble noble-updates' 'Components: main' 'Architectures: amd64' 'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' '' \
        'Types: deb' 'URIs: http://security.ubuntu.com/ubuntu/' 'Suites: noble-security' 'Components: main' 'Architectures: amd64' 'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' > /etc/apt/sources.list.d/ubuntu-amd64.sources \
   && apt-get update \
   && apt-get install -y --no-install-recommends libc6:amd64 libstdc++6:amd64 zlib1g:amd64 \
   && rm -rf /var/lib/apt/lists/*; \
    fi
# Isomer's Linux builds compile their C with clang.
ENV CC=clang CXX=clang++
# Node 22, from Node's own image.
COPY --from=docker.io/library/node:22-bookworm-slim /usr/local/bin/node /usr/local/bin/node
COPY --from=docker.io/library/node:22-bookworm-slim /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
# Bazel through bazelisk, which fetches the version a workspace asks for.
ARG BAZELISK_VERSION=v1.30.0
RUN case "${TARGETARCH:-arm64}" in \
      arm64) sum=b2bcc040c213b44586b121bda6d983c35df121b917c3a7a66fb16f2fa0df1a4f ;; \
      amd64) sum=a248ae2b2b62b5baebb748f6fba7203bff1a27e5d01b55399a8406744cb539e8 ;; \
      *) echo "no bazelisk for ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /usr/local/bin/bazelisk "https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-${TARGETARCH:-arm64}" \
 && echo "$sum  /usr/local/bin/bazelisk" | sha256sum -c - \
 && chmod 755 /usr/local/bin/bazelisk && ln -s bazelisk /usr/local/bin/bazel
# Bazel in a mounted repository: its output on the container's own disk (a
# Mac holds a file handle for every file a container opens through a
# mount, and one output tree there ran a Mac out of them), and none of its
# convenience links in the repository, where they would replace the Mac's
# own builds' links with ones to paths only the container has.
RUN printf '%s\n' 'startup --output_user_root=/var/cache/bazel' 'build --experimental_convenience_symlinks=ignore' > /etc/bazel.bazelrc
RUN npm install -g @anthropic-ai/claude-code @openai/codex && npm cache clean --force
COPY --from=openrouter /usr/local/bin/openrouter /usr/local/bin/openrouter
# The server finds the agents' host beside it.
COPY --from=visor /usr/local/bin/visor-server /usr/local/bin/visor-agent-host /usr/local/bin/
# The session's folder belongs to the Mac's user, not root: git works in it.
RUN git config --system --add safe.directory '*'
# Visor's tools (`visor`), which the server mounts here.
ENV PATH=/opt/visor:$PATH
# The container is the agent's sandbox: Claude Code skips its permission
# prompts though it runs as root.
ENV IS_SANDBOX=1
