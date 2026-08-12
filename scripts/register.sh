#!/usr/bin/env bash
# Register the persistent Titan Stocks runner against GitHub.
#
# Architecture
# ============
#
# Registration is the one phase that requires a fresh registration
# token. It is run by ``deploy.sh register`` through a one-shot
# sidecar that mounts the token file read-only. The script:
#
#   1. Validates the token file (0600 mode, non-empty contents).
#   2. Rebuilds a temporary runtime tree at
#      ``$RUNNER_RUNTIME_DIR`` from the image-owned
#      ``/opt/actions-runner`` tree.
#   3. Invokes ``config.sh --replace --disableupdate`` from the
#      runtime tree so the resulting ``.runner``,
#      ``.credentials``, and ``.credentials_rsaparams`` files land
#      inside it.
#   4. Copies the resulting registration files into the persistent
#      ``$RUNNER_STATE_DIR`` directory with strict permissions
#      owned by the ``runner`` user. The token is consumed in
#      memory and discarded.
#   5. Cleans up the runtime tree before exiting so the subsequent
#      ``start-runner`` invocation rebuilds it from image + state.
#
# The script never deletes an existing ``$RUNNER_STATE_DIR`` before
# writing; ``config.sh --replace`` is the only destructive step and
# GitHub is the source of truth for credential replacement.
#
# Environment variables
# =====================
#
#   REPO_URL              Repository clone URL the runner targets
#                         (e.g. ``https://github.com/owner/repo``).
#   RUNNER_NAME           Display name. Defaults to
#                         ``titan-ci-<hostname>``.
#   RUNNER_LABELS         Comma-separated capability labels.
#                         Defaults to
#                         ``self-hosted,linux,ARM64,titan-ci``.
#   RUNNER_TOKEN_FILE     Path to a 0600 file containing the
#                         short-lived registration token.
#   RUNNER_STATE_DIR      Persistent state directory. Defaults to
#                         ``/var/lib/titan-runner/state``.
#   RUNNER_RUNTIME_DIR    Disposable runtime tree used during
#                         registration. Defaults to
#                         ``/var/lib/titan-runner/runtime``.
#   RUNNER_WORK_DIR       GitHub ``_work`` directory. Defaults to
#                         ``/var/lib/titan-runner/work``.
#   RUNNER_BROWSER_DIR    Playwright cache directory. Defaults to
#                         ``/var/lib/titan-runner/browser``.
#   RUNNER_ROOT           Image-owned runner tree. Defaults to
#                         ``/opt/actions-runner``.
#
# Exit codes
# ==========
#
#   0  Runner registered and credentials persisted.
#   1  Required configuration missing or invalid.
#   2  Registration token could not be obtained.
#   3  Runner configuration failed.
set -euo pipefail

log() { printf '[register] %s\n' "$*"; }
fail() { log "ERROR: $*"; exit "${2:-1}"; }

if [ "$(id -u)" -ne 0 ]; then
    fail "register must run as root (the entrypoint sets up the runner user)" 1
fi

: "${REPO_URL:?REPO_URL is required (e.g. https://github.com/owner/repo)}"
: "${RUNNER_TOKEN_FILE:?RUNNER_TOKEN_FILE is required (path to a 0600 token file)}"

RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,ARM64,titan-ci}"
RUNNER_NAME="${RUNNER_NAME:-titan-ci-$(hostname)}"
RUNNER_STATE_DIR="${RUNNER_STATE_DIR:-/var/lib/titan-runner/state}"
RUNNER_RUNTIME_DIR="${RUNNER_RUNTIME_DIR:-/var/lib/titan-runner/runtime}"
RUNNER_WORK_DIR="${RUNNER_WORK_DIR:-/var/lib/titan-runner/work}"
RUNNER_BROWSER_DIR="${RUNNER_BROWSER_DIR:-/var/lib/titan-runner/browser}"
RUNNER_ROOT="${RUNNER_ROOT:-/opt/actions-runner}"

log "runner_name=$RUNNER_NAME labels=$RUNNER_LABELS"
log "state_dir=$RUNNER_STATE_DIR runtime_dir=$RUNNER_RUNTIME_DIR work_dir=$RUNNER_WORK_DIR"

# Validate the token file. The deployment binds it read-only with a
# 0600 mode; the script refuses to fall back to anything else.
if [ ! -f "$RUNNER_TOKEN_FILE" ]; then
    fail "RUNNER_TOKEN_FILE=$RUNNER_TOKEN_FILE does not exist" 2
fi
token_mode="$(stat -c '%a' "$RUNNER_TOKEN_FILE" 2>/dev/null || stat -f '%Lp' "$RUNNER_TOKEN_FILE" 2>/dev/null || echo unknown)"
case "$token_mode" in
    600|400) ;;
    *) fail "RUNNER_TOKEN_FILE must be mode 0400 or 0600 (got 0$token_mode)" 2 ;;
esac
token="$(cat "$RUNNER_TOKEN_FILE")"
if [ -z "$token" ]; then
    fail "RUNNER_TOKEN_FILE is empty" 2
fi
trap 'unset token' EXIT

# Verify the image-owned runner binaries are present.
if [ ! -x "$RUNNER_ROOT/config.sh" ]; then
    fail "runner binaries missing from $RUNNER_ROOT; rebuild the image" 1
fi

# Ensure the persistent directories exist with the documented
# ownership and permissions before touching anything.
install -d -m 0750 -o runner -g runner \
    "$RUNNER_STATE_DIR" \
    "$RUNNER_RUNTIME_DIR" \
    "$RUNNER_WORK_DIR" \
    "$RUNNER_BROWSER_DIR"

# Rebuild the runtime tree from the image-owned source tree. Writing
# into the runtime tree (instead of running ``config.sh`` from
# ``/opt/actions-runner`` directly) keeps the image immutable.
log "materialising runtime tree at $RUNNER_RUNTIME_DIR"
rm -rf "$RUNNER_RUNTIME_DIR"
mkdir -p "$RUNNER_RUNTIME_DIR"
cp -a "$RUNNER_ROOT/." "$RUNNER_RUNTIME_DIR/"
chown -R runner:runner "$RUNNER_RUNTIME_DIR"

# Register the runner. ``config.sh --replace`` removes an existing
# GitHub registration of the same name; ``--disableupdate`` makes the
# persisted ``.runner`` refuse subsequent in-container updates.
log "registering persistent runner against $REPO_URL"
register_args=(
    --unattended
    --replace
    --disableupdate
    --url "$REPO_URL"
    --token "$token"
    --name "$RUNNER_NAME"
    --labels "$RUNNER_LABELS"
    --work "$RUNNER_WORK_DIR"
)
if ! env HOME="$RUNNER_RUNTIME_DIR" gosu runner \
        "$RUNNER_RUNTIME_DIR/config.sh" "${register_args[@]}"; then
    fail "runner registration failed" 3
fi
unset token

# Copy the mutable registration files into the persistent state
# directory. ``start-runner`` overlays them onto a freshly-built
# runtime tree on every container start.
for fname in .runner .credentials .credentials_rsaparams .runner_pkey; do
    if [ -f "$RUNNER_RUNTIME_DIR/$fname" ]; then
        cp "$RUNNER_RUNTIME_DIR/$fname" "$RUNNER_STATE_DIR/$fname"
    fi
done

chown -R runner:runner "$RUNNER_STATE_DIR"
chmod 0640 "$RUNNER_STATE_DIR/.runner" 2>/dev/null || true
chmod 0600 "$RUNNER_STATE_DIR"/.credentials* 2>/dev/null || true

# Save a sanitised diagnostics summary alongside the credentials so
# deployment audits can confirm which repository and label set is
# registered without exposing the credentials themselves.
{
    printf '# titan-runner diagnostics\n'
    printf 'registered_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'repo_url=%s\n' "$REPO_URL"
    printf 'runner_name=%s\n' "$RUNNER_NAME"
    printf 'runner_labels=%s\n' "$RUNNER_LABELS"
    printf 'runner_root=%s\n' "$RUNNER_ROOT"
    printf 'state_dir=%s\n' "$RUNNER_STATE_DIR"
    printf 'runtime_dir=%s\n' "$RUNNER_RUNTIME_DIR"
    printf 'work_dir=%s\n' "$RUNNER_WORK_DIR"
    printf 'browser_dir=%s\n' "$RUNNER_BROWSER_DIR"
    printf 'runner_version=%s\n' "${RUNNER_VERSION:-2.336.0}"
} > "$RUNNER_STATE_DIR/diagnostics.txt"
chown runner:runner "$RUNNER_STATE_DIR/diagnostics.txt"
chmod 0640 "$RUNNER_STATE_DIR/diagnostics.txt"

# Discard the runtime tree; the persistent state is the only thing
# the next listener start needs.
rm -rf "$RUNNER_RUNTIME_DIR"

log "registration complete; credentials persisted to $RUNNER_STATE_DIR"
