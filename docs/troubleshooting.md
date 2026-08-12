# Troubleshooting

The runner surfaces failure modes through two channels: a failing
healthcheck and a non-zero exit from `deploy.sh`. The list below
covers the documented failure modes; everything else is treated as
host-level degradation and surfaces in `deploy.sh logs`.

## Registration token file is not mode 0600

```
register: ERROR: RUNNER_TOKEN_FILE must be mode 0400 or 0600 (got 0XXX)
```

The host file is readable by a different user or group. Reset the
mode and re-run:

```bash
chmod 0600 /run/secrets/titan-runner-registration-token
```

## `register` aborts with `runner binaries missing from /opt/actions-runner`

The image is incomplete. Confirm the digest resolves and re-pull:

```bash
docker pull ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest>
docker image inspect <digest> --format '{{.Id}}'
```

If the digest does not match the pulled image, clear the daemon
cache and re-pull.

## Listener refuses to start with `missing persisted credential file`

The state volume is empty. Run the registration phase:

```bash
TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest> \
TITAN_RUNNER_REPO_URL=https://github.com/PintjesB/titan-stocks \
TITAN_RUNNER_TOKEN_FILE=/run/secrets/titan-runner-registration-token \
    ./deploy.sh register
```

After the sidecar returns 0, delete the token file and re-run
`deploy.sh up`.

## Docker CLI fails with `permission denied while trying to connect to the Docker daemon socket`

The host socket's group ID has not been granted to the runner user.
Confirm the supplemental group:

```bash
./deploy.sh logs --tail=200 | grep -i 'docker group'
```

The expected log line is `adding runner user to supplemental group
GID=<N>`. A missing line indicates the socket is not present at
`/var/run/docker.sock` inside the container; check the host:

```bash
ls -l /var/run/docker.sock
docker compose version
```

A `g+rwx` socket group mode is required. If the host socket is
present and the GID matches, recreate the container so the
supplemental group mapping applies:

```bash
./deploy.sh up
```

## `playwright install chromium` runs at job time and fails with `sudo: a password is required`

The application workflow is using `npx playwright install --with-deps`.
The runner image already carries the Playwright system dependencies,
so the workflow must drop `--with-deps`. The runner-smoke workflow in
`PintjesB/titan-stocks` installs the application from
`frontend/package-lock.json` and uses the bundled Chromium binary;
the `--with-deps` flag is not part of the contract.

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
  `deploy.sh register`.
* the host lost network connectivity to `*.actions.githubusercontent.com`.
  Confirm the firewall and re-run `deploy.sh up`.
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

## Cycle: container restarts, then drains immediately

A stale `docker compose` project references the same volume with an
incompatible contract. Recreate the project:

```bash
docker compose -p titan-runner down --remove-orphans --volumes=false
./deploy.sh up
```

Persistent volumes are preserved; the recreate still reuses the
existing `titan-runner-state`.
