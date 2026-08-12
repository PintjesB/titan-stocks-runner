# Operations

This document is the operator-facing reference for `deploy.sh` and
the persistent runner.

## `deploy.sh` reference

`deploy.sh` is a thin wrapper around `docker buildx` and
`docker compose`. It accepts seven subcommands:

| Subcommand | Purpose | Required env |
| --- | --- | --- |
| `build`   | Build the `linux/arm64` image with Buildx, load into the local Docker daemon, and tag it with the value of `TITAN_RUNNER_IMAGE`. | `TITAN_RUNNER_IMAGE` |
| `probe`   | Run `probe.sh` in a one-shot container with the Docker socket bind-mounted read/write. Confirms every documented capability without registering. | `TITAN_RUNNER_IMAGE` |
| `register`| Run `register.sh` in a one-shot sidecar. Persists the runner credentials to the `titan-runner-state` volume. Consumes the token file. | `TITAN_RUNNER_IMAGE`, `TITAN_RUNNER_REPO_URL`, `TITAN_RUNNER_TOKEN_FILE` |
| `up`      | Start the persistent listener through the Compose contract. Refuses to start without configured state. | `TITAN_RUNNER_IMAGE`, `TITAN_RUNNER_REPO_URL` |
| `status`  | Print the container state, the persisted volume IDs, and the registered runner name from `~/.runner`. | &mdash; |
| `logs`    | Tail the runner logs (`docker compose logs`). | &mdash; |
| `down`    | Stop the listener and remove orphaned containers. Does NOT delete the state, work, or browser volumes. | &mdash; |

Every subcommand refuses to run if the required environment is
missing.

## Persistent state layout

`register.sh` writes three files into
`RUNNER_STATE_DIR` (default `/var/lib/titan-runner/state`):

* `.runner` &mdash; the Actions runner registration manifest.
* `.credentials` &mdash; the GitHub-issued long-lived secret used by
  `run.sh --start` to authenticate against GitHub.
* `diagnostics.txt` &mdash; a sanitised bundle with the registered
  repository URL, the runner name, and the label list. The bundle
  never contains the registration token or the credentials.

The work volume (`RUNNER_WORK_DIR`) holds the upstream `_work`,
`_diag`, and `_data` directories. The browser volume
(`RUNNER_BROWSER_DIR`) is bind-mounted from inside the runner user's
home so `npx playwright install chromium` only downloads binaries
once.

The listener refuses to start if `.runner` or `.credentials` is
missing from the state volume. The `up` action performs the same
check before it invokes Compose.

## Health check

The Compose configuration wires `/usr/local/bin/probe --skip-network`
into the `HEALTHCHECK` directive. The probe re-uses the image's
documented capability checks (Docker daemon reachability, Compose v2
plugin, Buildx, Node 24, Python 3.12, Playwright Chromium), but it
skips the GitHub API probe because the listener does not need
network reachability to remain in a healthy state. A failing
healthcheck means the runner cannot service any job and the host
should investigate.

## Updating labels

The capability label list is configured per host, not per image.
Edit `TITAN_RUNNER_LABELS` and re-run `register`. The `register`
sidecar invokes the upstream `config.sh` with `--replace`, so the
existing registration is removed before the new one is created. The
state volume is preserved &mdash; only the metadata in `.runner`
changes.

## Rotating the repository URL

To migrate the runner to a new repository (for example, after a
GitHub repository rename), re-run `register` with the new
`TITAN_RUNNER_REPO_URL`. The GitHub-issued secret in `.credentials`
is invalidated by GitHub whenever the registration moves between
repositories, so a fresh token is required.

## Replacing the host

See [quick-start.md &sect; 7](quick-start.md#7-tear-down-host-rotation).
The `state` volume is the only piece that must be preserved; the
`work` and `browser` volumes are convenience caches and can be
discarded.
