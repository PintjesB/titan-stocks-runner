# syntax=docker/dockerfile:1.7
#
# Titan Stocks self-hosted GitHub Actions runner image.
#
# This image powers the persistent ARM64 runner that executes every job
# from the private Titan Stocks repository. It carries a single
# short-lived registration token at start time, persists its
# Actions runner credentials in a dedicated state volume, and listens
# for jobs until it is redeployed.
#
# Build only on ARM64 hardware:
#
#   docker buildx build --platform linux/arm64 \
#     --tag ghcr.io/pintjesb/titan-stocks-runner:dev --load .
#
# Update procedure:
#
#   1. ``RUNNER_VERSION`` below must track the current GitHub-supported
#      ``v2.x`` line. GitHub ends runner support 30 days after a new
#      release; this image MUST be rebuilt before the cutoff.
#   2. ``RUNNER_SHA256`` is the SHA-256 of the upstream tarball
#      ``actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz`` pinned to
#      the immutable digest published by ``actions/runner``. Refresh
#      both values together; the lifecycle scripts verify the digest
#      before any job is allowed to register against GitHub.
#   3. ``PLAYWRIGHT_VERSION`` is consumed by the image's capability probe
#      only. Containerized Playwright application installs do not need
#      to match.
#
# The image runs as a non-root ``runner`` user. The Docker socket is
# bind-mounted read/write by the persistent Compose configuration and
# the host socket's group ID is mapped onto the runner user at start
# time so the docker CLI can reach the daemon without sudo.

ARG UBUNTU_BASE_DIGEST=sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea
FROM ubuntu:24.04@${UBUNTU_BASE_DIGEST} AS base

ARG DEBIAN_FRONTEND=noninteractive
ARG RUNNER_VERSION=2.336.0
ARG RUNNER_SHA256=58b758e420b87093fbd4bfddd368074960053e2f1388f01848c82624b90f27d1
ARG PLAYWRIGHT_VERSION=1.61.1

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    RUNNER_VERSION=${RUNNER_VERSION} \
    RUNNER_SHA256=${RUNNER_SHA256} \
    PLAYWRIGHT_VERSION=${PLAYWRIGHT_VERSION} \
    # The image installs Node via NodeSource; declaring the major here
    # keeps the Docker layer cache stable across rebuilds that only
    # refresh the runner or Playwright versions.
    NODE_MAJOR=24 \
    # The runner binaries live in this image-owned directory. The
    # container entrypoint does not need to redownload them.
    RUNNER_ROOT=/opt/actions-runner

# Refresh the base image's package index, install the documented CI
# toolchain, and create the non-root ``runner`` user. The system
# packages mirror the canonical ``actions/runner`` container plus the
# Playwright Chromium runtime dependency set. ``tini`` provides PID 1
# for the ``init: true`` Compose contract so the runner child
# processes get proper signal forwarding and zombie reaping.
#
# ``ca-certificates`` ships the Mozilla CA bundle so GitHub API calls
# and Playwright browser downloads all use a trusted store. ``gnupg``
# is required for the NodeSource apt keyring pattern; ``jq`` powers
# the runner registration token exchange. ``gosu`` is required for the
# persistent listener to drop from the root entrypoint to the
# unprivileged ``runner`` user.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        git \
        bash \
        coreutils \
        tar \
        gzip \
        xz-utils \
        unzip \
        zip \
        file \
        gnupg \
        jq \
        tini \
        gosu \
        # Docker CLI + Compose v2 plugin + Buildx (CLI plugins ship
        # under /usr/local/lib/docker/cli-plugins so the docker CLI
        # discovers them automatically).
        docker.io \
        docker-compose-v2 \
        docker-buildx \
        # PostgreSQL client tooling used by the capability probe and
        # by downstream test stacks.
        postgresql-client \
        # ShellCheck for the workflow ``run_gate`` and visual Playwright
        # jobs.
        shellcheck \
        # Playwright Chromium system dependencies. The list matches the
        # Ubuntu 24.04 requirements documented by the Playwright
        # project; we install them at image build time so workflow jobs
        # never need ``--with-deps`` and never need sudo.
        libasound2t64 \
        libatk-bridge2.0-0t64 \
        libatk1.0-0t64 \
        libcairo2 \
        libcups2t64 \
        libdbus-1-3 \
        libdrm2 \
        libgbm1 \
        libglib2.0-0t64 \
        libnspr4 \
        libnss3 \
        libpango-1.0-0 \
        libpangocairo-1.0-0 \
        libx11-6 \
        libxcb1 \
        libxcomposite1 \
        libxdamage1 \
        libxext6 \
        libxfixes3 \
        libxkbcommon0 \
        libxrandr2 \
 && rm -rf /var/lib/apt/lists/*

# Install Node.js 24.x via NodeSource. The ``setup-node`` action in the
# workflow reuses the same ``.nvmrc`` (24.18.0); the system install is
# the fallback that keeps the runner functional even if the GitHub-
# hosted action ever fails to fetch.
RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && node --version \
 && npm --version

# Install the GitHub CLI from the official apt repository. The CI host
# uses ``gh`` for the runner-smoke capability probe and for occasional
# diagnostic invocations against the API.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/* \
 && gh --version

# Install Python 3.12 from the deadsnakes PPA. The runner needs the
# interpreter for the ``setup-python`` action fallback and for the
# capability probe; application Python dependencies are still installed
# by the workflow from its own hash-locked requirements files.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3.12 python3.12-venv python3.12-dev \
 && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1 \
 && python3 --version \
 && rm -rf /var/lib/apt/lists/*

# Create the non-root ``runner`` user. ``RUNNER_UID`` matches the
# deployment's conventional 1001. The start-up script maps the bind-
# mounted Docker socket's group onto the runner user as a *supplemental*
# group; the runner user's *primary* group remains ``runner``.
#
# The home directory hosts the canonical Actions runner checkout, the
# ``_work`` job workspace, and the Playwright ``.cache`` for browser
# binaries. Persistent volumes overlay these directories in production.
RUN groupadd --system --gid 1001 runner \
 && useradd --system --uid 1001 --gid 1001 \
        --home-dir /home/runner \
        --shell /bin/bash \
        --comment "Titan Stocks CI runner" \
        runner \
 && mkdir -p /home/runner/.cache/ms-playwright \
             /home/runner/actions-runner \
             /home/runner/.local/bin \
             /var/lib/titan-runner/{state,work,browser} \
 && chown -R runner:runner /home/runner /var/lib/titan-runner \
 && chmod 0755 /home/runner \
 && chmod 0755 /var/lib/titan-runner/{state,work,browser}

# Pin the Actions runner tarball by SHA-256. The tarball is extracted
# into ``RUNNER_ROOT`` (default ``/opt/actions-runner``); the entrypoint
# symlinks that directory into ``$HOME/actions-runner`` on first start
# so the upstream ``run.sh`` finds its sibling files.
COPY --chown=root:root scripts/fetch-runner.sh /usr/local/bin/fetch-runner
RUN chmod 0755 /usr/local/bin/fetch-runner \
 && /usr/local/bin/fetch-runner

# Install a deterministic ``playwright-core`` dependency tree that the
# capability probe consumes at runtime. A committed ``package-lock.json``
# pins the resolved version so the image is reproducible without ever
# invoking ``npx`` at probe time. ``npx`` interprets its first positional
# argument as a binary to execute, not a package to install, so it
# cannot be used to "install playwright-core and then run node".
COPY scripts/probe-package.json /opt/titan-probe/package.json
COPY scripts/probe-package-lock.json /opt/titan-probe/package-lock.json
RUN cd /opt/titan-probe && npm ci --omit=dev --no-audit --no-fund \
 && npm cache clean --force

# Install Playwright system browsers as the runner user. The Chromium
# binary is reused for both Playwright application runs and the
# ``probe`` capability check. We install only the Chromium binary (the
# OS libraries were installed earlier in this Dockerfile) into the
# baked image cache, which ``start-runner`` seeds into the persistent
# browser volume on first start.
USER runner
WORKDIR /home/runner
ENV PLAYWRIGHT_BROWSERS_PATH=/home/runner/.cache/ms-playwright
RUN /opt/titan-probe/node_modules/.bin/playwright install chromium \
 && ls -1 /home/runner/.cache/ms-playwright

USER root

# Stage the runner lifecycle scripts. ``register`` reads the short-
# lived registration token from the bind-mounted ``$RUNNER_TOKEN_FILE``
# file and persists the resulting ``.runner`` and ``.credentials*``
# artifacts in the state volume. ``start-runner`` invokes the upstream
# ``run.sh`` listener as a persistent runner. ``probe`` exposes every
# documented capability for the smoke workflow.
COPY scripts/register.sh /usr/local/bin/register
COPY scripts/start-runner.sh /usr/local/bin/start-runner
COPY scripts/probe.sh /usr/local/bin/probe
COPY scripts/upstream-version.sh /usr/local/bin/upstream-version
RUN chmod 0755 /usr/local/bin/register \
                /usr/local/bin/start-runner \
                /usr/local/bin/probe \
                /usr/local/bin/upstream-version

# Document the expected labels so operators can spot misconfigured
# deployments at a glance. The labels are passed at registration time so
# an image rebuild is not required to retarget a temporary host.
#
# The image is intentionally published without an OCI license label.
# The repository's README states that publication does not grant any
# reuse rights and the project does not ship a ``LICENSE`` file.
LABEL org.opencontainers.image.title="titan-stocks-runner" \
      org.opencontainers.image.description="Persistent ARM64 GitHub Actions runner for Titan Stocks (capability-complete, no auto-update)" \
      org.opencontainers.image.source="https://github.com/PintjesB/titan-stocks-runner" \
      org.opencontainers.image.vendor="PintjesB"

# ``init: true`` enables ``tini`` as PID 1 so the runner's child
# processes receive clean signals and zombies are reaped. The default
# argument runs the persistent listener; ``register`` overrides the
# command at deployment time to perform the one-shot credential copy.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/start-runner"]
CMD []
