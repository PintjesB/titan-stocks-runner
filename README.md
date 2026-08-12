# titan-stocks-runner

Public repository that owns the persistent ARM64 GitHub Actions runner
for [PintjesB/titan-stocks](https://github.com/PintjesB/titan-stocks).

* **Image** &mdash; an Ubuntu 24.04 ARM64 image that carries the
  Docker CLI, Compose v2 plugin, Buildx, the GitHub CLI, ShellCheck,
  PostgreSQL client, Node 24, Python 3.12, the Playwright Chromium
  system dependencies, `gosu`, and the GitHub Actions Runner binary
  pinned by SHA-256.
* **Lifecycle** &mdash; a small set of shell scripts that operators
  invoke on the dedicated CI host through `deploy.sh` (`build`,
  `probe`, `register`, `up`, `status`, `logs`, `down`).
* **Contract tests** &mdash; focused Python and shell tests that pin
  the documented operator contract.
* **Publishing** &mdash; a single `publish` workflow that builds and
  pushes the public `linux/arm64` image as
  `ghcr.io/pintjesb/titan-stocks-runner:latest`. The CI surface is a
  hosted `ubuntu-24.04-arm` build; a successful build is the
  validation step. The published digest is reported in the workflow
  output so deployments can pin `latest@sha256:<digest>`.

The image is publicly pullable. Running the container still requires
the operator to supply a GitHub Actions registration token; the
project does not include any reusable source code, so it ships
without a `LICENSE` file and without an OCI license label. **No
reproduction or reuse rights are granted by publication.**

## Quick start (dedicated CI host)

1. Fetch a short-lived registration token from GitHub:

   ```bash
   gh api -X POST \
     repos/PintjesB/titan-stocks/actions/runners/registration-token \
     | jq -r .token > /run/secrets/titan-runner-registration-token
   chmod 0600 /run/secrets/titan-runner-registration-token
   ```

2. Pull the image and register the runner once:

   ```bash
   TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest> \
   TITAN_RUNNER_REPO_URL=https://github.com/PintjesB/titan-stocks \
   TITAN_RUNNER_TOKEN_FILE=/run/secrets/titan-runner-registration-token \
       ./deploy.sh register
   ```

3. Delete the bootstrap token file so it cannot be re-used:

   ```bash
   shred -u /run/secrets/titan-runner-registration-token
   ```

4. Start the persistent listener (the same image digest, no token
   required &mdash; the credentials persisted by `register` are
   mounted from the `titan-runner-state` volume):

   ```bash
   TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest> \
   TITAN_RUNNER_REPO_URL=https://github.com/PintjesB/titan-stocks \
       ./deploy.sh up
   ```

5. Confirm the listener is online:

   ```bash
   ./deploy.sh status
   ./deploy.sh logs --tail=50
   ```

6. After a reboot or a container restart the listener returns
   online without another registration token. The credentials in
   `titan-runner-state` carry the GitHub-issued long-lived secret;
   only an image upgrade or a credential rotation touches the
   secret store again.

## Documentation

* [docs/quick-start.md](docs/quick-start.md) &mdash; the bootstrap
  recipe in narrative form.
* [docs/operations.md](docs/operations.md) &mdash; `deploy.sh`
  reference, health checks, image upgrades, rollback.
* [docs/security.md](docs/security.md) &mdash; the host boundary,
  registration-token handling, and what the Docker socket
  permissions actually mean.
* [docs/upgrade-and-rollback.md](docs/upgrade-and-rollback.md)
  &mdash; how to refresh the runner image and how to roll back to a
  previous digest.
* [docs/troubleshooting.md](docs/troubleshooting.md) &mdash; failure
  triage for the documented failure modes.

## Operator contract

| Item | Value |
| --- | --- |
| Architecture | `linux/arm64` only |
| Host | Ubuntu 24.04 ARM64 with the Docker Engine, Compose v2 plugin, and Buildx installed |
| Network | `network_mode: host`; the runner shares the host network namespace |
| IPC | `ipc: host` so Playwright can share the host IPC namespace |
| Privileges | `no-new-privileges:true`; `privileged: false`; no DinD |
| Docker socket | bind-mounted read/write; the socket's host GID is granted as a *supplemental* group to the runner user inside the container |
| Registration | persistent listener; `--disableupdate`; updates only ship through a tested image release |
| State | `titan-runner-state` volume holds the Actions runner credentials; `titan-runner-work` holds the `_work` workspace; `titan-runner-browser` holds the Playwright cache |
| Image pin | every deployment references `ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest>` |
| Host rotation | rotate the host by reading the persisted state volume, redeploying the image, and pointing the new host at the same volume. No new token is required. |

## Repository hygiene

* No LICENSE file. The image is publicly pullable; no reuse rights
  are granted.
* No OCI license label.
* The Compose contract is generic &mdash; it accepts the consumer
  repository URL, runner name, and labels through deployment
  environment variables. The Titan Stocks repository is the default
  in the documentation examples; nothing else hardcodes that
  relationship.
* `.dockerignore` excludes everything except the documentation,
  scripts, and Dockerfile so every published layer is minimal.
* The hosted `publish` workflow runs on
  `ubuntu-24.04-arm` so CI does not depend on the runner image
  itself.

## Related repositories

* [PintjesB/titan-stocks](https://github.com/PintjesB/titan-stocks)
  &mdash; the private consumer application; every workflow targets
  the `[self-hosted, linux, ARM64, titan-ci]` label group.
