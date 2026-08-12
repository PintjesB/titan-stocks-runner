# Quick start

This procedure covers the first-time deployment of a persistent
`PintjesB/titan-stocks` runner on a dedicated CI host. The host must
already run Docker Engine with the Compose v2 plugin and Buildx
available on the `PATH`.

## 1. Prepare host paths

The runner distinguishes three storage tiers; pre-create the host
paths once:

```bash
sudo install -d -m 0750 -o 1001 -g 1001 \
    /var/lib/titan-runner/state \
    /var/lib/titan-runner/runtime \
    /var/lib/titan-runner/work \
    /var/lib/titan-runner/browser
```

* **`state`** — persistent. Holds the GitHub-issued Actions runner
  credentials and a sanitised diagnostics summary.
* **`runtime`** — disposable. Materialised from the image on every
  container start; recreated by `start-runner.sh`.
* **`work`** — host bind mount. Used as GitHub's `_work` directory.
  The same absolute path **must** exist inside the container so the
  host Docker daemon can publish child service-container artefacts
  into the runner's checkout.
* **`browser`** — persistent. Holds the Playwright Chromium cache.

## 2. Bootstrap a short-lived registration token

GitHub registration tokens are valid for about an hour. The token is
read once by the `register` lifecycle phase and then deleted; it is
never stored in the image or in the state volume.

```bash
install -d -m 0700 /run/secrets
gh api -X POST \
  repos/PintjesB/titan-stocks/actions/runners/registration-token \
  | jq -r .token > /run/secrets/titan-runner-registration-token
chmod 0600 /run/secrets/titan-runner-registration-token
```

A SOPS-decrypted file, an AWS Secrets Manager `get-secret-value`
output, or a HashiCorp Vault read are equally valid.

## 3. Pull the image

The image is published as `ghcr.io/pintjesb/titan-stocks-runner:latest`.
Resolve the immutable digest that backs the tag, then pin by digest:

```bash
docker buildx imagetools inspect ghcr.io/pintjesb/titan-stocks-runner:latest
docker pull ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest>
```

## 4. Register once and persist credentials

`deploy.sh register` is a one-shot sidecar. It consumes the token
file, registers as a persistent listener with `--disableupdate`,
materialises a temporary runtime tree from the image, writes the
resulting credentials into `titan-runner-state`, then exits:

```bash
TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest> \
TITAN_RUNNER_REPO_URL=https://github.com/PintjesB/titan-stocks \
TITAN_RUNNER_NAME=titan-ci-host-1 \
TITAN_RUNNER_TOKEN_FILE=/run/secrets/titan-runner-registration-token \
    ./deploy.sh register
```

The sidecar refuses to run if:

* `TITAN_RUNNER_REPO_URL` is not set (the image refuses to
  hard-code the consumer).
* `TITAN_RUNNER_TOKEN_FILE` does not exist or is not mode `0600`.
* A `titan-runner` listener is already running — run
  `deploy.sh down` first.
* The image does not contain the `RUNNER_ROOT` binaries.

After successful registration the script logs the diagnostic summary
that is persisted to `state/diagnostics.txt`.

## 5. Shred the bootstrap token

The registration used a one-time credential. Delete it:

```bash
shred -u /run/secrets/titan-runner-registration-token
```

The persisted credentials live in
`titan-runner-state:/var/lib/titan-runner/state/.credentials`. A
fresh token is only required when the host is rebuilt from scratch
or when GitHub invalidates the secret (typically after more than 30
days of inactivity).

## 6. Start the persistent listener

`deploy.sh up` refuses to start without configured state so the
runner never boots into a loop that asks GitHub for a fresh token.

```bash
TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest> \
TITAN_RUNNER_REPO_URL=https://github.com/PintjesB/titan-stocks \
    ./deploy.sh up
```

On start the listener:

1. Validates `state/.runner` and `state/.credentials` are present.
2. Grants the host Docker socket's group ID to the `runner` user as
   a **supplemental** group (the primary `runner` group is preserved).
3. Copies the immutable `RUNNER_ROOT` tree into
   `/var/lib/titan-runner/runtime` and overlays the persisted
   credentials onto it.
4. Launches the upstream `run.sh` directly via `gosu runner` with
   no runtime flags — `--disableupdate` is set at registration and
   persists in the `.runner` manifest.

The container restarts on host reboot because the deployment uses
`restart: unless-stopped`. The GitHub-issued long-lived secret in
`/var/lib/titan-runner/state/.credentials` covers every restart;
the token file is never mounted on the long-running container.

## 7. Confirm the listener

```bash
./deploy.sh status
./deploy.sh logs --tail=200 --follow
```

`deploy.sh status` reports the runner image digest, the listener
container and process state, the Docker socket reachability, the
state volume contents, and the token file presence.

In the GitHub UI the runner appears under **Settings &rarr; Actions
&rarr; Runners** with the configured name and the
`self-hosted`, `linux`, `ARM64`, `titan-ci` labels.

## 8. Tear down (host rotation)

When a host is rotated, **only the `state` volume and the host
work/browser paths must be preserved** — the runtime tree and the
running container are disposable.

```bash
# Old host: stop the container. State and work paths remain on disk.
./deploy.sh down

# New host: pre-create the directories, transfer /var/lib/titan-runner/state
# and /var/lib/titan-runner/{work,browser} (e.g. via rsync, btrfs send,
# or a backup volume), then start without re-registering.
sudo install -d -m 0750 -o 1001 -g 1001 \
    /var/lib/titan-runner/state \
    /var/lib/titan-runner/runtime \
    /var/lib/titan-runner/work \
    /var/lib/titan-runner/browser
# ... (restore state + work + browser) ...
TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest> \
TITAN_RUNNER_REPO_URL=https://github.com/PintjesB/titan-stocks \
    ./deploy.sh up
```

A token is only necessary when the `state` volume is empty.
