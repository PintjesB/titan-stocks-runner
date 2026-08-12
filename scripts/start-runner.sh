#!/usr/bin/env bash
# Start the persistent Titan Stocks GitHub Actions listener.
#
# This script is the long-running entrypoint. It assumes the
# ``register`` phase has already populated the credentials inside
# ``RUNNER_STATE_DIR`` and refuses to start without them. Updating the
# runner binary requires a fresh image release; the listener registers
# with ``--disableupdate`` so even a compromised in-container update
# attempt cannot swap the binary.
#
# Responsibilities:
#
#   1. Validate the persisted credentials. The runner never has a way
#      to fetch a new registration token at runtime; a missing or
#      malformed ``.credentials`` file aborts startup so the host is
#      alerted instead of looping silently.
#   2. Re-align the runner user's *supplemental* groups with the bind-
#      mounted Docker socket's GID. The primary ``runner`` group is
#      preserved; only the supplemental list is touched.
#   3. Materialise the image-owned ``/opt/actions-runner`` checkout as
#      a symlink inside the state volume so the upstream ``run.sh``
#      finds its sibling files.
#   4. Execute the upstream ``run.sh --start`` listener continuously
#      with ``--disableupdate``. The container stays up across job
#      boundaries so the registration token does not need to be
#      re-issued.
#
# Required environment variables (inherited from the registration
# phase):
#
#   RUNNER_NAME           Display name used at registration.
#   RUNNER_LABELS         Comma-separated capability labels.
#   RUNNER_STATE_DIR      Credential persistence directory.
#                         Defaults to ``/var/lib/titan-runner/state``.
#   RUNNER_WORK_DIR       ``_work`` workspace directory.
#                         Defaults to ``/var/lib/titan-runner/work``.
#   RUNNER_BROWSER_DIR    Playwright cache directory.
#                         Defaults to ``/var/lib/titan-runner/browser``.
#   RUNNER_ROOT           Override the image-owned checkout.
#                         Defaults to ``/opt/actions-runner``.
#
# Exit codes:
#
#   0  Listener exited cleanly.
#   1  Required configuration missing or invalid.
#   4  Listener exited non-zero.
set -euo pipefail

log() { printf '[start-runner] %s\n' "$*"; }
fail() { log "ERROR: $*"; exit "${2:-1}"; }

if [ "$(id -u)" -ne 0 ]; then
    fail "start-runner must run as root (the entrypoint sets up the runner user)" 1
fi

RUNNER_STATE_DIR="${RUNNER_STATE_DIR:-/var/lib/titan-runner/state}"
RUNNER_WORK_DIR="${RUNNER_WORK_DIR:-/var/lib/titan-runner/work}"
RUNNER_BROWSER_DIR="${RUNNER_BROWSER_DIR:-/var/lib/titan-runner/browser}"
RUNNER_ROOT="${RUNNER_ROOT:-/opt/actions-runner}"

# Refuse to start without configured state. A fresh container without
# credentials would otherwise loop forever attempting to fetch a
# non-existent registration token.
for path in \
    "$RUNNER_STATE_DIR/.runner" \
    "$RUNNER_STATE_DIR/.credentials"; do
    if [ ! -s "$path" ]; then
        fail "missing persisted credential file: $path. Run register first." 1
    fi
done

# Re-apply the host Docker socket's group to the runner user as a
# supplemental group on every start so a host GID change survives a
# container recreation.
DOCKER_SOCKET="${DOCKER_SOCKET:-/var/run/docker.sock}"
if [ -S "$DOCKER_SOCKET" ]; then
    host_docker_gid="$(stat -c '%g' "$DOCKER_SOCKET" 2>/dev/null || stat -f '%g' "$DOCKER_SOCKET" 2>/dev/null || echo "")"
    if [ -n "$host_docker_gid" ]; then
        if ! getent group "$host_docker_gid" >/dev/null 2>&1; then
            groupadd --gid "$host_docker_gid" docker-host || fail "could not create host docker group" 1
        fi
        group_name="$(getent group "$host_docker_gid" | awk -F: '{print $1}')"
        if [ -n "$group_name" ] && ! id -Gn runner | tr ' ' '\n' | grep -qx "$group_name"; then
            log "adding runner user to supplemental group GID=$host_docker_gid"
            usermod -a -G "$host_docker_gid" runner
        fi
    fi
else
    log "warning: $DOCKER_SOCKET is not a socket; Docker CLI calls will fail inside the runner"
fi

# Re-link the image-owned checkout into the runner user's home. The
# image stages the binary tree in ``RUNNER_ROOT``; the symlink keeps
# upstream ``run.sh`` happy without re-extracting the tarball.
RUNNER_HOME="/home/runner"
RUNNER_CHECKOUT="$RUNNER_HOME/actions-runner"
install -d -m 0755 -o runner -g runner "$RUNNER_HOME"
if [ ! -e "$RUNNER_CHECKOUT/run.sh" ]; then
    ln -sfn "$RUNNER_ROOT" "$RUNNER_CHECKOUT"
    chown -h runner:runner "$RUNNER_CHECKOUT"
fi

# Materialise the Playwright cache directory the listener shares with
# the registration phase so jobs download browser binaries exactly
# once.
install -d -m 0755 -o runner -g runner "$RUNNER_BROWSER_DIR"
ln -sfn "$RUNNER_BROWSER_DIR" "$RUNNER_HOME/.cache/ms-playwright" 2>/dev/null || true

log "launching persistent listener; foreground logs follow"
exec_args=(
    "$RUNNER_ROOT/run.sh"
    --start
    --disableupdate
)

if ! env HOME="$RUNNER_STATE_DIR" gosu runner "${exec_args[@]}"; then
    fail "listener exited non-zero" 4
fi
