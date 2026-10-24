# Visor's agent image: the Linux a session's agent runs in when it runs in a
# container on its Visor server's Mac (Apple's container). Claude Code and
# Codex, with Node (which also runs Visor's MCP script and `visor`), Swift
# 6.4.0 (which Bazel's Swift package rules ask for on Linux; the same as
# rules_applecross builds Apple apps with), git, ssh, tmux, Python, Bazel
# (bazelisk), and what Isomer's Linux apps link (SDL, GL, GTK, WebKitGTK). The Visor server makes each session's
# container from it (its `containers image` setting, visor-agent by
# default). Build it on each Mac whose Visor server runs containers, again
# to take newer agents:
#   container build --tag visor-agent --file tools/containers/visor-agent/Dockerfile tools/containers/visor-agent
# The container sees the session's folder at the same path, Xcode at
# /Applications/Xcode.app (read-only), and Visor's tools at /opt/visor
# (read-only, from the server). Its sign-ins live with the Visor server,
# never in the image (ContainerSignIns):
#   <Visor's data>/containers/agent.env   CLAUDE_CODE_OAUTH_TOKEN=… (`claude setup-token`)
#   <Visor's data>/containers/home/       .codex/auth.json (Codex's ChatGPT sign-in), copied in

FROM docker.io/library/swift:6.4.0-noble
ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git openssh-client tmux python3 unzip zip less procps ripgrep bubblewrap \
      libxml2 libgcc-13-dev lld clang pkg-config \
      libsdl2-dev libsdl2-ttf-dev libcurl4-openssl-dev libgl-dev libegl-dev libglvnd-dev libsqlite3-dev libgtk-3-dev libwebkit2gtk-4.1-dev \
 && rm -rf /var/lib/apt/lists/*
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
# The session's folder belongs to the Mac's user, not root: git works in it.
RUN git config --system --add safe.directory '*'
# Visor's tools (`visor`), which the server mounts here.
ENV PATH=/opt/visor:$PATH
# The container is the agent's sandbox: Claude Code skips its permission
# prompts though it runs as root.
ENV IS_SANDBOX=1
