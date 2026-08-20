#!/usr/bin/env bash
# Compare the image's pinned Actions Runner version against upstream.
#
# This script runs from a scheduled workflow that does not own the
# self-hosted runner. The check ensures we are notified when GitHub
# publishes a new ``actions/runner`` release so a fresh
# ``titan-stocks-runner`` image can be published before GitHub ends
# support for the current version (30 days after a new release).
#
# The script can also be executed inside a running container to
# confirm the version it advertises matches the GitHub release.
set -euo pipefail

: "${RUNNER_VERSION:?RUNNER_VERSION is required (e.g. 2.336.0)}"

current="$RUNNER_VERSION"
latest="$(curl --fail --silent --show-error --max-time 15 \
        https://api.github.com/repos/actions/runner/releases/latest \
        | sed -n 's/.*"tag_name": "v\([^"]*\)".*/\1/p')"

if [ -z "$latest" ]; then
    printf 'upstream-version: cannot determine latest release\n' >&2
    exit 1
fi

if [ "$current" = "$latest" ]; then
    printf 'upstream-version: in sync (%s)\n' "$current"
    exit 0
fi

# Treat the current version as current if both the major and minor
# numbers match upstream's. Patch releases are normally not worth a
# rebuild on their own; major and minor releases are.
current_major_minor="$(printf '%s' "$current" | awk -F. '{print $1"."$2}')"
latest_major_minor="$(printf '%s' "$latest" | awk -F. '{print $1"."$2}')"

if [ "$current_major_minor" = "$latest_major_minor" ]; then
    printf 'upstream-version: in sync on major.minor (current=%s latest=%s)\n' "$current" "$latest"
    exit 0
fi

printf 'upstream-version: drift detected (current=%s latest=%s)\n' "$current" "$latest"
exit 2
