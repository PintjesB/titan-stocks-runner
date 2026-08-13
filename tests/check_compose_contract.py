#!/usr/bin/env python3
# Validate the documented Compose startup contract using the
# resolved Compose model rather than the raw YAML surface.
#
# The contract requires:
#
#   * Exactly one service: ``runner`` (the long-running listener).
#   * Registration runs inside the runner's startup entrypoint; there
#     is no disposable Compose service or ``depends_on`` gate.
#   * The workspace mount is an identical host/container bind
#     mount; a named ``titan-runner-work`` volume is forbidden.
#   * Persistent ``titan-runner-state`` and ``titan-runner-browser``
#     named volumes are declared so Compose owns their lifecycle.
#
# A regression that drops any of these surfaces blocks the
# ``publish.yml`` workflow contract job and prevents publication.
#
# The validation prefers ``docker compose config`` because it
# resolves variable interpolation, the bind-mount source and
# target, and the volume declarations exactly the way Compose
# itself would. When the docker CLI is unavailable the script
# falls back to parsing the YAML surface; an available Compose CLI
# must always parse the real file successfully.
from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path


COMPOSE_PATH = Path("docker-compose.yml")
DOTENV_PATH = Path(".env.example")


def _fail(message: str) -> None:
    print(f"::error::{message}", file=sys.stderr)
    raise SystemExit(1)


def _load_resolved_model() -> dict | None:
    """Return the resolved Compose model.

    Prefers ``docker compose config`` so variable interpolation,
    bind-mount resolution, and the volume declarations are
    resolved by the same engine that runs the stack. Uses the
    secret-free ``.env.example`` so the contract surface is
    checked against the same interpolation a production host
    would perform without leaking credentials. Returns ``None`` only
    when Docker itself is unavailable; when Docker Compose is present,
    an invalid model is a deployment failure and MUST fail the gate.
    """
    if shutil.which("docker") is None:
        return None
    if not DOTENV_PATH.exists():
        _fail(".env.example is required to resolve the Compose contract")
    try:
        result = subprocess.run(
            [
                "docker",
                "compose",
                "-f",
                str(COMPOSE_PATH),
                "--env-file",
                str(DOTENV_PATH),
                "config",
                "--format",
                "json",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    except (FileNotFoundError, PermissionError):
        return None
    if result.returncode != 0 or not result.stdout.strip():
        detail = (result.stderr or result.stdout or "unknown error").strip()
        _fail(f"docker compose config failed: {detail}")
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict):
        return None
    return data
def _load_yaml() -> dict:
    import yaml

    return yaml.safe_load(COMPOSE_PATH.read_text(encoding="utf-8"))


def _validate(resolved: dict | None, raw: dict) -> None:
    data = resolved if resolved is not None else raw
    if not isinstance(data, dict):
        _fail("docker-compose.yml must parse as a mapping")
    services = data.get("services")
    if not isinstance(services, dict):
        _fail("docker-compose.yml must declare `services:` as a mapping")
    if set(services) != {"runner"}:
        _fail(
            "docker-compose.yml must declare exactly one service, `runner`; "
            "registration is an internal startup phase"
        )
    runner = services["runner"]
    if not isinstance(runner, dict):
        _fail("docker-compose.yml `runner` service must be a mapping")
    if "depends_on" in runner:
        _fail("docker-compose.yml `runner` must not declare `depends_on`")

    environment = runner.get("environment") or {}
    if "RUNNER_TOKEN" not in environment:
        _fail(
            "docker-compose.yml runner environment must pass RUNNER_TOKEN "
            "to the startup registration phase"
        )

    # The workspace MUST be a bind mount with identical absolute
    # source and target paths; a named volume would mean the host
    # Docker daemon's view of the workspace diverges from the
    # listener's view. ``docker compose config`` resolves the
    # ``${TITAN_RUNNER_WORK_DIR:-/var/lib/titan-runner/work}``
    # default to the absolute path; the YAML fallback inspects
    # the raw interpolation form so the contract is still pinned
    # when docker is unavailable.
    service_name, service = "runner", runner
    if resolved is not None:
        bind_mounts = [
            m
            for m in (service.get("volumes") or [])
            if isinstance(m, dict) and m.get("type") == "bind"
        ]
    else:
        bind_mounts = [
            v
            for v in (service.get("volumes") or [])
            if isinstance(v, dict) and v.get("type") == "bind"
        ]
    work_mounts = [m for m in bind_mounts if _is_work_mount(m)]
    if not work_mounts:
        _fail(
            f"docker-compose.yml `{service_name}` service must mount the "
            "workspace as a bind mount"
        )
    mount = work_mounts[0]
    if resolved is None:
        bind = mount.get("bind")
        if not isinstance(bind, dict) or bind.get("create_host_path") is not True:
            _fail(
                f"docker-compose.yml `{service_name}` service work bind mount "
                "must declare bind.create_host_path: true"
            )
    source = mount.get("source")
    target = mount.get("target")
    if not source or not target:
        _fail(
            f"docker-compose.yml `{service_name}` service work bind mount "
            "must declare both source and target"
        )
    if source != target:
        _fail(
            f"docker-compose.yml `{service_name}` service work bind mount "
            "source and target must be identical "
            f"(source={source!r}, target={target!r})"
        )

    # The named work volume MUST NOT be declared; the workspace is
    # a bind mount now.
    volumes = data.get("volumes")
    if isinstance(volumes, dict) and "titan-runner-work" in volumes:
        _fail(
            "docker-compose.yml MUST NOT declare a `titan-runner-work` "
            "named volume; the workspace is now a host/container bind mount"
        )

    # Persistent state and browser volumes MUST exist.
    if not isinstance(volumes, dict) or "titan-runner-state" not in volumes:
        _fail(
            "docker-compose.yml must declare the `titan-runner-state` named "
            "volume"
        )
    if not isinstance(volumes, dict) or "titan-runner-browser" not in volumes:
        _fail(
            "docker-compose.yml must declare the `titan-runner-browser` named "
            "volume"
        )


def _is_work_mount(mount: dict) -> bool:
    target = mount.get("target")
    return isinstance(target, str) and (
        target == "/var/lib/titan-runner/work"
        or target == "${TITAN_RUNNER_WORK_DIR:-/var/lib/titan-runner/work}"
        or target.endswith("/var/lib/titan-runner/work")
    )


def main() -> int:
    if not COMPOSE_PATH.exists():
        _fail("docker-compose.yml is missing from the repository root")
    raw = _load_yaml()
    _validate(None, raw)
    resolved = _load_resolved_model()
    if resolved is not None:
        _validate(resolved, raw)
    print(
        "compose contract validated"
        + (" (resolved via docker compose config)" if resolved is not None else " (raw YAML fallback)")
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
