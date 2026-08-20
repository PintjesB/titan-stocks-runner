# Self-hosted GitHub runners

Central repository for the self-hosted GitHub Actions runner images operated by PintjesB.

The repository is intentionally organized by runner profile. Each profile owns its image, Compose deployment, lifecycle scripts, tests, and documentation so repositories can use only the capabilities they actually need.

## Runner profiles

| Profile | Purpose | Image |
| --- | --- | --- |
| [`titan`](runners/titan/) | Titan Stocks CI, including Docker tooling, Python, PostgreSQL client, Playwright/Chromium, and Codex | `ghcr.io/pintjesb/titan-stocks-runner` |
| [`oportunist`](runners/oportunist/) | Oportunist CI and Codex automation with a lean Python/Docker toolchain | `ghcr.io/pintjesb/oportunist-runner` |

Additional profiles should be added under `runners/<name>/` rather than expanding every image with unrelated dependencies.

## Repository layout

```text
runners/
  titan/
    Dockerfile
    docker-compose.yml
    deploy.sh
    scripts/
    tests/
    docs/
  oportunist/
    Dockerfile
    docker-compose.yml
    scripts/
.github/workflows/
  publish-titan.yml
  publish-oportunist.yml
```

## Design rules

- Runner profiles are independently buildable and deployable.
- Profile-specific dependencies stay inside that profile.
- Persistent runner identity, workspaces, and Codex authentication use Docker named volumes.
- Codex authentication is replaceable state: if its volume is deleted, authenticate again with `codex login --device-auth`.
- Images remain pinned and tested before publication.
- The dedicated CI VM is the security boundary for runners that receive the host Docker socket.

## Titan runner

The existing Titan runner lives under [`runners/titan/`](runners/titan/). See its [README](runners/titan/README.md) for deployment and operations.

## Oportunist runner

The Oportunist profile lives under [`runners/oportunist/`](runners/oportunist/). It intentionally omits Titan-only browser and PostgreSQL tooling while retaining Docker, Python, Node, GitHub CLI, and Codex.

## Repository rename

This repository is being prepared to become the central runner repository. Renaming the GitHub repository itself is intentionally separate from the file-layout change so GitHub redirects and GHCR image names can be handled explicitly.
