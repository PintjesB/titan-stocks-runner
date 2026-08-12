#!/usr/bin/env bash
# Start the persistent Titan Stocks GitHub Actions listener.
#
# Architecture
# ============
#
# Three storage tiers cooperate at startup. Each tier is recreated or
# refreshed independently so a container restart never has to fetch a
# new registration token.
#
#   /opt/actions-runner         Image-owned immutable binary tree
#                              (e.g. ``run.sh``, ``config.sh``,
#                              ``runsvc.sh``).
#
#   /var/lib/titan-runner/state    Persistent volume. Holds the
#                              Actions runner ``.runner`` and
#                              ``.credentials*`` files.
#
#   /var/lib/titan-runner/runtime  Materialised tree built fresh on
#                              every container start by copying the
#                              immutable image tree and overlaying the
#                              persistent state. The listener reads
#                              its configuration from here and writes
#                              its logs here. A container recreation
#                              can discard the runtime completely
#                              without losing the GitHub identity.
#
#   /var/lib/titan-runner/work     Host bind mount used as GitHub's
#                              ``_work`` directory. The same absolute
#                              path exists on the Docker host so child
#                              service containers can publish their
#                              artefacts on the host filesystem.
#
#   /var/lib/titan-runner/browser  Persistent Playwright browser cache.
#
# On every start the script:
#
#   1. Refuses to run without a non-empty ``state/.runner`` and
#      ``state/.credentials``. The script never fetches a registration
#      token; the operator must run ``deploy.sh register`` once.
#   2. Grants the host Docker socket's GID to the runner user as a
#      *supplemental* group; the primary ``runner`` group is preserved.
#   3. Rebuilds the runtime tree from ``/opt/actions-runner`` and
#      overlays the persisted registration files onto it.
#   4. Launches ``run.sh`` directly via ``gosu`` with no runtime
#      flags. ``--disableupdate`` is set at registration and persists
#      in the ``.runner`` manifest.
#
# Environment variables
# =====================
#
#   RUNNER_STATE_DIR    Persistent state volume. Default
#                       ``/var/lib/titan-runner/state``.
#   RUNNER_RUNTIME_DIR  Disposable runtime tree. Default
#                       ``/var/lib/titan-runner/runtime``.
#   RUNNER_WORK_DIR     Host-visible ``_work`` directory. Default
#                       ``/var/lib/titan-runner/work``.
#   RUNNER_BROWSER_DIR  Persistent Playwright cache. Default
#                       ``/var/lib/titan-runner/browser``.
#   RUNNER_ROOT         Image-owned source tree. Default
#                       ``/opt/actions-runner``.
#
# Exit codes
# ==========
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
RUNNER_RUNTIME_DIR="${RUNNER_RUNTIME_DIR:-/var/lib/titan-runner/runtime}"
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

if [ ! -x "$RUNNER_ROOT/run.sh" ]; then
    fail "image-owned runner binaries missing from $RUNNER_ROOT; rebuild the image" 1
fi

# Re-apply the host Docker socket's GID to the runner user as a
# supplemental group on every start so a host GID change survives a
# container recreation. The primary ``runner`` group is preserved.
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

# Ensure the persistent directories exist and are owned by runner.
install -d -m 0750 -o runner -g runner \
    "$RUNNER_STATE_DIR" \
    "$RUNNER_RUNTIME_DIR" \
    "$RUNNER_WORK_DIR" \
    "$RUNNER_BROWSER_DIR"

# Rebuild the runtime tree from the immutable image tree. The runner
# reads ``.runner`` and ``.credentials*`` from ``$HOME`` at startup,
# so setting ``HOME=$RUNNER_RUNTIME_DIR`` makes the overlaid
# credentials resolve naturally.
log "materialising runtime tree at $RUNNER_RUNTIME_DIR"
rm -rf "$RUNNER_RUNTIME_DIR"
mkdir -p "$RUNNER_RUNTIME_DIR"
cp -a "$RUNNER_ROOT/." "$RUNNER_RUNTIME_DIR/"

# Overlay persisted registration files onto the runtime tree. The
# upstream tooling requires ``$HOME/.runner`` and
# ``$HOME/.credentials`` to exist.
cp "$RUNNER_STATE_DIR/.runner" "$RUNNER_RUNTIME_DIR/.runner"
cp "$RUNNER_STATE_DIR/.credentials" "$RUNNER_RUNTIME_DIR/.credentials"
if [ -f "$RUNNER_STATE_DIR/.credentials_rsaparams" ]; then
    cp "$RUNNER_STATE_DIR/.credentials_rsaparams" "$RUNNER_RUNTIME_DIR/.credentials_rsaparams"
fi

chown -R runner:runner "$RUNNER_RUNTIME_DIR"
chmod 0640 "$RUNNER_RUNTIME_DIR/.runner"
chmod 0600 "$RUNNER_RUNTIME_DIR/.credentials" \
          "$RUNNER_RUNTIME_DIR/.credentials_rsaparams" 2>/dev/null || true

# Materialise the Playwright cache link so downloaded browser
# binaries land in the persistent browser volume.
ln -sfn "$RUNNER_BROWSER_DIR" /home/runner/.cache/ms-playwright 2>/dev/null || true

log "launching persistent listener; foreground logs follow"
if ! env HOME="$RUNNER_RUNTIME_DIR" gosu runner \
        "$RUNNER_RUNTIME_DIR/run.sh"; then
    fail "listener exited non-zero" 4
fi
