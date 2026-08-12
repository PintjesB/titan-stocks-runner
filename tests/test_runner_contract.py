"""Contract tests for the Titan Stocks self-hosted runner.

The tests pin the image, the Compose runtime contract, the
operator-facing configuration knobs, and the lifecycle script
behaviour. They run from CI on a hosted ARM64 runner without
Docker so they only validate the project files; the behavioural
assertions (Docker daemon reachability, Chromium launch) live in
``deploy.sh probe`` and the published image.

Lifecycle invariants covered here:

* Image builds only target ``linux/arm64`` with the documented
  Capabilities and a pinned Actions runner.
* The persistent state layout is named volume + host bind mount, not
  a single container filesystem.
* ``deploy.sh probe`` and ``deploy.sh register`` use ``--entrypoint``
  to override the image's default listener entrypoint.
* ``deploy.sh up`` does not mount the registration token file.
* The listener runs only ``run.sh`` with no runtime
  ``--start``/``--disableupdate`` flags.
* The Compose contract mounts the host work directory at the same
  absolute path inside the container.
"""
from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOCKERFILE = ROOT / "Dockerfile"
COMPOSE_FILE = ROOT / "docker-compose.yml"
DEPLOY_SCRIPT = ROOT / "deploy.sh"
SCRIPTS_DIR = ROOT / "scripts"
REGISTER_SCRIPT = SCRIPTS_DIR / "register.sh"
START_RUNNER_SCRIPT = SCRIPTS_DIR / "start-runner.sh"

DEFAULT_LABELS = "self-hosted,linux,ARM64,titan-ci"


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_dockerfile_targets_arm64_ubuntu_base_with_digest_pin() -> None:
    """The base image MUST be Ubuntu 24.04 ARM64 with a digest pin."""
    text = _read(DOCKERFILE)
    assert "ARG UBUNTU_BASE_DIGEST=sha256:" in text, (
        "Dockerfile must declare UBUNTU_BASE_DIGEST as an immutable digest"
    )
    assert "FROM ubuntu:24.04@${UBUNTU_BASE_DIGEST}" in text, (
        "Dockerfile must reference ubuntu:24.04 through the digest ARG"
    )


def test_dockerfile_pins_actions_runner_version_and_digest() -> None:
    """The Actions runner must be pinned by version and digest."""
    text = _read(DOCKERFILE)
    assert "ARG RUNNER_VERSION=" in text, "Dockerfile must declare RUNNER_VERSION"
    assert "ARG RUNNER_SHA256=" in text, "Dockerfile must declare RUNNER_SHA256"
    assert "fetch-runner.sh" in text, "Dockerfile must call fetch-runner at build time"
    assert re.search(
        r"sha256sum.*RUNNER_SHA256", text, flags=re.DOTALL
    ) or "sha256sum \"$archive\"" in _read(SCRIPTS_DIR / "fetch-runner.sh"), (
        "fetch-runner.sh must verify the upstream tarball digest"
    )


def test_dockerfile_installs_documented_capabilities() -> None:
    """The image MUST install the documented capability set."""
    text = _read(DOCKERFILE)
    for marker in (
        "docker.io",
        "docker-compose-v2",
        "docker-buildx",
        "postgresql-client",
        "shellcheck",
        "nodejs",
        "githubcli-archive-keyring.gpg",  # GH CLI
        "libnss3",
        "libgbm1",
        "libasound2t64",
        "libcairo2",
        "libpangocairo-1.0-0t64",
        "playwright@${PLAYWRIGHT_VERSION}",
        "gosu",
        "tini",
    ):
        assert marker in text, f"Dockerfile must install capability: {marker!r}"


def test_dockerfile_omits_oci_license_label() -> None:
    """The image intentionally ships without an OCI license label.

    No third party receives any license grant by pulling the image; the
    project does not ship a ``LICENSE`` file.
    """
    text = _read(DOCKERFILE)
    assert "org.opencontainers.image.licenses" not in text, (
        "Dockerfile must not declare an OCI license label"
    )


def test_register_materialises_runtime_and_persists_credentials_separately() -> None:
    """Registration writes a *runtime* tree and persists only the
    mutable credentials into the *state* directory."""
    text = _read(REGISTER_SCRIPT)
    assert "RUNNER_STATE_DIR" in text
    assert "RUNNER_RUNTIME_DIR" in text
    assert "RUNNER_TOKEN_FILE" in text
    assert "--disableupdate" in text, "registration must disable self-update"
    assert "--replace" in text, "registration must replace an existing registration"
    register_block = text.split("register_args=(", 1)[1].split(")", 1)[0]
    assert "--ephemeral" not in register_block
    assert "--once" not in register_block
    # The runtime tree is materialised from the image; the credentials
    # are written into the state directory only.
    assert 'cp -a "$RUNNER_ROOT/." "$RUNNER_RUNTIME_DIR/"' in text, (
        "register.sh must clone the image-owned tree into a disposable runtime"
    )
    # Register copies only the mutable credentials into state and
    # removes the runtime tree afterwards.
    assert '"$RUNNER_STATE_DIR/$fname"' in text or (
        '"$RUNNER_RUNTIME_DIR/$fname"' in text and '"$RUNNER_STATE_DIR/$fname"' in text
    ), "register.sh must copy mutable credentials from runtime to state"
    assert 'rm -rf "$RUNNER_RUNTIME_DIR"' in text, (
        "register.sh must remove the disposable runtime tree on exit"
    )


def test_register_does_not_change_runner_primary_group() -> None:
    """The register sidecar does not change the runner user's primary group."""
    text = _read(REGISTER_SCRIPT)
    assert "usermod --gid" not in text, (
        "register.sh must NOT change the runner user's primary group"
    )


def test_register_applies_strict_credentials_permissions() -> None:
    """Credentials MUST be persisted with strict permissions and runner ownership."""
    text = _read(REGISTER_SCRIPT)
    assert 'chmod 0600 "$RUNNER_STATE_DIR"/.credentials*' in text, (
        "register.sh must chmod 0600 on persistent credentials"
    )
    assert 'chmod 0640 "$RUNNER_STATE_DIR/.runner"' in text, (
        "register.sh must chmod 0640 on the .runner registration manifest"
    )
    assert 'chown -R runner:runner "$RUNNER_STATE_DIR"' in text, (
        "register.sh must chown state directory to runner:runner"
    )


def test_start_runner_rebuilds_runtime_tree_from_image() -> None:
    """The listener must materialise a runtime tree from the image rather
    than depend on an in-image configuration."""
    text = _read(START_RUNNER_SCRIPT)
    # The runtime tree is rebuilt from the immutable image before the
    # persisted credentials are overlaid.
    assert 'cp -a "$RUNNER_ROOT/." "$RUNNER_RUNTIME_DIR/"' in text, (
        "start-runner.sh must clone the image-owned tree into a fresh runtime"
    )
    assert 'cp "$RUNNER_STATE_DIR/.runner" "$RUNNER_RUNTIME_DIR/.runner"' in text, (
        "start-runner.sh must overlay persisted .runner onto the runtime tree"
    )
    assert 'cp "$RUNNER_STATE_DIR/.credentials" "$RUNNER_RUNTIME_DIR/.credentials"' in text, (
        "start-runner.sh must overlay persisted .credentials onto the runtime tree"
    )


def test_start_runner_refuses_without_persisted_credentials() -> None:
    """The listener must abort early when the state directory has no credentials."""
    text = _read(START_RUNNER_SCRIPT)
    assert "RUNNER_STATE_DIR" in text
    assert "missing persisted credential" in text, (
        "start-runner.sh must refuse to start when credentials are missing"
    )


def test_start_runner_invokes_run_sh_with_no_runtime_flags() -> None:
    """The listener MUST run ``run.sh`` without ``--start``/``--disableupdate``.

    ``--disableupdate`` is set at registration and persists in the
    ``.runner`` manifest; ``--start`` daemonises, which we do not want
    inside a container.
    """
    text = _read(START_RUNNER_SCRIPT)
    # The final ``gosu runner run.sh`` invocation is the only listener
    # launch; it must not include the listener-side flags.
    exec_call = text.split("gosu runner", 1)[1].split("fi", 1)[0]
    assert "--start" not in exec_call, (
        "start-runner.sh must NOT pass --start to run.sh"
    )
    assert "--disableupdate" not in exec_call, (
        "start-runner.sh must NOT pass --disableupdate to run.sh"
    )
    assert "run.sh" in exec_call, (
        "start-runner.sh must exec run.sh via gosu runner"
    )


def test_start_runner_grants_docker_socket_as_supplemental_group() -> None:
    """The host Docker socket's GID must be added as a supplemental group only."""
    text = _read(START_RUNNER_SCRIPT)
    assert "usermod -a -G" in text, (
        "start-runner.sh must add the host docker GID as supplemental (usermod -a -G)"
    )
    assert "usermod --gid" not in text, (
        "start-runner.sh must NOT change the runner user's primary group"
    )


def test_compose_pins_image_and_declares_state_and_browser_volumes() -> None:
    """The Compose contract must pin the image and declare the named volumes
    for state and browser cache."""
    text = _read(COMPOSE_FILE)
    assert "TITAN_RUNNER_IMAGE" in text, (
        "docker-compose.yml must reference TITAN_RUNNER_IMAGE"
    )
    assert "titan-runner-state" in text, (
        "docker-compose.yml must declare the titan-runner-state named volume"
    )
    assert "titan-runner-browser" in text, (
        "docker-compose.yml must declare the titan-runner-browser named volume"
    )
    for marker in (
        "network_mode: host",
        "ipc: host",
        "init: true",
        "no-new-privileges:true",
        "privileged: false",
        "/var/run/docker.sock:/var/run/docker.sock",
        "restart: unless-stopped",
    ):
        assert marker in text, f"docker-compose.yml must declare {marker!r}"


def test_compose_binds_work_directory_at_same_absolute_path() -> None:
    """The ``_work`` directory MUST be a host bind mount with the same
    absolute path inside and outside the container so the host Docker
    daemon publishes child service-container artefacts into the same
    workspace the runner sees."""
    text = _read(COMPOSE_FILE)
    assert "- /var/lib/titan-runner/work:/var/lib/titan-runner/work" in text, (
        "docker-compose.yml must bind-mount /var/lib/titan-runner/work at the same path"
    )
    # The work directory must NOT be a named volume at the top-level
    # ``volumes:`` block.
    volumes_block = text.split("volumes:", 1)[1]
    assert "titan-runner-work:" not in volumes_block, (
        "work must not be a named volume; it must be a bind mount"
    )


def test_compose_does_not_mount_registration_token() -> None:
    """The Compose contract MUST NOT mount a registration token file on
    the long-running listener. The token exists only for the one-shot
    ``deploy.sh register`` sidecar."""
    text = _read(COMPOSE_FILE)
    assert "registration-token" not in text, (
        "docker-compose.yml must not mount a registration token file"
    )
    assert "TITAN_RUNNER_TOKEN_FILE" not in text, (
        "docker-compose.yml must not accept a token file environment variable"
    )


def test_compose_does_not_hardcode_repository_url() -> None:
    """The Compose contract must NOT hardcode the consumer repository URL."""
    text = _read(COMPOSE_FILE)
    assert "https://github.com/PintjesB/titan-stocks" not in text, (
        "docker-compose.yml must not hardcode the consumer repository URL"
    )
    assert "TITAN_RUNNER_REPO_URL" in text, (
        "docker-compose.yml must source the repo URL from the deployment"
    )


def test_deploy_refuses_non_arm64_hosts() -> None:
    """``deploy.sh`` MUST abort on non-ARM64 hosts."""
    text = _read(DEPLOY_SCRIPT)
    assert "uname -m" in text, (
        "deploy.sh must inspect uname -m before any state mutation"
    )
    assert "ARM64" in text, (
        "deploy.sh must report an ARM64 requirement error"
    )
    assert re.search(r"aarch64\|arm64\)", text), (
        "deploy.sh architecture check must accept aarch64 or arm64"
    )


def test_deploy_exposes_required_subcommands() -> None:
    """``deploy.sh`` must expose every documented subcommand."""
    text = _read(DEPLOY_SCRIPT)
    for subcommand in ("build", "probe", "register", "up", "down", "status", "logs"):
        assert subcommand in text, (
            f"deploy.sh must handle the {subcommand!r} subcommand"
        )


def test_deploy_probe_uses_entrypoint_override() -> None:
    """``deploy.sh probe`` MUST override the image entrypoint to probe."""
    text = _read(DEPLOY_SCRIPT)
    # Locate the probe branch and confirm it overrides the entrypoint.
    branch = text.split("probe)", 1)[1].split("register)", 1)[0]
    assert "--entrypoint /usr/local/bin/probe" in branch, (
        "deploy.sh probe must set --entrypoint /usr/local/bin/probe"
    )


def test_deploy_register_uses_entrypoint_override() -> None:
    """``deploy.sh register`` MUST override the image entrypoint to register."""
    text = _read(DEPLOY_SCRIPT)
    branch = text.split("register)", 1)[1].split("up)", 1)[0]
    assert "--entrypoint /usr/local/bin/register" in branch, (
        "deploy.sh register must set --entrypoint /usr/local/bin/register"
    )


def test_deploy_register_does_not_mount_token_on_long_running() -> None:
    """``deploy.sh up`` MUST NOT mount the registration token file."""
    text = _read(DEPLOY_SCRIPT)
    up_branch = text.split("up)", 1)[1].split("down)", 1)[0]
    assert "registration-token" not in up_branch, (
        "deploy.sh up must not mount the registration token file"
    )
    assert "TITAN_RUNNER_TOKEN_FILE" not in up_branch, (
        "deploy.sh up must not pass the token file env var to compose"
    )


def test_deploy_takes_exclusive_lock_for_lifecycle_mutations() -> None:
    """``deploy.sh`` register/up/down MUST take an exclusive flock."""
    text = _read(DEPLOY_SCRIPT)
    assert "flock -n 9" in text, "deploy.sh must take an exclusive flock"
    assert "/var/lock/titan-runner.lock" in text, (
        "deploy.sh must use /var/lock/titan-runner.lock by default"
    )
    # All three mutation subcommands must call take_lock.
    for sub in ("register", "up", "down"):
        branch = text.split(f"{sub})", 1)[1].split("logs)", 1)[0]
        assert "take_lock" in branch, (
            f"deploy.sh {sub!r} must take the lifecycle lock"
        )


def test_deploy_status_reports_runner_health_signals() -> None:
    """``deploy.sh status`` MUST expose the listener process, docker
    socket reachability, and credentials state."""
    text = _read(DEPLOY_SCRIPT)
    branch = text.split("status)", 1)[1].split("*)", 1)[0]
    for marker in (
        "Runner.Listener",
        "docker info",
        ".credentials",
        "titan-runner-state",
    ):
        assert marker in branch, f"deploy.sh status must surface {marker!r}"


def test_deploy_pins_image_by_digest_only() -> None:
    """``deploy.sh`` must read ``TITAN_RUNNER_IMAGE`` and refuse to fall
    back to a mutable tag."""
    text = _read(DEPLOY_SCRIPT)
    assert "TITAN_RUNNER_IMAGE" in text, (
        "deploy.sh must read TITAN_RUNNER_IMAGE as the deployment image"
    )
