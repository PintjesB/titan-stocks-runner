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
#   deploy.sh probe      Run the capability probe without starting.
#   deploy.sh register   Register the runner against GitHub once,
#                        persist its credentials, and exit.
#   deploy.sh up         Start the persistent listener.
#   deploy.sh status     Show the runner's state.
#   deploy.sh logs       Tail the runner logs.
#   deploy.sh down       Stop the runner.
#
# Required environment:
#
#   TITAN_RUNNER_IMAGE        The pinned image digest to deploy
#                             (e.g. ``ghcr.io/pintjesb/titan-stocks-runner@sha256:...``).
#   TITAN_RUNNER_REPO_URL     The repository URL the runner targets.
#
# Optional environment:
#
#   TITAN_RUNNER_NAME         Display name for the runner.
#                             Default: ``titan-ci``.
#   TITAN_RUNNER_LABELS       Comma-separated capability labels.
#                             Default: ``self-hosted,linux,ARM64,titan-ci``.
#   TITAN_RUNNER_TOKEN_FILE   Path on the host to the 0600 token file.
#                             Default: ``/run/secrets/titan-runner-registration-token``.
#   TITAN_RUNNER_STATE_DIR    Override the credential volume mount.
#   TITAN_RUNNER_WORK_DIR     Override the workspace volume mount.
#   TITAN_RUNNER_BROWSER_DIR  Override the browser cache volume mount.
#   TITAN_RUNNER_ROOT         Override the image-owned checkout.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"

action="${1:-status}"
shift || true

require() {
    if [ -z "${!1:-}" ]; then
        echo "Required environment variable $1 is unset." >&2
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
        echo "Registration token file $file does not exist." >&2
        echo "Generate a token with:" >&2
        echo "  gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token | jq -r .token" >&2
        exit 1
    fi
    local mode
    mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || echo unknown)"
    case "$mode" in
        600|400) ;;
        *) echo "Registration token file must be mode 0400 or 0600 (got 0$mode)." >&2; exit 1 ;;
    esac
}

compose_env_args() {
    cat <<EOF
TITAN_RUNNER_IMAGE=${TITAN_RUNNER_IMAGE:-}
TITAN_RUNNER_REPO_URL=${TITAN_RUNNER_REPO_URL:-}
TITAN_RUNNER_NAME=${TITAN_RUNNER_NAME:-titan-ci}
TITAN_RUNNER_LABELS=${TITAN_RUNNER_LABELS:-self-hosted,linux,ARM64,titan-ci}
TITAN_RUNNER_TOKEN_FILE=${TITAN_RUNNER_TOKEN_FILE:-/run/secrets/titan-runner-registration-token}
TITAN_RUNNER_STATE_DIR=${TITAN_RUNNER_STATE_DIR:-/var/lib/titan-runner/state}
TITAN_RUNNER_WORK_DIR=${TITAN_RUNNER_WORK_DIR:-/var/lib/titan-runner/work}
TITAN_RUNNER_BROWSER_DIR=${TITAN_RUNNER_BROWSER_DIR:-/var/lib/titan-runner/browser}
TITAN_RUNNER_ROOT=${TITAN_RUNNER_ROOT:-/opt/actions-runner}
EOF
}

state_volume_ready() {
    local volume="${TITAN_RUNNER_STATE_VOLUME:-titan-runner-state}"
    docker volume inspect "$volume" >/dev/null 2>&1 || return 1
    local marker="${TITAN_RUNNER_STATE_DIR:-/var/lib/titan-runner/state}"
    if docker run --rm \
            -v "$volume":"$marker" \
            busybox:1.36 \
            test -s "$marker/.credentials"; then
        return 0
    fi
    return 1
}
# shellcheck disable=SC2317

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
        docker run --rm --platform linux/arm64 \
            --network host --ipc host \
            --security-opt no-new-privileges:true \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -e HOME=/tmp \
            "$TITAN_RUNNER_IMAGE" \
            /usr/local/bin/probe
        ;;
    register)
        ensure_compose
        require TITAN_RUNNER_IMAGE
        require TITAN_RUNNER_REPO_URL
        ensure_token_file
        # ``register`` is intentionally a one-shot sidecar that
        # consumes the token file and writes the credentials to the
        # shared state volume. The persistent listener is started by
        # ``deploy.sh up`` afterwards.
        docker run --rm --platform linux/arm64 \
            --name titan-runner-register \
            --network host --ipc host \
            --security-opt no-new-privileges:true \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v titan-runner-state:/var/lib/titan-runner/state \
            -v titan-runner-work:/var/lib/titan-runner/work \
            -v titan-runner-browser:/var/lib/titan-runner/browser \
            -v "$(dirname "${TITAN_RUNNER_TOKEN_FILE:-/run/secrets}")":"$(dirname "${TITAN_RUNNER_TOKEN_FILE:-/run/secrets}")":ro \
            -e REPO_URL="${TITAN_RUNNER_REPO_URL}" \
            -e RUNNER_NAME="${TITAN_RUNNER_NAME:-titan-ci}" \
            -e RUNNER_LABELS="${TITAN_RUNNER_LABELS:-self-hosted,linux,ARM64,titan-ci}" \
            -e RUNNER_TOKEN_FILE="${TITAN_RUNNER_TOKEN_FILE:-/run/secrets/titan-runner-registration-token}" \
            -e RUNNER_STATE_DIR=/var/lib/titan-runner/state \
            -e RUNNER_WORK_DIR=/var/lib/titan-runner/work \
            -e RUNNER_BROWSER_DIR=/var/lib/titan-runner/browser \
            -e RUNNER_ROOT=/opt/actions-runner \
            -e RUNNER_VERSION=2.336.0 \
            "$TITAN_RUNNER_IMAGE" \
            /usr/local/bin/register
        ;;
    up)
        ensure_compose
        require TITAN_RUNNER_IMAGE
        require TITAN_RUNNER_REPO_URL
        # The listener refuses to start without configured state.
        if ! state_volume_ready; then
            echo "state volume has no persisted credentials; run \`deploy.sh register\` first." >&2
            exit 1
        fi
        docker compose --env-file <(compose_env_args) -f "$COMPOSE_FILE" up -d --force-recreate
        ;;
    down)
        ensure_compose
        docker compose -f "$COMPOSE_FILE" --env-file <(compose_env_args) down --remove-orphans
        ;;
    logs)
        ensure_compose
        docker compose -f "$COMPOSE_FILE" --env-file <(compose_env_args) logs --tail=200 --follow "$@"
        ;;
    status)
        ensure_compose
        docker compose -f "$COMPOSE_FILE" --env-file <(compose_env_args) ps
        cid="$(docker compose -f "$COMPOSE_FILE" --env-file <(compose_env_args) ps -q runner 2>/dev/null || true)"
        if [ -n "$cid" ]; then
            docker inspect --format '{{.State.Status}}  {{.Name}}' "$cid" 2>/dev/null || true
        fi
        ;;
    *)
        echo "Usage: deploy.sh {build|probe|register|up|status|logs|down}" >&2
        exit 2
        ;;
esac
