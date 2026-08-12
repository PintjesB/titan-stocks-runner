# Troubleshooting

The runner surfaces failure modes through three channels: a failing
healthcheck, a non-zero exit from `deploy.sh`, and an `Offline`
status in the GitHub UI under **Settings &rarr; Actions &rarr;
Runners**. The list below covers the documented failure modes.

## Architecture mismatch

```
ERROR: titan-stocks-runner requires an ARM64 host (got x86_64)
```

`deploy.sh` only runs on ARM64 hosts. The image is `linux/arm64`;
running it on x86_64 would fall back to emulation and break every
binary that expects native ARM64. Use an ARM64 host.

## Registration token file is not mode 0600

```
Token file must be mode 0400 or 0600 (got 0XXX)
```

The host file is readable by another user or group. Reset the mode:

```bash
chmod 0600 /run/secrets/titan-runner-registration-token
```

## Listener is already running when registering

```
titan-runner listener is already running as <id>.
Run ./deploy.sh down before re-registering.
```

The `register` sidecar refuses to run while the listener container
is up; the new credentials would not reach the running listener
until its next restart. Stop the listener first:

```bash
./deploy.sh down
./deploy.sh register
./deploy.sh up
```

## State volume has no persisted credentials

```
State volume has no persisted credentials.
Run ./deploy.sh register first.
```

The `up` action refuses to start without configured state. Run
`deploy.sh register` once, then re-run `deploy.sh up`.

## Listener binary missing from image

```
ERROR: image-owned runner binaries missing from /opt/actions-runner; rebuild the image
```

The image did not include the fetched Actions runner tarball.
Confirm the digest matches the published digest and re-pull:

```bash
docker pull ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest>
```

If the digest does not match the local image, clear the daemon
cache and re-pull.

## Docker CLI fails with permission denied inside the listener

```
permission denied while trying to connect to the Docker daemon socket
```

The host socket's group ID has not been granted to the runner user.
Inspect the diagnostic log:

```bash
./deploy.sh logs --tail=200 | grep -i 'docker group'
```

The expected line is
`adding runner user to supplemental group GID=<N>`. A missing line
indicates the socket is not present at `/var/run/docker.sock`
inside the container. Check the host:

```bash
ls -l /var/run/docker.sock
docker compose version
```

A `g+rwx` socket group mode is required. After fixing the host
socket permissions, recreate the container so the supplemental
group mapping applies:

```bash
./deploy.sh up
```

## `npx playwright install --with-deps` failed with sudo prompt

The application workflow is trying to install OS packages at job
time. The runner image already carries the Playwright system
dependencies (`libcairo2`, `libpangocairo-1.0-0t64`, and friends);
remove `--with-deps` from the workflow and rerun. The
`runner-smoke` workflow in `PintjesB/titan-stocks` installs the
application from `frontend/package-lock.json` and uses the bundled
Chromium binary; `--with-deps` is not part of the contract.

## `shellcheck: command not found`

The job is running on a different runner. Confirm the runner's
labels match the consumer workflow:

```bash
./deploy.sh status
gh api repos/PintjesB/titan-stocks/actions/runners | \
  jq '.runners[] | {name, labels: [.labels[].name]}'
```

A missing row means the listener is offline; re-run `deploy.sh up`.

## Healthcheck fails

`docker inspect --format '{{json .State.Health}}'` shows the failing
probe step. Re-run the probe interactively:

```bash
TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest> \
    ./deploy.sh probe
```

## Listener exits non-zero and restarts

`deploy.sh logs` shows `listener exited non-zero`. The most common
causes are:

* the credentials in `.credentials` were invalidated by GitHub
  (typically after more than 30 days of inactivity). Re-run
  `deploy.sh register` with a fresh token.
* the host lost network connectivity to
  `*.actions.githubusercontent.com`. Confirm the firewall and re-run
  `deploy.sh up`.
* the host lost connectivity to the Docker daemon. Restart the
  daemon and recreate the container.

## Anonymous pull fails

```bash
docker pull ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest>
# error: requested access to the resource is denied
```

GitHub creates personal-account GHCR packages as private by default.
Open
[`PintjesB/titan-stocks-runner`'s package settings](https://github.com/users/PintjesB/packages/container/titan-stocks-runner/settings),
choose **Danger Zone &rarr; Change package visibility**, and set it
to **Public**. The setting is one-time; subsequent publishes keep the
public visibility automatically. After the change, retry the pull.

## Lifecycle lock contention

```
Another lifecycle command is already running.
```

Another `deploy.sh register`, `up`, or `down` is in flight, or a
stale lock file at `/var/lock/titan-runner.lock` was not released.
Inspect with:

```bash
sudo fuser /var/lock/titan-runner.lock
```

If no `deploy.sh` process holds the lock, remove the stale file and
re-run.

## Anonymous manifests show only `linux/arm64`

```bash
docker buildx imagetools inspect ghcr.io/pintjesb/titan-stocks-runner:latest
```

The manifest list reported by the registry must contain a single
`linux/arm64` entry. If it shows `linux/amd64` the published image
is from a different platform; re-trigger the `publish` workflow
on `main` to overwrite `:latest` with the correct ARM64 build.
