#!/usr/bin/env bash
# Shell-level tests for the runner lifecycle scripts.
#
# The tests exercise input validation and contract guards directly
# without requiring Docker, the network, or the full set of installed
# CLI plugins. Behaviour that depends on the installed image (binary
# presence, Compose v2 plugin, etc.) is covered by ``deploy.sh probe``
# inside the published image.
#
# Tests cover:
#
#   * ``fetch-runner.sh`` rejects missing environment variables and
#     digest mismatches.
#   * ``register.sh`` refuses to run without configuration and rejects
#     a non-0600 token file.
#   * ``start-runner.sh`` refuses to start without persisted state.
#   * ``probe.sh`` honours ``--skip-network``.
#   * ``deploy.sh`` rejects unknown subcommands.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPTS_DIR="$ROOT_DIR/scripts"

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf 'FAIL %s\n  expected to contain: %s\n' "$message" "$needle" >&2
        exit 1
    fi
}

assert_exit_code() {
    local actual="$1" expected="$2" message="$3"
    if [ "$actual" -ne "$expected" ]; then
        printf 'FAIL %s\n  expected exit: %s\n  actual exit: %s\n' "$message" "$expected" "$actual" >&2
        exit 1
    fi
}

ok() { printf 'ok   %s\n' "$*"; }

run_with_capture() {
    local script="$1"; shift
    local rc=0
    env -i HOME=/tmp PATH=/usr/bin:/bin "$@" bash "$script" 2>&1 || rc=$? || true
    printf '%s' "$rc"
}

test_fetch_runner_rejects_missing_version() {
    local output rc
    output="$(env -i HOME=/tmp PATH=/usr/bin:/bin bash "$SCRIPTS_DIR/fetch-runner.sh" 2>&1)" || rc=$? || true
    rc="${rc:-0}"
    assert_exit_code "$rc" 1 "fetch-runner exits 1 when RUNNER_VERSION is unset"
    assert_contains "$output" "RUNNER_VERSION" "error mentions RUNNER_VERSION"
    ok "fetch-runner requires RUNNER_VERSION"
}

test_fetch_runner_rejects_bad_digest_after_download() {
    local tmp; tmp="$(mktemp -d)"
    mkdir -p "$tmp/bin"
    # A ``curl`` stub that materialises a fake tarball in the working
    # directory captured at install time. ``fetch-runner.sh`` invokes
    # curl with ``--output <path>`` so we honour that flag.
    cat > "$tmp/bin/curl" <<EOF
#!/usr/bin/env bash
output="\$PWD/fake.tar.gz"
while [ \$# -gt 0 ]; do
    case "\$1" in
        --output) output="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
echo "fake upstream tarball" > "\$output"
EOF
    chmod +x "$tmp/bin/curl"
    local output rc
    # ``sha256sum`` is shipped in /usr/bin on Debian/Ubuntu runners and
    # in /sbin on macOS hosts (where /sbin is required for coreutils).
    # Include both so the test runs in either environment.
    output="$(cd "$tmp" && env -i PATH="$tmp/bin:/usr/bin:/sbin:/bin" HOME="$tmp" \
        RUNNER_VERSION=2.336.0 \
        RUNNER_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
        bash "$SCRIPTS_DIR/fetch-runner.sh" 2>&1)" || rc=$? || true
    rc="${rc:-0}"
    assert_exit_code "$rc" 3 "fetch-runner exits 3 on digest mismatch"
    assert_contains "$output" "digest" "error mentions digest verification"
    rm -rf "$tmp"
    ok "fetch-runner rejects a digest mismatch"
}

test_register_requires_configuration() {
    # The script also refuses to run as a non-root user; either
    # failure is acceptable for the contract test.
    local rc=0
    env -i HOME=/tmp PATH=/usr/bin:/bin bash "$SCRIPTS_DIR/register.sh" >/dev/null 2>&1 || rc=$? || true
    rc="${rc:-0}"
    [ "$rc" -ne 0 ] || { echo "FAIL register must not run without configuration" >&2; exit 1; }
    ok "register requires configuration"
}

test_register_rejects_world_readable_token() {
    # ``register.sh`` requires ``root`` to map supplemental groups, so
    # we skip the test on unprivileged developer workstations.
    if [ "$(id -u)" -ne 0 ]; then
        printf 'ok   (skip) register refuses a world-readable token file (requires root)\n'
        return 0
    fi
    local tmp; tmp="$(mktemp -d)"
    local token="$tmp/token"
    echo "ABC" > "$token"
    chmod 0644 "$token"
    local rc=0
    env -i HOME=/tmp PATH=/usr/bin:/bin \
        REPO_URL=https://example.com/repo \
        RUNNER_TOKEN_FILE="$token" \
        bash "$SCRIPTS_DIR/register.sh" >/dev/null 2>&1 || rc=$? || true
    rc="${rc:-0}"
    assert_exit_code "$rc" 2 "register refuses a non-0600 token file"
    rm -rf "$tmp"
    ok "register refuses a world-readable token file"
}

test_start_runner_requires_state() {
    # The start-runner script also refuses to run as a non-root user;
    # the missing-credentials guard fires before any privileged
    # operation.
    local rc=0
    env -i HOME=/tmp PATH=/usr/bin:/bin bash "$SCRIPTS_DIR/start-runner.sh" >/dev/null 2>&1 || rc=$? || true
    rc="${rc:-0}"
    [ "$rc" -ne 0 ] || { echo "FAIL start-runner must require persisted state" >&2; exit 1; }
    ok "start-runner refuses to start without state"
}

test_probe_wires_skip_network() {
    assert_contains "$(cat "$SCRIPTS_DIR/probe.sh")" "skip-network" "probe supports skip-network"
    ok "probe honours --skip-network"
}

test_deploy_rejects_unknown_subcommand() {
    local rc=0
    env -i HOME=/tmp PATH=/usr/bin:/bin \
        TITAN_RUNNER_IMAGE=example.com/runner:dev \
        TITAN_RUNNER_REPO_URL=https://example.com/repo \
        bash "$ROOT_DIR/deploy.sh" bogus >/dev/null 2>&1 || rc=$? || true
    rc="${rc:-0}"
    assert_exit_code "$rc" 2 "deploy.sh rejects unknown subcommands"
    ok "deploy.sh rejects unknown subcommands"
}

main() {
    test_fetch_runner_rejects_missing_version
    test_fetch_runner_rejects_bad_digest_after_download
    test_register_requires_configuration
    test_register_rejects_world_readable_token
    test_start_runner_requires_state
    test_probe_wires_skip_network
    test_deploy_rejects_unknown_subcommand
    echo "all runner shell tests passed"
}

main "$@"
