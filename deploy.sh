#!/usr/bin/env bash
# Local-only lifecycle helper for the persistent runner.
#
# This script is for the dedicated CI host. It does not start or stop
# any application stack; it only operates the ``docker-compose.yml``
# overlay. Operators run this directly on the CI host (or via SSH)
# so the runner is reproducible from a single pinned image digest.
#
# Usage:
#
#   deploy.sh build      Build the runner image (arm64).
#   deploy.sh probe      Run the capability probe on the image.
#   deploy.sh register   Register the runner against GitHub once,
#                        persist its credentials, and exit.
#   deploy.sh up         Start the persistent listener.
#   deploy.sh down       Stop the listener (state and work persist).
#   deploy.sh status     Show the runner's state.
#   deploy.sh logs       Tail the runner logs.
#
# Required environment:
#
#   TITAN_RUNNER_IMAGE        The pinned image digest to deploy
#                             (e.g. ``ghcr.io/pintjesb/titan-stocks-runner@sha256:...``).
#   TITAN_RUNNER_REPO_URL     The repository URL the runner targets.
#
# Optional environment:
#
#   TITAN_RUNNER_TOKEN_FILE   Path on the host to the 0600 token file.
#                             Default: ``/run/secrets/titan-runner-registration-token``.
#   TITAN_RUNNER_LOCK_FILE    Path to the lifecycle lock file.
#                             Default: ``/var/lock/titan-runner.lock``.
#
# Subcommands take an exclusive flock (``register``, ``up``,
# ``down``); ``status`` and ``logs`` run without it so operators can
# inspect the deployment while a long command runs in another shell.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"

# Architecture guard. The image is linux/arm64 only; refuse to
# operate on a host of any other architecture before any state is
# touched.
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    aarch64|arm64) ;;
    *)
        printf 'ERROR: titan-stocks-runner requires an ARM64 host (got %s)\n' "$HOST_ARCH" >&2
        exit 1
        ;;
esac

action="${1:-status}"
shift || true

LOCK_FILE="${TITAN_RUNNER_LOCK_FILE:-/var/lock/titan-runner.lock}"

require() {
    if [ -z "${!1:-}" ]; then
        printf 'Required environment variable %s is unset.\n' "$1" >&2
        exit 1
    fi
}

ensure_compose() {
    command -v docker >/dev/null 2>&1 || { echo "docker is required." >&2; exit 1; }
    docker compose version >/dev/null 2>&1 || { echo "docker compose v2 plugin is required." >&2; exit 1; }
}

ensure_token_file() {
    local file="${TITAN_RUNNER_TOKEN_FILE:-/run/secrets/titan-runner-registration-token}"
    if [ ! -f "$file" ]; then
        printf 'Registration token file %s does not exist.\n' "$file" >&2
        printf 'Generate one with:\n' >&2
        printf '  gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token | jq -r .token\n' >&2
        exit 1
    fi
    local mode
    mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || echo unknown)"
    case "$mode" in
        600|400) ;;
        *) printf 'Token file must be mode 0400 or 0600 (got 0%s).\n' "$mode" >&2; exit 1 ;;
    esac
}

# Take an exclusive flock on the lifecycle lock. ``status`` and
# ``logs`` skip this call so multiple operators can observe.
take_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        printf 'Another lifecycle command is already running.\n' >&2
        exit 1
    fi
}

release_lock() {
    flock -u 9 2>/dev/null || true
}

compose_env_args() {
    cat <<EOF
TITAN_RUNNER_IMAGE=${TITAN_RUNNER_IMAGE:-}
TITAN_RUNNER_REPO_URL=${TITAN_RUNNER_REPO_URL:-}
TITAN_RUNNER_NAME=${TITAN_RUNNER_NAME:-titan-ci}
TITAN_RUNNER_LABELS=${TITAN_RUNNER_LABELS:-self-hosted,linux,ARM64,titan-ci}
TITAN_RUNNER_STATE_DIR=${TITAN_RUNNER_STATE_DIR:-/var/lib/titan-runner/state}
TITAN_RUNNER_RUNTIME_DIR=${TITAN_RUNNER_RUNTIME_DIR:-/var/lib/titan-runner/runtime}
TITAN_RUNNER_WORK_DIR=${TITAN_RUNNER_WORK_DIR:-/var/lib/titan-runner/work}
TITAN_RUNNER_BROWSER_DIR=${TITAN_RUNNER_BROWSER_DIR:-/var/lib/titan-runner/browser}
TITAN_RUNNER_ROOT=${TITAN_RUNNER_ROOT:-/opt/actions-runner}
TITAN_RUNNER_TOKEN_FILE=${TITAN_RUNNER_TOKEN_FILE:-/run/secrets/titan-runner-registration-token}
EOF
}

state_volume_ready() {
    local volume="${TITAN_RUNNER_STATE_VOLUME:-titan-runner-state}"
    docker volume inspect "$volume" >/dev/null 2>&1 || return 1
    docker run --rm \
        -v "$volume":/state \
        busybox:1.36 \
        sh -c '[ -s /state/.runner ] && [ -s /state/.credentials ]' \
        >/dev/null 2>&1
}

listener_running() {
    docker ps -q --filter name=titan-runner 2>/dev/null
}

token_file_present() {
    local file="${TITAN_RUNNER_TOKEN_FILE:-/run/secrets/titan-runner-registration-token}"
    [ -f "$file" ] && echo present || echo absent
}

image_digest() {
    # Resolve the registry-served manifest digest for the configured
    # image reference. The ``Digest:`` line emitted by ``buildx
    # imagetools inspect`` is the manifest digest, not an arbitrary
    # configuration- or layer-level digest from the raw JSON. A
    # correctly-formatted digest is exactly ``sha256:`` followed by
    # 64 lowercase hex characters.
    local candidate
    candidate="$(docker buildx imagetools inspect "${TITAN_RUNNER_IMAGE:-}" 2>/dev/null \
        | awk '$1 == "Digest:" {print $2; exit}')"
    if [ "$candidate" = "sha256:$(printf '%s' "$candidate" | cut -d: -f2)" ] \
            && [ "$(printf '%s' "$candidate" | cut -d: -f2 | wc -c)" -eq 65 ]; then
        printf '%s\n' "$candidate"
    fi
}

case "$action" in
    build)
        ensure_compose
        require TITAN_RUNNER_IMAGE
        docker buildx build \
            --platform linux/arm64 \
            --load \
            -f "$ROOT_DIR/Dockerfile" \
            -t "$TITAN_RUNNER_IMAGE" \
            "$ROOT_DIR"
        ;;
    probe)
        ensure_compose
        require TITAN_RUNNER_IMAGE
        # The probe entrypoint must explicitly override the image's
        # listener entrypoint. Without ``--entrypoint`` the probe
        # invocation would be appended as an argument to
        # ``start-runner``.
        docker run --rm --platform linux/arm64 \
            --entrypoint /usr/local/bin/probe \
            --network host --ipc host \
            --security-opt no-new-privileges:true \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -e HOME=/tmp \
            "$TITAN_RUNNER_IMAGE"
        ;;
    register)
        ensure_compose
        take_lock
        trap release_lock EXIT
        require TITAN_RUNNER_IMAGE
        require TITAN_RUNNER_REPO_URL
        ensure_token_file
        listener_id="$(listener_running || true)"
        if [ -n "$listener_id" ]; then
            printf 'titan-runner listener is already running as %s.\n' "$listener_id" >&2
            printf 'Run ./deploy.sh down before re-registering.\n' >&2
            exit 1
        fi
        token_file="${TITAN_RUNNER_TOKEN_FILE:-/run/secrets/titan-runner-registration-token}"
        token_dir="$(dirname "$token_file")"
        docker run --rm --platform linux/arm64 \
            --entrypoint /usr/local/bin/register \
            --name titan-runner-register \
            --network host --ipc host \
            --security-opt no-new-privileges:true \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v titan-runner-state:/var/lib/titan-runner/state \
            -v "$token_dir":"$token_dir":ro \
            -e REPO_URL="${TITAN_RUNNER_REPO_URL}" \
            -e RUNNER_NAME="${TITAN_RUNNER_NAME:-titan-ci}" \
            -e RUNNER_LABELS="${TITAN_RUNNER_LABELS:-self-hosted,linux,ARM64,titan-ci}" \
            -e RUNNER_TOKEN_FILE="$token_file" \
            -e RUNNER_STATE_DIR=/var/lib/titan-runner/state \
            -e RUNNER_RUNTIME_DIR=/var/lib/titan-runner/runtime \
            -e RUNNER_WORK_DIR=/var/lib/titan-runner/work \
            -e RUNNER_BROWSER_DIR=/var/lib/titan-runner/browser \
            -e RUNNER_ROOT=/opt/actions-runner \
            -e RUNNER_VERSION=2.336.0 \
            "$TITAN_RUNNER_IMAGE"
        printf 'token file %s kept on the host; shred it when ready:\n' "$token_file"
        printf '  shred -u %s\n' "$token_file"
        ;;
    up)
        ensure_compose
        take_lock
        trap release_lock EXIT
        require TITAN_RUNNER_IMAGE
        require TITAN_RUNNER_REPO_URL
        if ! state_volume_ready; then
            printf 'State volume has no persisted credentials.\n' >&2
            printf 'Run ./deploy.sh register first.\n' >&2
            exit 1
        fi
        # The listener uses the image's default entrypoint
        # (``tini`` -> ``start-runner``). The registration token file
        # is intentionally NOT mounted on ``up`` so a future
        # re-registration cannot leak into the running listener.
        docker compose --env-file <(compose_env_args) -f "$COMPOSE_FILE" \
            up -d --force-recreate
        ;;
    down)
        ensure_compose
        take_lock
        trap release_lock EXIT
        docker compose -f "$COMPOSE_FILE" --env-file <(compose_env_args) down --remove-orphans
        ;;
    logs)
        ensure_compose
        docker compose -f "$COMPOSE_FILE" --env-file <(compose_env_args) \
            logs --tail=200 --follow "$@"
        ;;
    status)
        ensure_compose
        require TITAN_RUNNER_IMAGE
        echo "=== Runner image ==="
        printf 'reference : %s\n' "$TITAN_RUNNER_IMAGE"
        digest="$(image_digest || true)"
        if [ -n "$digest" ]; then
            printf 'digest    : %s\n' "$digest"
        else
            printf 'digest    : unresolved\n'
        fi
        echo "=== Listener container ==="
        cid="$(listener_running || true)"
        if [ -n "$cid" ]; then
            docker inspect --format '{{.State.Status}}  {{.Name}}' "$cid"
            listener_status="$(docker exec titan-runner pgrep -f 'Runner.Listener' >/dev/null 2>&1 \
                && echo running || echo not-running)"
            printf 'listener process : %s\n' "$listener_status"
            socket_status="$(docker exec titan-runner sh -c 'docker info >/dev/null 2>&1' \
                && echo accessible || echo not-accessible)"
            printf 'docker socket    : %s\n' "$socket_status"
            runner_state="$(docker exec titan-runner sh -c 'test -s /var/lib/titan-runner/state/.credentials && echo registered || echo unregistered')"
            printf 'registered       : %s\n' "$runner_state"
        else
            echo "not running"
        fi
        echo "=== State volume ==="
        if docker volume inspect titan-runner-state >/dev/null 2>&1; then
            docker run --rm \
                -v titan-runner-state:/state \
                busybox:1.36 \
                sh -c 'printf ".runner          : %s\n.credentials     : %s\n.credentials_rsa  : %s\n" \
                    "$(test -s /state/.runner && echo present || echo absent)" \
                    "$(test -s /state/.credentials && echo present || echo absent)" \
                    "$(test -s /state/.credentials_rsaparams && echo present || echo absent)"'
        else
            echo "volume not created"
        fi
        echo "=== Token file ==="
        printf '%s : %s\n' \
            "${TITAN_RUNNER_TOKEN_FILE:-/run/secrets/titan-runner-registration-token}" \
            "$(token_file_present)"
        ;;
    *)
        echo "Usage: deploy.sh {build|probe|register|up|down|status|logs}" >&2
        exit 2
        ;;
esac
