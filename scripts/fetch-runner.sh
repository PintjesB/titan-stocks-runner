#!/usr/bin/env bash
# Fetch and verify the GitHub Actions runner tarball.
#
# This script runs at image build time. It downloads the upstream
# ``actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz`` archive,
# verifies it against the pinned ``RUNNER_SHA256``, and extracts it
# into ``/opt/actions-runner``. The persistent listener symlinks that
# directory into the runner user's home on first start.
#
# The script is intentionally minimal: no GitHub API calls, no
# self-update, no background polling. Updating the runner requires
# rebuilding the image with a refreshed ``RUNNER_VERSION`` and
# ``RUNNER_SHA256`` pair. Persistent runners register with
# ``--disableupdate`` so even a compromised in-container update attempt
# cannot swap the binary.
#
# Environment variables:
#
#   RUNNER_VERSION    The pinned Actions runner version (e.g. 2.336.0).
#   RUNNER_SHA256     The expected SHA-256 digest of the upstream tarball.
#   RUNNER_TARBALL    Override the download URL. Defaults to the
#                     canonical GitHub release artifact.
#   RUNNER_DEST       Override the extraction directory. Defaults to
#                     ``/opt/actions-runner``.
#
# Exit codes:
#
#   0  Tarball downloaded, digest verified, archive extracted.
#   1  Required environment variable is missing or empty.
#   2  Download failed.
#   3  Digest verification failed.
#   4  Extraction failed.
set -euo pipefail

: "${RUNNER_VERSION:?RUNNER_VERSION is required (e.g. 2.336.0)}"
: "${RUNNER_SHA256:?RUNNER_SHA256 is required (sha256 hex digest of the upstream tarball)}"

DEST="${RUNNER_DEST:-/opt/actions-runner}"
TARBALL_URL="${RUNNER_TARBALL:-https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz}"
TMP_DIR="$(mktemp -d -t actions-runner.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

archive="$TMP_DIR/actions-runner.tar.gz"

log() { printf '[fetch-runner] %s\n' "$*"; }
fail() { log "ERROR: $*" >&2; exit "${2:-1}"; }

log "downloading $TARBALL_URL"
if ! curl --fail --silent --show-error --location --retry 3 --retry-delay 5 \
        --output "$archive" "$TARBALL_URL"; then
    fail "download failed" 2
fi

log "verifying sha256 digest"
computed="$(sha256sum "$archive" | awk '{print $1}')"
expected="${RUNNER_SHA256#sha256:}"
if [ "$computed" != "$expected" ]; then
    log "digest mismatch" >&2
    log "  expected: $expected" >&2
    log "  actual:   $computed" >&2
    fail "refusing to install upstream tarball" 3
fi

log "extracting to $DEST"
mkdir -p "$DEST"
if ! tar -xzf "$archive" -C "$DEST"; then
    fail "extraction failed" 4
fi

log "installed runner version: ${RUNNER_VERSION}"
