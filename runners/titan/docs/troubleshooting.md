# Troubleshooting

The runner surfaces failure modes through four channels: a
failing healthcheck, a non-zero exit from `deploy.sh` or
`docker compose up -d`, an `Offline` status in the GitHub UI
under **Settings &rarr; Actions &rarr; Runners**, or the
`PreJob.sh` hook failing at job start. The list below covers
the documented failure modes.

## Architecture mismatch

```
ERROR: titan-stocks-runner requires a native x86_64 or ARM64 host (got i686)
```

`deploy.sh` only runs on `x86_64` (`amd64`) or `aarch64`
(`arm64`) hosts. The image is published as a multi-platform
manifest with both `linux/amd64` and `linux/arm64` entries;
running it under emulation or on any other host architecture
would either fail the capability probe or break binaries that
expect native execution. Use a `x86_64` or `aarch64` host.

## Daemon / runner architecture mismatch

```
FAIL docker daemon architecture (amd64) does not match native runner architecture (arm64); emulated/mismatched daemons are rejected
```

The capability probe (and the pre-job hook) refuse a Docker
daemon whose reported architecture does not match the native
runner architecture. The VM is the security boundary; the
runner container reaches the daemon through the VM socket
directly so a daemon architecture mismatch means the VM is not
a native host for the runner. Confirm the VM is the matching
`x86_64` (for `linux/amd64`) or `aarch64` (for `linux/arm64`)
platform and re-run `deploy.sh probe`.

## Env file is missing or not mode 0600

```
Configured env file /path/.env does not exist.
Env file /path/.env must be mode 0400 or 0600 (got 0644).
```

`docker compose` and `deploy.sh` read the deployment variables
from a gitignored `.env` file consumed through an allowlist.
The file must be mode `0600` or stricter because
`TITAN_RUNNER_TOKEN` lives inside it.

```bash
chmod 0600 /path/.env
```

## Registration fails during `docker compose up -d`

```
titan-runner exited with status 2
```

The single runner container performs registration before starting
the listener. A non-zero exit means the persisted identity is
missing, partial, or has drifted and `TITAN_RUNNER_TOKEN` was empty
or unusable. Inspect the runner logs:

```bash
docker compose logs runner
```

The expected actionable messages are:

* `no persisted credentials found and RUNNER_TOKEN is empty.
  Set TITAN_RUNNER_TOKEN in the .env file and rerun 'docker
  compose up -d'.` &mdash; the state volume is empty; refresh
  the token and re-run.
* `persisted credentials have a different identity
  (existing_repo='…' requested_repo='…'). Set
  TITAN_RUNNER_TOKEN in the .env file and rerun 'docker
  compose up -d' to refresh them.` &mdash; the repository URL,
  runner name, or labels drifted; refresh the token and
  re-run.

The listener is launched only after the internal registration phase
succeeds, so the single container remains stopped (or retries under
`restart: unless-stopped`) after a failed registration. Re-run
`docker compose up -d` once the configuration is fixed.
The script never writes a backup unless it has a non-empty
token to attempt a re-registration; a missing-token failure
leaves the persistent state untouched.

## State volume has no persisted credentials

The previous failure mode is the only way this can happen on a
fresh deployment: the `titan-runner-state` volume was not
carried over from the previous host, or the volume was wiped.
Set `TITAN_RUNNER_TOKEN` in `.env` and re-run
`docker compose up -d`.

## Listener binary missing from image

```
ERROR: image-owned runner binaries missing from /opt/actions-runner; rebuild the image
```

The image did not include the fetched Actions runner tarball.
Confirm the digest matches the published digest and re-pull:

```bash
docker compose pull
```

If the digest does not match the local image, clear the daemon
cache and re-pull.

## Docker CLI fails with permission denied inside the listener

```
permission denied while trying to connect to the Docker daemon socket
```

The host socket's group ID has not been granted to the runner
user. Inspect the diagnostic log:

```bash
./deploy.sh logs --tail=200 | grep -i 'docker group'
```

The expected line is
`adding runner user to supplemental group GID=<N>`. A missing
line indicates the socket is not present at
`/var/run/docker.sock` inside the container. Check the host:

```bash
ls -l /var/run/docker.sock
docker compose version
```

A `g+rwx` socket group mode is required. After fixing the host
socket permissions, recreate the container so the supplemental
group mapping applies:

```bash
docker compose up -d
```

## Workflow cannot reach the service container

Workflow jobs that publish service containers onto the Docker
host must resolve the published port through
`host.docker.internal` rather than `localhost` or `127.0.0.1`.
The bridge network does not share the host's loopback.

```bash
# Inside a workflow job
PGPORT="${{ job.services.postgres.ports['5432'] }}"
psql -h host.docker.internal -p "$PGPORT" -U postgres
```

The `runner-smoke` workflow in `PintjesB/titan-stocks`
exercises the same pattern end-to-end and accepts
`RUNNER_ARCH=X64` or `RUNNER_ARCH=ARM64` so it can dispatch on
either compatible architecture.

## `host.docker.internal` does not resolve inside the listener

```
getent hosts host.docker.internal
# empty result
```

The listener is missing the `extra_hosts` mapping that wires
the host-gateway alias. Confirm `deploy.sh status` reports
`host-gateway : unresolved` and re-run:

```bash
docker compose up -d
```

The pre-job hook fails any workflow job while the alias is
unresolved so the host boundary is restored before the next
job starts.

## Listener reports the host network mode

```
network mode : host
```

The Compose contract requires `titan-runner-net` (a bridge
network) on the listener. A `host` mode report indicates the
Compose file was overridden by an external override; bring the
listener back to the canonical configuration:

```bash
docker compose up -d
```

## Pre-job hook fails

The pre-job hook validates that the Docker daemon's reported
architecture matches the native runner architecture, that the
Compose plugin, Buildx plugin, Node, Python, the
`host.docker.internal` alias, and the Playwright Chromium
cache are all available. The job fails before any workflow step
runs. Inspect the listener logs to identify the failing check:

```bash
./deploy.sh logs --tail=200 | grep -i pre-job
```

## `npx playwright install --with-deps` failed with sudo prompt

The application workflow is trying to install OS packages at
job time. The runner image already carries the Playwright
system dependencies (`libcairo2`, `libpangocairo-1.0-0`, and
friends); remove `--with-deps` from the workflow and rerun.
The `runner-smoke` workflow in `PintjesB/titan-stocks`
installs the application from
`frontend/package-lock.json` and uses the bundled Chromium
binary; `--with-deps` is not part of the contract.

## `shellcheck: command not found`

The job is running on a different runner. Confirm the runner's
labels match the consumer workflow:

```bash
./deploy.sh status
gh api repos/PintjesB/titan-stocks/actions/runners | \
  jq '.runners[] | {name, labels: [.labels[].name]}'
```

The custom-label list shrinks to `titan-ci` because GitHub
auto-attaches `self-hosted`, `linux`, and `X64` / `ARM64`
based on the listener's actual platform; the application
workflow selector `[self-hosted, linux, titan-ci]` matches
either architecture. A missing row means the listener is
offline; re-run `docker compose up -d`.

## Healthcheck fails

`docker inspect --format '{{json .State.Health}}'` shows the
failing probe step. Re-run the probe interactively:

```bash
./deploy.sh probe
```

## Listener exits non-zero and restarts

`deploy.sh logs` shows `listener exited non-zero`. The most
common causes are:

* the credentials in `.credentials` were invalidated by
  GitHub (typically after more than 30 days of inactivity).
  Refresh `TITAN_RUNNER_TOKEN` in `.env` and re-run
  `docker compose up -d`.
* the host lost network connectivity to
  `*.actions.githubusercontent.com`. Confirm the firewall and
  re-run `docker compose up -d`.
* the host lost connectivity to the Docker daemon. Restart
  the daemon and recreate the container.

## Anonymous pull fails

```bash
docker pull ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest>
# error: requested access to the resource is denied
```

GitHub creates personal-account GHCR packages as private by
default. Open
[`PintjesB/titan-stocks-runner`'s package settings](https://github.com/users/PintjesB/packages/container/titan-stocks-runner/settings),
choose **Danger Zone &rarr; Change package visibility**, and
set it to **Public**. The setting is one-time; subsequent
publishes keep the public visibility automatically. After the
change, retry the pull.

## Lifecycle lock contention

```
Another lifecycle command is already running.
```

Another `deploy.sh up` or `down` is in flight,
or a stale lock file at `/var/lock/titan-runner.lock` was not
released. Inspect with:

```bash
sudo fuser /var/lock/titan-runner.lock
```

If no `deploy.sh` process holds the lock, remove the stale
file and re-run.

## Manifest shows only one architecture

```bash
docker buildx imagetools inspect ghcr.io/pintjesb/titan-stocks-runner:latest
```

The manifest list reported by the registry MUST contain both
`linux/amd64` and `linux/arm64` entries. If it shows only one
platform the publish workflow either failed or did not run;
re-trigger the `publish` workflow on `main` to rebuild both
native candidates and merge them into a new multi-platform
manifest.

## Old offline GitHub runner entry persists

When migrating from an older one-shot registration flow to the
current `docker compose up -d` flow, the previous registration may
remain visible in the
GitHub UI under **Settings &rarr; Actions &rarr; Runners** as
an offline entry. The new registration re-uses the same runner
name and labels and cannot remove the old offline entry
through `--replace` if the underlying accounts differ; remove
the offline entry manually from the GitHub UI.

## `_work` directory accumulates entries

The runner `_work` directory lives in the persistent named volume
`titan-runner-work`. The post-job hook intentionally does NOT
recurse into it; cleanup only targets Compose projects whose name
matches `titan-stocks-playwright-`. Entries left by interrupted
jobs can remain after a restart. GitHub recreates checkout folders
as needed, and operators may inspect or remove stale entries inside
the volume during a maintenance window; automated cleanup must not
delete the runner-owned volume.
