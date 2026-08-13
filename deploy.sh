#!/usr/bin/env bash
# Local-only lifecycle helper for the persistent runner.
#
# This script is for the dedicated CI host. It does not start or
# stop any application stack; it only operates the
# ``docker-compose.yml`` overlay. Operators run this directly on
# the CI host (or via SSH) so the runner is reproducible from a
# single pinned image digest.
#
# The image is published as a multi-platform manifest supporting
# both ``linux/amd64`` and ``linux/arm64``. ``deploy.sh`` maps the
# host's ``uname -m`` output to the corresponding ``linux/amd64``
# or ``linux/arm64`` platform so a build, a probe, and a
# ``docker run --platform`` invocation always resolve to a native
# architecture. Emulation, mismatched daemons, and any host
# architecture other than x86_64 or aarch64 are rejected up front
# so a degraded deployment cannot reach the network.
#
# Usage:
#
#   deploy.sh build      Build the runner image for the native
#                        host architecture (linux/amd64 or
#                        linux/arm64).
#   deploy.sh probe      Run the capability probe on the image,
#                        scoped to the native host architecture.
#   deploy.sh up         Register the runner if needed and start the
#                        persistent listener in the single Compose
#                        container. A matching persisted identity
#                        skips the GitHub registration call.
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
#   TITAN_RUNNER_ENV_FILE     Path on the host to the gitignored
#                             ``.env`` that supplies the deployment
#                             variables. Default: the runner
#                             repository's ``.env``.
#   TITAN_RUNNER_LOCK_FILE    Path to the lifecycle lock file.
#                             Default: ``/var/lock/titan-runner.lock``.
#
# The env file is parsed through an allowlist -- only documented
# ``KEY=value`` entries are exposed to the deployment. ``.env`` is
# never shell-sourced and arbitrary entries are ignored. The file
# MUST be mode ``0600`` or stricter because ``TITAN_RUNNER_TOKEN``
# lives inside it.
#
# ``TITAN_RUNNER_TOKEN`` is the short-lived registration token.
# GitHub registration tokens expire after one hour; refresh the
# token immediately before the first ``docker compose up -d``. The
# token is forwarded by Compose to the single runner container as
# ``RUNNER_TOKEN``; the startup entrypoint consumes and unsets it
# before launching the listener. After successful registration,
# blank the line in ``.env`` and recreate the container so the
# listener metadata no longer carries the token; it continues to
# authenticate with the persisted long-lived secret.
#
# ``docker compose`` is the only command an operator needs. The
# single runner container performs the idempotent registration phase
# before launching its listener. The Compose contract rejects
# arbitrary ``.env`` entries: only the variables explicitly
# interpolated under the runner's ``environment:`` block reach the
# service. The allowlist in this helper is the auditable source of
# truth for the deployment surface.
#
# Subcommands take an exclusive flock (``up``, ``down``); ``status``
# and ``logs`` run without it so operators
# can inspect the deployment while a long command runs in another
# shell.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"

# Allowlist of documented deployment variables. Every entry read
# from the ``.env`` file MUST appear here or it is silently
# dropped. Adding a new variable requires extending this list and
# updating the documentation so the contract is auditable from
# one file.
ALLOWLIST_KEYS=(
    TITAN_RUNNER_IMAGE
    TITAN_RUNNER_REPO_URL
    TITAN_RUNNER_NAME
    TITAN_RUNNER_LABELS
    TITAN_RUNNER_TOKEN
    TITAN_RUNNER_STATE_DIR
    TITAN_RUNNER_RUNTIME_DIR
    TITAN_RUNNER_BROWSER_DIR
    TITAN_RUNNER_ROOT
    TITAN_RUNNER_STATE_VOLUME
    TITAN_RUNNER_LOCK_FILE
)
ALLOWLIST_RE='^[A-Za-z_][A-Za-z0-9_]*$'

# Architecture guard. The image supports the native ``linux/amd64``
# and ``linux/arm64`` platforms; map ``uname -m`` to the matching
# Docker platform string and refuse to operate on a host of any
# other architecture before any state is touched. Emulated /
# mismatched daemons are rejected separately inside ``probe``.
HOST_ARCH_RAW="$(uname -m)"
case "$HOST_ARCH_RAW" in
    x86_64|amd64)
        HOST_ARCH="amd64"
        PLATFORM="linux/amd64"
        EXPECTED_ARCH="amd64"
        ;;
    aarch64|arm64)
        HOST_ARCH="arm64"
        PLATFORM="linux/arm64"
        EXPECTED_ARCH="arm64"
        ;;
    *)
        printf 'ERROR: titan-stocks-runner requires a native x86_64 or ARM64 host (got %s)\n' "$HOST_ARCH_RAW" >&2
        exit 1
        ;;
esac

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

# Check whether a key is on the documented allowlist.
is_allowed_key() {
    local key="$1"
    local allowed
    for allowed in "${ALLOWLIST_KEYS[@]}"; do
        if [ "$allowed" = "$key" ]; then
            return 0
        fi
    done
    return 1
}

# Reject shell-unsafe values. Newlines, command substitution
# markers, and quoting characters are all refused so a value can
# never pivot a ``docker run --env-file`` injection.
is_safe_value() {
    case "$1" in
        *'$('*) return 1 ;;
        *'`'*) return 1 ;;
        *'"'*) return 1 ;;
        *'\'*) return 1 ;;
        *) return 0 ;;
    esac
}

# Build a temporary env-file containing only allowlisted
# ``KEY=value`` entries parsed from the supplied ``.env``. The
# returned path is mode ``0600`` because the registration token
# lives inside it.
build_env_file() {
    local env_file="$1"
    local out
    out="$(mktemp -t titan-runner-env.XXXXXX)"
    chmod 0600 "$out"
    if [ ! -f "$env_file" ]; then
        printf 'Configured env file %s does not exist.\n' "$env_file" >&2
        rm -f "$out"
        exit 1
    fi
    local mode
    mode="$(stat -c '%a' "$env_file" 2>/dev/null || stat -f '%Lp' "$env_file" 2>/dev/null || echo unknown)"
    case "$mode" in
        600|400) ;;
        *) printf 'Env file %s must be mode 0400 or 0600 (got 0%s).\n' "$env_file" "$mode" >&2
           rm -f "$out"
           exit 1 ;;
    esac
    local line stripped key value
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        # Strip an optional leading ``export `` so the file is
        # readable as both a shell-style and a Compose-style env
        # file.
        case "$line" in
            export\ *) stripped="${line#export }" ;;
            *) stripped="$line" ;;
        esac
        if [[ "$stripped" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            case "$value" in
                \"*\") value="${value#\"}"; value="${value%\"}" ;;
                \'*\') value="${value#\'}"; value="${value%\'}" ;;
            esac
            if [ -n "$key" ] \
                    && [[ "$key" =~ $ALLOWLIST_RE ]] \
                    && is_allowed_key "$key" \
                    && is_safe_value "$value"; then
                printf '%s=%s\n' "$key" "$value" >> "$out"
            fi
        fi
    done < "$env_file"
    printf '%s\n' "$out"
}

# Populate any unset deployment variables from the allowlisted
# ``.env`` file. Command-line / shell-exported values take
# precedence so operators can override individual keys without
# editing the file, including deliberate empty overrides
# (``export TITAN_RUNNER_TOKEN=``). The parser refuses shell-unsafe
# values, so a malicious ``.env`` cannot pivot a
# ``docker run --env-file`` injection. The temporary parsed
# env-file is removed as soon as the shell has absorbed its
# contents.
populate_from_env_file() {
    local env_file="${TITAN_RUNNER_ENV_FILE:-$ROOT_DIR/.env}"
    if [ ! -f "$env_file" ]; then
        return 0
    fi
    local parsed
    parsed="$(build_env_file "$env_file")"
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            # ``${!key+set}`` is non-empty when the variable is
            # set, including when set to an empty value. We only
            # populate the shell when the variable is *unset*, so a
            # deliberate empty override (``TITAN_RUNNER_TOKEN=`` on
            # the command line or in the operator's environment)
            # always wins over a value present in ``.env``.
            if [ -z "${!key+set}" ]; then
                printf -v "$key" '%s' "$value"
                declare -x "$key"
            fi
        fi
    done < "$parsed"
    rm -f "$parsed"
}

# Load the allowlisted ``.env`` file BEFORE resolving any
# operator-controlled path (e.g. ``TITAN_RUNNER_LOCK_FILE``) so
# the operator can override the lock-file location through the
# documented allowlist. The helper only populates variables that
# are not already set in the shell, so explicitly exported values
# -- including deliberately empty overrides such as
# ``export TITAN_RUNNER_TOKEN=`` -- always win over the file.
populate_from_env_file

action="${1:-status}"
shift || true

LOCK_FILE="${TITAN_RUNNER_LOCK_FILE:-/var/lock/titan-runner.lock}"

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

listener_running() {
    docker ps -q --filter name=titan-runner 2>/dev/null
}

env_file_present() {
    local file="${TITAN_RUNNER_ENV_FILE:-$ROOT_DIR/.env}"
    [ -f "$file" ] && echo present || echo absent
}

image_digest() {
    # Resolve the registry-served manifest digest for the
    # configured image reference. The ``Digest:`` line emitted by
    # ``buildx imagetools inspect`` is the manifest digest, not an
    # arbitrary configuration- or layer-level digest from the raw
    # JSON. A correctly-formatted digest is exactly ``sha256:``
    # followed by 64 lowercase hex characters.
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
            --platform "$PLATFORM" \
            --load \
            -f "$ROOT_DIR/Dockerfile" \
            -t "$TITAN_RUNNER_IMAGE" \
            "$ROOT_DIR"
        ;;
    probe)
        ensure_compose
        require TITAN_RUNNER_IMAGE
        # The probe sidecar must mirror the listener's bridge
        # contract: no ``--network host``, no ``--ipc host``,
        # ``--add-host host.docker.internal:host-gateway``, and a
        # generous shared-memory allocation so Chromium can
        # launch. The probe must never receive the registration
        # token, so the in-container environment is built
        # explicitly instead of being inherited from the host.
        # ``EXPECTED_ARCH`` is the native host architecture so
        # the probe can refuse an emulated or mismatched Docker
        # daemon before the rest of the contract runs.
        docker run --rm --platform "$PLATFORM" \
            --entrypoint /usr/local/bin/probe \
            --security-opt no-new-privileges:true \
            --add-host host.docker.internal:host-gateway \
            --shm-size 2gb \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -e HOME=/tmp \
            -e EXPECTED_ARCH="$EXPECTED_ARCH" \
            -e REPO_URL="${TITAN_RUNNER_REPO_URL:-}" \
            -e RUNNER_NAME="${TITAN_RUNNER_NAME:-titan-ci}" \
            -e RUNNER_LABELS="${TITAN_RUNNER_LABELS:-titan-ci}" \
            -e RUNNER_STATE_DIR="${TITAN_RUNNER_STATE_DIR:-/var/lib/titan-runner/state}" \
            -e RUNNER_RUNTIME_DIR="${TITAN_RUNNER_RUNTIME_DIR:-/var/lib/titan-runner/runtime}" \
            -e RUNNER_BROWSER_DIR="${TITAN_RUNNER_BROWSER_DIR:-/var/lib/titan-runner/browser}" \
            -e RUNNER_ROOT="${TITAN_RUNNER_ROOT:-/opt/actions-runner}" \
            "$TITAN_RUNNER_IMAGE"
        ;;
    up)
        ensure_compose
        take_lock
        trap release_lock EXIT
        require TITAN_RUNNER_IMAGE
        require TITAN_RUNNER_REPO_URL
        # The single runner container performs registration as its
        # startup phase, then launches the persistent listener. The
        # registration script is idempotent: a matching persisted
        # identity exits successfully without contacting GitHub and
        # without requiring ``TITAN_RUNNER_TOKEN``.
        docker compose -f "$COMPOSE_FILE" up -d --force-recreate --remove-orphans
        ;;
    down)
        ensure_compose
        take_lock
        trap release_lock EXIT
        docker compose -f "$COMPOSE_FILE" down --remove-orphans
        ;;
    logs)
        ensure_compose
        docker compose -f "$COMPOSE_FILE" logs --tail=200 --follow "$@"
        ;;
    status)
        ensure_compose
        require TITAN_RUNNER_IMAGE
        echo "=== Runner image ==="
        printf 'reference    : %s\n' "$TITAN_RUNNER_IMAGE"
        printf 'host arch    : %s (%s)\n' "$HOST_ARCH" "$PLATFORM"
        digest="$(image_digest || true)"
        if [ -n "$digest" ]; then
            printf 'digest       : %s\n' "$digest"
        else
            printf 'digest       : unresolved\n'
        fi
        echo "=== Runner container ==="
        printf 'lifecycle        : registration during startup; persistent listener\n'
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
            # Surface the bridge network mode so operators can
            # confirm the listener is not sharing the host
            # network namespace.
            network_mode="$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$cid")"
            printf 'network mode     : %s\n' "$network_mode"
            shm_size="$(docker inspect --format '{{.HostConfig.ShmSize}}' "$cid")"
            printf 'shm size         : %d bytes\n' "$shm_size"
            host_gateway="$(docker exec titan-runner getent hosts host.docker.internal 2>/dev/null \
                | awk '{print $1}' || true)"
            if [ -n "$host_gateway" ]; then
                printf 'host-gateway     : %s\n' "$host_gateway"
            else
                printf 'host-gateway     : unresolved\n'
            fi
            # Confirm the token is absent from the long-running
            # listener's environment. The image's user is
            # ``runner``; the container is named ``titan-runner``
            # and ``docker exec`` resolves the username against
            # ``/etc/passwd`` inside the container, so
            # ``-u titan-runner`` would fail and abort the status
            # check.
            token_in_env="$(docker exec -u runner titan-runner \
                sh -c 'env | grep -c "^RUNNER_TOKEN=" || true')"
            printf 'RUNNER_TOKEN       : %s occurrence(s)\n' "$token_in_env"
            titan_token_in_env="$(docker exec -u runner titan-runner \
                sh -c 'env | grep -c "^TITAN_RUNNER_TOKEN=" || true')"
            printf 'TITAN_RUNNER_TOKEN : %s occurrence(s)\n' "$titan_token_in_env"
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
        for volume in titan-runner-work titan-runner-browser; do
            if docker volume inspect "$volume" >/dev/null 2>&1; then
                printf '%s : present\n' "$volume"
            else
                printf '%s : not created\n' "$volume"
            fi
        done
        echo "=== Env file ==="
        printf '%s : %s\n' \
            "${TITAN_RUNNER_ENV_FILE:-$ROOT_DIR/.env}" \
            "$(env_file_present)"
        ;;
    *)
        echo "Usage: deploy.sh {build|probe|up|down|status|logs}" >&2
        exit 2
        ;;
esac
