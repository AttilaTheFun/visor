# Visor's agent image for oss: Claude Code and Codex, with Node (which also
# runs visor_mcp.js), git, ssh, tmux, Python, Bazel (bazelisk) and oss's CLI
# (`oss mcp` and `oss machine …` lease machines with the container's own
# token). The Visor server makes its sessions' containers from it (its
# `oss image` setting, visor-agent by default). Build it on the oss server,
# again to take newer agents:
#   oss image build container visor-agent --dockerfile=tools/oss/visor-agent/Dockerfile
# Its sign-ins live on the oss server, never in the image, and only
# containers made from it get them:
#   ~/.config/oss/images/visor-agent.env    CLAUDE_CODE_OAUTH_TOKEN=… (`claude setup-token`)
#   ~/.config/oss/images/visor-agent.home/  .codex/auth.json (Codex's ChatGPT sign-in), settings

# oss's CLI for Linux, its Swift standard library linked in: the release
# the Visor server's client is (Package.swift).
FROM docker.io/library/swift:6.2-noble AS oss
ARG OSS_REF=v0.1.0
RUN git clone --depth 1 --branch "${OSS_REF}" https://github.com/AttilaTheFun/oss /src \
 && cd /src && swift build -c release --static-swift-stdlib --product oss && cp .build/release/oss /oss

FROM docker.io/library/ubuntu:24.04
ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git openssh-client tmux python3 unzip less procps ripgrep \
 && rm -rf /var/lib/apt/lists/*
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
RUN npm install -g @anthropic-ai/claude-code @openai/codex && npm cache clean --force
COPY --from=oss /oss /usr/local/bin/oss
# The container is the agent's sandbox: Claude Code skips its permission
# prompts though it runs as root.
ENV IS_SANDBOX=1
