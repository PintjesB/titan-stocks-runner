# titan-stocks-runner

Public repository that owns the persistent ARM64 GitHub Actions runner
for [PintjesB/titan-stocks](https://github.com/PintjesB/titan-stocks).

* **Image** &mdash; an Ubuntu 24.04 ARM64 image that carries the
  Docker CLI, Compose v2 plugin, Buildx, the GitHub CLI, ShellCheck,
  PostgreSQL client, Node 24, Python 3.12, the Playwright Chromium
  system dependencies (`libcairo2` and `libpangocairo` included),
  `gosu`, and the GitHub Actions Runner binary pinned by SHA-256.
* **Lifecycle** &mdash; a small set of shell scripts that operators
  invoke on the dedicated CI host through `deploy.sh` (`build`,
  `probe`, `register`, `up`, `down`, `status`, `logs`).
* **Contract tests** &mdash; focused Python and shell tests that pin
  the documented operator contract.
* **Publishing** &mdash; a single `publish` workflow that builds the
  real `linux/arm64` image, gates publication on a capability probe
  that runs inside the built image, then pushes
  `ghcr.io/pintjesb/titan-stocks-runner:latest`. The CI surface is a
  hosted `ubuntu-24.04-arm` build; the published digest surfaces in
  the workflow output so deployments pin `latest@sha256:<digest>`.

The image is publicly pullable. Running the container still requires
the operator to supply a GitHub Actions registration token *once*;
the project does not include any reusable source code, so it ships
without a `LICENSE` file and without an OCI license label. **No
reproduction or reuse rights are granted by publication.**

## Architecture at a glance

The runner separates immutable image contents, persistent runner
identity, and disposable materialised runtime so a container can be
recreated without touching GitHub:

```
GHCR image                        /opt/actions-runner
  immutable binaries and tools    (read-only image layer)
        |
        v
runner container
  disposable materialised tree    /var/lib/titan-runner/runtime/
        |  (cp -a $RUNNER_ROOT/. $RUNTIME_DIR at every start)
        |
        +--- titan-runner-state volume      GitHub identity
        |    /var/lib/titan-runner/state/
        |      .runner
        |      .credentials
        |      .credentials_rsaparams
        |      diagnostics.txt
        |
        +--- /var/lib/titan-runner/work/    host bind mount
        |                                    same path inside + outside
        |                                    so child service containers
        |                                    can publish on host fs
        |
        +--- titan-runner-browser volume    Playwright cache
        |                                    seeded from the baked
        |                                    image cache on first start
        |
        +--- /var/run/docker.sock/          host bind mount
                                             daemon access as supplemental group
```

Three lifecycle phases map to three entrypoints. The image is
configured with `tini -> start-runner` by default; `deploy.sh`
overrides the entrypoint for the one-shot phases:

* `deploy.sh probe`     &rarr; `docker run --entrypoint /usr/local/bin/probe`
* `deploy.sh register`  &rarr; `docker run --entrypoint /usr/local/bin/register`
* `deploy.sh up`        &rarr; `docker compose up` (default entrypoint)

## Quick start (dedicated CI host)

Prepare the host once. Only the `_work` directory is a host bind
mount; the persistent `state` and `browser` storage are Docker-named
volumes that Compose creates automatically.

```bash
sudo install -d -m 0750 -o 1001 -g 1001 /var/lib/titan-runner/work
sudo install -d -m 0700 /run/secrets
```

Then:

1. Fetch a short-lived registration token from GitHub:

   ```bash
   gh api -X POST \
     repos/PintjesB/titan-stocks/actions/runners/registration-token \
     | jq -r .token > /run/secrets/titan-runner-registration-token
   chmod 0600 /run/secrets/titan-runner-registration-token
   ```

2. Register the runner once. The sidecar consumes the token and
   writes the persistent credentials into `titan-runner-state`:

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

4. Start the persistent listener. The token file is *not* mounted
   on the long-running container; the runner authenticates with the
   GitHub-issued long-lived secret persisted by `register`:

   ```bash
   TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest> \
   TITAN_RUNNER_REPO_URL=https://github.com/PintjesB/titan-stocks \
       ./deploy.sh up
   ```

5. Confirm the listener is online and registered:

   ```bash
   ./deploy.sh status
   ./deploy.sh logs --tail=50
   ```

6. After a host reboot or a container restart the listener returns
   online without another registration token. Only an image upgrade
   or a credential rotation touches the secret store again.

## Documentation

* [docs/quick-start.md](docs/quick-start.md) &mdash; the bootstrap
  recipe in narrative form.
* [docs/operations.md](docs/operations.md) &mdash; `deploy.sh`
  reference, lock file, status reporting, image upgrades, rollback.
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
| Architecture | `linux/arm64` only &mdash; `deploy.sh` aborts on non-ARM64 hosts |
| Host | Ubuntu 24.04 ARM64 with Docker Engine, Compose v2 plugin, Buildx |
| Network | `network_mode: host`; the runner shares the host network namespace |
| IPC | `ipc: host` so Playwright can share the host IPC namespace |
| Privileges | `no-new-privileges:true`; `privileged: false`; no DinD |
| Docker socket | bind-mounted read/write; the socket's host GID is granted as a *supplemental* group to the runner user inside the container |
| Registration | persistent listener; `--disableupdate` set at registration; updates only ship through a tested image release |
| State | `titan-runner-state` volume holds the Actions runner credentials |
| Runtime | disposable materialised tree at `/var/lib/titan-runner/runtime/`; rebuilt on every container start |
| Work | host bind mount at `/var/lib/titan-runner/work` &mdash; identical path inside and outside so child service containers share the workspace |
| Browser | `titan-runner-browser` volume holds the Playwright cache; seeded from the baked image cache on first start |
| Lifecycle lock | `flock /var/lock/titan-runner.lock` around `register`, `up`, `down` |
| Image pin | every deployment references `ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest>` |
| Host rotation | rotate the host by preserving the `titan-runner-state` volume and `/var/lib/titan-runner/work`; no new token is required |

## Repository hygiene

* No LICENSE file. The image is publicly pullable; no reuse rights
  are granted.
* No OCI license label.
* The Compose contract is generic &mdash; it accepts the consumer
  repository URL, runner name, and labels through deployment
  environment variables. The Titan Stocks repository is the default
  in the documentation examples; nothing else hardcodes that
  relationship.
* `.dockerignore` excludes everything except the scripts and
  Dockerfile so every published layer is minimal.
* The hosted `publish` workflow runs on `ubuntu-24.04-arm`, gates
  publication on the image's capability probe, then pushes
  `:latest`. CI does not depend on the runner image itself.

## Related repositories

* [PintjesB/titan-stocks](https://github.com/PintjesB/titan-stocks)
  &mdash; the private consumer application; every workflow targets
  the `[self-hosted, linux, ARM64, titan-ci]` label group.
