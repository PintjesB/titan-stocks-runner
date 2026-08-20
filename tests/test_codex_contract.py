"""Static contract tests for the Codex capability on the runner image."""
from __future__ import annotations

import re
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
DOCKERFILE = ROOT / "Dockerfile"
COMPOSE_FILE = ROOT / "docker-compose.yml"
START_RUNNER = ROOT / "scripts" / "start-runner.sh"
PROBE = ROOT / "scripts" / "probe.sh"
POST_JOB = ROOT / "scripts" / "post-job.sh"
DOC = ROOT / "docs" / "codex.md"


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_codex_cli_is_version_pinned_in_image() -> None:
    text = _read(DOCKERFILE)
    match = re.search(r"ARG CODEX_VERSION=([0-9]+\.[0-9]+\.[0-9]+)", text)
    assert match, "Dockerfile must pin CODEX_VERSION to an exact stable version"
    version = match.group(1)
    assert f'@openai/codex@${{CODEX_VERSION}}' in text
    assert "codex --version" in text
    assert f"CODEX_VERSION={version}" in text
    assert "CODEX_HOME=/home/runner/.codex" in text


def test_compose_persists_codex_auth_in_named_volume() -> None:
    data = yaml.safe_load(COMPOSE_FILE.read_text(encoding="utf-8"))
    runner = data["services"]["runner"]
    assert runner["environment"]["CODEX_HOME"] == "/home/runner/.codex"
    assert "titan-runner-codex:/home/runner/.codex" in runner["volumes"]
    assert data["volumes"]["titan-runner-codex"] == {
        "name": "titan-runner-codex"
    }


def test_startup_repairs_codex_volume_ownership() -> None:
    text = _read(START_RUNNER)
    assert 'CODEX_HOME="${CODEX_HOME:-/home/runner/.codex}"' in text
    assert '"$CODEX_HOME"' in text
    assert 'chown -R runner:runner "$CODEX_HOME"' in text
    assert 'CODEX_HOME="$CODEX_HOME"' in text


def test_release_probe_checks_codex_binary_and_pin() -> None:
    text = _read(PROBE)
    assert "probe_codex()" in text
    assert "require_binary codex" in text
    assert "codex --version" in text
    assert "CODEX_VERSION" in text
    assert re.search(r"^probe_codex$", text, flags=re.MULTILINE)


def test_post_job_cleanup_protects_codex_volume() -> None:
    text = _read(POST_JOB)
    assert "titan-runner-codex" in text
    assert (
        "titan-runner-state|titan-runner-work|titan-runner-browser|titan-runner-codex"
        in text
    )


def test_codex_relogin_recovery_is_documented() -> None:
    text = _read(DOC)
    assert "docker compose exec --user runner runner codex login --device-auth" in text
    assert "docker compose exec --user runner runner codex login status" in text
    assert "docker compose down -v" in text
    assert "Deleting it only logs Codex out" in text
    assert "No OpenAI API key is required" in text
