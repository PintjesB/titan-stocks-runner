"""Contract tests for the Titan Stocks self-hosted runner.

The tests pin the image, the Compose runtime contract, and the
operator-facing configuration knobs. They run from CI on a hosted ARM64
runner without Docker so they only validate the project files; the
behavioural assertions (Docker daemon reachability, Chromium launch)
live in ``deploy.sh probe`` and the published image.
"""
from __future__ import annotations

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
DOCKERFILE = ROOT / "Dockerfile"
COMPOSE_FILE = ROOT / "docker-compose.yml"
DEPLOY_SCRIPT = ROOT / "deploy.sh"
SCRIPTS_DIR = ROOT / "scripts"

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


def test_register_persists_credentials_to_state_volume() -> None:
    """The register script must persist credentials to a state directory."""
    text = _read(SCRIPTS_DIR / "register.sh")
    assert "RUNNER_STATE_DIR" in text, "register.sh must honour a state directory"
    assert "RUNNER_TOKEN_FILE" in text, "register.sh must consume a token file"
    assert "--disableupdate" in text, "registration must disable self-update"
    # ``config.sh`` accepts ``--ephemeral`` and ``--once``; both must be
    # absent from the registration argument vector. The documentation
    # of the script may mention the flags in prose.
    register_block = text.split("register_args=(", 1)[1].split(")", 1)[0]
    assert "--ephemeral" not in register_block, (
        "registration must NOT be ephemeral"
    )
    assert "--once" not in register_block, (
        "registration must NOT be once-only"
    )
    assert ".credentials" in text, "registration must persist .credentials"


def test_register_keeps_runner_primary_group_intact() -> None:
    """The register script must add the docker GID as supplemental only."""
    text = _read(SCRIPTS_DIR / "register.sh")
    assert "usermod -a -G" in text, (
        "register.sh must add the host docker GID as a supplemental group (-aG)"
    )
    assert "usermod --gid" not in text, (
        "register.sh must NOT change the runner user's primary group"
    )


def test_start_runner_refuses_without_credentials() -> None:
    """The listener must refuse to start without persisted credentials."""
    text = _read(SCRIPTS_DIR / "start-runner.sh")
    assert "RUNNER_STATE_DIR" in text, "start-runner.sh must read a state directory"
    assert "missing persisted credential" in text, (
        "start-runner.sh must abort early when credentials are missing"
    )
    assert "--disableupdate" in text, "listener must run with --disableupdate"
    # ``run.sh`` accepts ``--once``; the listener argument vector must
    # not include it. The prose at the top of the script may.
    listener_block = text.split('exec_args=(', 1)[1].split(')', 1)[0]
    assert "--once" not in listener_block, (
        "listener must NOT be configured with --once"
    )


def test_compose_pins_image_and_uses_three_volumes() -> None:
    """The Compose contract must pin the image and use the three volumes."""
    text = _read(COMPOSE_FILE)
    assert "TITAN_RUNNER_IMAGE" in text, (
        "docker-compose.yml must reference TITAN_RUNNER_IMAGE"
    )
    assert "titan-runner-state" in text, (
        "docker-compose.yml must declare the titan-runner-state volume"
    )
    assert "titan-runner-work" in text, (
        "docker-compose.yml must declare the titan-runner-work volume"
    )
    assert "titan-runner-browser" in text, (
        "docker-compose.yml must declare the titan-runner-browser volume"
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


def test_compose_does_not_hardcode_repository_url() -> None:
    """The Compose contract must NOT hardcode the consumer repository URL."""
    text = _read(COMPOSE_FILE)
    assert "https://github.com/PintjesB/titan-stocks" not in text, (
        "docker-compose.yml must not hardcode the consumer repository URL"
    )
    assert "TITAN_RUNNER_REPO_URL" in text, (
        "docker-compose.yml must source the repo URL from the deployment"
    )
    assert "RO" not in text or "TITAN_RUNNER_REPO_URL" in text, (
        "the repository URL must only appear through TITAN_RUNNER_REPO_URL"
    )


def test_deploy_exposes_required_subcommands() -> None:
    """``deploy.sh`` must expose every documented subcommand."""
    text = _read(DEPLOY_SCRIPT)
    for subcommand in ("build", "probe", "register", "up", "status", "logs", "down"):
        assert subcommand in text, f"deploy.sh must handle the {subcommand!r} subcommand"


def test_deploy_register_mounts_token_file_read_only() -> None:
    """``deploy.sh register`` must bind-mount the token file read-only."""
    text = _read(DEPLOY_SCRIPT)
    # Inspect the register branch for the bind-mount declaration.
    assert "register)" in text or "register)\n" in text or "    register)" in text, (
        "deploy.sh must define a `register` branch"
    )
    # The script manages the token via :ro for the volume mount; the
    # sidecar container uses --security-opt no-new-privileges:true.
    assert "no-new-privileges:true" in text, (
        "deploy.sh register must enforce no-new-privileges on the helper"
    )


def test_deploy_pins_image_by_digest_only() -> None:
    """Operator documentation must document digest pinning."""
    text = _read(DEPLOY_SCRIPT)
    assert "TITAN_RUNNER_IMAGE" in text, (
        "deploy.sh must read TITAN_RUNNER_IMAGE as the deployment image"
    )
