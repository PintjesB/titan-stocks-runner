# Operations

This document is the operator-facing reference for `deploy.sh` and
the persistent runner.

## Storage tiers

The runner separates immutable image contents, persistent runner
identity, and disposable materialised runtime. Each tier is recreated
or refreshed independently so a container restart never has to fetch
a new registration token.

| Path | Storage | Owner | Mode | Persistent? |
| --- | --- | --- | --- | --- |
| `/opt/actions-runner` | Image-owned source tree | `root` | image default | immutable |
| `/var/lib/titan-runner/state` | named volume | `runner:runner` | `0750` | **yes** |
| `/var/lib/titan-runner/runtime` | writable dir in container | `runner:runner` | `0750` | **no** |
| `/var/lib/titan-runner/work` | host bind mount | `runner:runner` | `0750` | **yes** |
| `/var/lib/titan-runner/browser` | named volume | `runner:runner` | `0750` | **yes** |
| `/run/secrets/titan-runner-registration-token` | host 0600 file | `root` | `0600` | temporary |

The state directory holds `.runner`, `.credentials`,
`.credentials_rsaparams`, and a sanitised `diagnostics.txt`. The
runtime directory is wiped on every container recreation; the
credentials overlay it from state on the next start.

## `deploy.sh` reference

| Subcommand | Lock | Purpose |
| --- | --- | --- |
| `build`   | none | Build the `linux/arm64` image with Buildx and load it into the local daemon. |
| `probe`   | none | Run `probe.sh` in a one-shot container with the Docker socket bind-mounted. Uses `--entrypoint /usr/local/bin/probe`. |
| `register`| exclusive | Mount the token file read-only on a one-shot sidecar, run `register.sh`, persist credentials, then exit. Refuses if a listener is running. |
| `up`      | exclusive | Start the persistent listener through the Compose contract. Refuses unless `state/.credentials` exists. The token file is **not** mounted. |
| `down`    | exclusive | Stop the listener. State, runtime, work, and browser volumes remain on disk. |
| `status`  | none | Report runner image digest, container state, listener process, docker socket reachability, state volume contents, and token file presence. |
| `logs`    | none | Tail the runner logs (`docker compose logs`). |

Architecture check: `deploy.sh` aborts immediately unless
`uname -m` reports `aarch64` or `arm64`.

Lifecycle lock: `register`, `up`, and `down` take an exclusive flock
on `${TITAN_RUNNER_LOCK_FILE:-/var/lock/titan-runner.lock}`. `status`
and `logs` skip the lock so operators can inspect the deployment
while a long command runs in another shell.

## Persistent state layout

The `register` sidecar writes five files into `$RUNNER_STATE_DIR`
(default `/var/lib/titan-runner/state`) with strict permissions:

| File | Permission | Owner |
| --- | --- | --- |
| `.runner` | `0640` | `runner:runner` |
| `.credentials` | `0600` | `runner:runner` |
| `.credentials_rsaparams` | `0600` | `runner:runner` |
| `.runner_pkey` | `0600` | `runner:runner` (when generated) |
| `diagnostics.txt` | `0640` | `runner:runner` |

`diagnostics.txt` contains only the registered repository URL,
runner name, label list, paths, and the runner version. It never
contains the credentials or the registration token.

## Health check

The Compose contract wires `probe --skip-network` into the
`HEALTHCHECK` directive. The probe exercises the documented
capability checks (Docker daemon reachability, Compose v2 plugin,
Buildx, Node 24, Python 3.12, Playwright Chromium) but skips the
GitHub API check; transient GitHub outages must not trigger a
restart loop. A failing healthcheck means the runner cannot service
any job and the host should investigate.

## Updating labels

The capability label list is configured per host, not per image.
Edit `TITAN_RUNNER_LABELS`, run `deploy.sh down`, run
`deploy.sh register` (with a fresh token), then run `deploy.sh up`.
The registration uses `--replace`, so the existing GitHub
registration is removed before the new one is created.

## Rotating the repository URL

To migrate the runner to a new repository, run `register` with the
new `TITAN_RUNNER_REPO_URL`. The GitHub-issued secret in
`.credentials` is invalidated by GitHub whenever the registration
moves between repositories, so a fresh token is required.

## Detecting listener health

`deploy.sh status` queries the listener container directly:

* `Runner.Listener` process running inside the container.
* Docker socket reachability: `docker info` inside the container.
* Credentials file presence inside the container's state directory.

A red healthcheck, a missing listener process, or an inaccessible
socket indicates the listener cannot service jobs.

## Replacing the host

See [quick-start.md &sect; 8](quick-start.md#8-tear-down-host-rotation).
The `state` volume and the host `work`/`browser` paths are the only
pieces that must be preserved; the runtime tree and the running
container are disposable.
