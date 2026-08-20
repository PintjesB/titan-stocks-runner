# Self-hosted GitHub runners

Central repository for the self-hosted GitHub Actions runner images operated by PintjesB.

The repository is organized by runner profile. Each profile owns its image, Compose deployment, lifecycle scripts, tests, and documentation so repositories use only the capabilities they actually need.

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
    ci-contract.sh
    scripts/
    tests/
    docs/
  oportunist/
    Dockerfile
    docker-compose.yml
    ci-contract.sh
    scripts/
.github/workflows/
  _publish-runner.yml
  publish-titan.yml
  publish-oportunist.yml
  validate.yml
docs/
  compose-migration.md
```

## CI and publication

Pull requests that touch runner profiles or workflow files run the profile contracts before merge. Publication uses one reusable hardened workflow for both images:

1. Run the profile contract.
2. Build native `linux/amd64` and `linux/arm64` candidates.
3. Probe each candidate on a matching native hosted runner.
4. Pass exact registry digests between jobs through workflow artifacts.
5. Merge the exact candidate digests and validate the merged platform set.
6. Probe the merged manifest on both native architectures.
7. Attach provenance to the immutable merged digest.
8. Promote that exact digest to `:latest` and verify the registry-served digest matches.

The reusable workflow deliberately tolerates the known Buildx case where `imagetools create` can return non-zero after the registry accepted the manifest. The remote merged-manifest postcondition remains authoritative.

## Design rules

- Runner profiles are independently buildable and deployable.
- Profile-specific dependencies stay inside that profile.
- Persistent runner identity, workspaces, and Codex authentication use Docker named volumes.
- Codex authentication is replaceable state: if its volume is deleted, authenticate again with `codex login --device-auth`.
- Images remain pinned and tested before publication.
- The dedicated CI VM is the security boundary for runners that receive the host Docker socket.

## Deployment migration

Existing runner containers do not stop because this source repository was reorganized or renamed. However, update deployment Compose files before adopting Codex or refreshing image pins. See [Compose migration after the runner repository split](docs/compose-migration.md).

The repository has already been renamed to `PintjesB/github-runners`. GitHub redirects the old repository URL, while the GHCR image names intentionally remain unchanged.
