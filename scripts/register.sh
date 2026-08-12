#!/usr/bin/env bash
# Register the persistent Titan Stocks runner against GitHub.
#
# This script is the one-shot lifecycle phase that materialises the
# runner's Actions credentials inside the ``state`` volume. It runs
# once during deployment, terminates, and never listens for jobs.
# The companion ``start-runner`` entrypoint takes over afterwards.
#
# Behaviour:
#
#   * Reads the short-lived registration token from
#     ``RUNNER_TOKEN_FILE`` (a 0600 file mounted read-only into the
#     container). The token is consumed once and never persisted.
#   * Registers as a *persistent* listener (``--disableupdate``,
#     no ``--ephemeral``, no ``--once``). Updates only happen through a
#     tested image release.
#   * Re-aligns the runner user's *supplemental* groups with the host
#     Docker socket's GID without changing the primary ``runner``
#     group, so ``docker`` commands resolve without sudo.
#   * Materialises the upstream ``actions-runner`` checkout as a
#     symlink to ``RUNNER_ROOT`` (``/opt/actions-runner``) so the image
#     owns the binary while the state volume owns credentials.
#   * Verifies the Actions runner version installed by the image
#     matches the version the operator asked GitHub to register against.
#   * Writes ``.runner``, ``.credentials``, and a sanitised
#     diagnostics bundle into ``RUNNER_STATE_DIR`` (default
#     ``/var/lib/titan-runner/state``) so the listener container can
#     reuse them on every subsequent start.
#
# Required environment variables:
#
#   REPO_URL              The repository clone URL the runner targets
#                         (e.g. ``https://github.com/PintjesB/titan-stocks``).
#   RUNNER_NAME           The runner's display name. Defaults to
#                         ``titan-ci-<hostname>`` so duplicates are
#                         obvious in the GitHub UI.
#   RUNNER_LABELS         Comma-separated capability labels. Defaults
#                         to ``self-hosted,linux,ARM64,titan-ci``.
#   RUNNER_TOKEN_FILE     Path to a 0600 file containing a short-lived
#                         registration token.
#   RUNNER_STATE_DIR      Override the credential persistence
#                         directory. Defaults to
#                         ``/var/lib/titan-runner/state``.
#   RUNNER_WORK_DIR       Override the Actions runner ``_work``
#                         directory. Defaults to
#                         ``/var/lib/titan-runner/work``.
#   RUNNER_BROWSER_DIR    Override the Playwright cache mount.
#                         Defaults to ``/var/lib/titan-runner/browser``.
#   RUNNER_ROOT           Override the image-owned runner checkout.
#                         Defaults to ``/opt/actions-runner``.
#
# Exit codes:
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
RUNNER_WORK_DIR="${RUNNER_WORK_DIR:-/var/lib/titan-runner/work}"
RUNNER_BROWSER_DIR="${RUNNER_BROWSER_DIR:-/var/lib/titan-runner/browser}"
RUNNER_ROOT="${RUNNER_ROOT:-/opt/actions-runner}"

log "runner_name=$RUNNER_NAME labels=$RUNNER_LABELS"
log "state_dir=$RUNNER_STATE_DIR work_dir=$RUNNER_WORK_DIR browser_dir=$RUNNER_BROWSER_DIR"

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

# Verify the image-owned runner binaries are present and match the
# version we are about to register against GitHub. A drift between the
# binary GitHub sees and the binary that actually runs jobs is a
# reliability hazard and a silent supply-chain window.
if [ ! -x "$RUNNER_ROOT/run.sh" ]; then
    fail "runner binaries missing from $RUNNER_ROOT; rebuild the image" 1
fi

# Materialise the runner checkout. The image owns the binary tree;
# the state volume owns the credentials. We bind ``_diag`` and
# ``_data`` directories alongside the credentials so the listener can
# start without a fresh checkout.
install -d -m 0750 -o runner -g runner "$RUNNER_STATE_DIR"
install -d -m 0750 -o runner -g runner "$RUNNER_WORK_DIR/_work" "$RUNNER_WORK_DIR/_diag" "$RUNNER_WORK_DIR/_data"
install -d -m 0750 -o runner -g runner "$RUNNER_BROWSER_DIR"

# Map the bind-mounted Docker socket's group onto the runner user as a
# supplemental group; the runner user's *primary* group remains
# ``runner`` so its permissions are unchanged for non-Docker work.
DOCKER_SOCKET="${DOCKER_SOCKET:-/var/run/docker.sock}"
if [ -S "$DOCKER_SOCKET" ]; then
    host_docker_gid="$(stat -c '%g' "$DOCKER_SOCKET" 2>/dev/null || stat -f '%g' "$DOCKER_SOCKET" 2>/dev/null || echo "")"
    if [ -n "$host_docker_gid" ]; then
        current_gid="$(getent group "$host_docker_gid" | awk -F: '{print $1}' || true)"
        if [ -z "$current_gid" ]; then
            groupadd --gid "$host_docker_gid" docker-host || fail "could not create host docker group" 1
        fi
        if ! id -Gn runner | tr ' ' '\n' | grep -qx "$(getent group "$host_docker_gid" | awk -F: '{print $1}')"; then
            log "adding runner user to supplemental group GID=$host_docker_gid"
            usermod -a -G "$host_docker_gid" runner
        fi
    fi
else
    log "warning: $DOCKER_SOCKET is not a socket; Docker CLI calls will fail inside the runner"
fi

# Reset any credentials in the state volume; we register fresh each time.
rm -f "$RUNNER_STATE_DIR"/.runner \
      "$RUNNER_STATE_DIR"/.credentials \
      "$RUNNER_STATE_DIR"/.credentials_rsaparams \
      "$RUNNER_STATE_DIR"/.runner_pkey

# Hand the upstream config script the state directory as $HOME so the
# resulting ``.runner`` and ``.credentials*`` land inside the
# persisted volume.
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
if ! env HOME="$RUNNER_STATE_DIR" gosu runner \
        "$RUNNER_ROOT/config.sh" "${register_args[@]}"; then
    fail "runner registration failed" 3
fi
unset token

# Mirror the persisted credentials into a sanitised diagnostics bundle.
# The bundle contains the runner name, label set, and capability
# summaries but never the credentials themselves or the registration
# token. It is published alongside the credentials so a triage session
# can verify which registration is mounted.
{
    printf '# titan-runner diagnostics\n'
    printf 'registered_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'repo_url=%s\n' "$REPO_URL"
    printf 'runner_name=%s\n' "$RUNNER_NAME"
    printf 'runner_labels=%s\n' "$RUNNER_LABELS"
    printf 'runner_root=%s\n' "$RUNNER_ROOT"
    printf 'state_dir=%s\n' "$RUNNER_STATE_DIR"
    printf 'work_dir=%s\n' "$RUNNER_WORK_DIR"
    printf 'browser_dir=%s\n' "$RUNNER_BROWSER_DIR"
    printf 'runner_version=%s\n' "$RUNNER_VERSION"
} > "$RUNNER_STATE_DIR/diagnostics.txt"
chown runner:runner "$RUNNER_STATE_DIR/diagnostics.txt"
chmod 0640 "$RUNNER_STATE_DIR/diagnostics.txt"

# Tighten credentials so the listener starts with the same access the
# registration just produced.
chown -R runner:runner "$RUNNER_STATE_DIR"
chmod 0600 "$RUNNER_STATE_DIR"/.credentials "$RUNNER_STATE_DIR"/.credentials_rsaparams 2>/dev/null || true
chmod 0644 "$RUNNER_STATE_DIR"/.runner 2>/dev/null || true

log "registration complete; credentials persisted to $RUNNER_STATE_DIR"
