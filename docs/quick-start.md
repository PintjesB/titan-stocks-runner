# Quick start

This procedure covers the first-time deployment of a persistent
`PintjesB/titan-stocks` runner on a dedicated CI host. The host must
already run Docker Engine with the Compose v2 plugin and Buildx
available on the `PATH`.

## 1. Bootstrap a short-lived registration token

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
output, or a HashiCorp Vault read are equally valid; the
`register.sh` script just needs a 0600 file at the path it is given.

## 2. Pull the image

The image is published as `ghcr.io/pintjesb/titan-stocks-runner:latest`.
Resolve the immutable digest that backs the tag, then pin by digest:

```bash
docker buildx imagetools inspect ghcr.io/pintjesb/titan-stocks-runner:latest
docker pull ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest>
```

Any host that can pull from `ghcr.io` can resolve the digest. The
image is public precisely so the digest pin is decoupled from any
GitHub App installation.

## 3. Register once and persist credentials

The `register` action is a one-shot sidecar. It consumes the token
file, registers as a persistent listener with `--disableupdate`,
and copies the resulting `.runner` and `.credentials*` files into
the `titan-runner-state` named volume. The volume outlives the
sidecar so subsequent starts do not need a token.

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
* The image does not contain the `RUNNER_ROOT` binaries.
* The Docker socket is missing (no fallback is possible).

When the sidecar exits, `deploy.sh register` returns 0 and prints a
`registration complete` line.

## 4. Shred the bootstrap token

The registration used a one-time credential. Delete it:

```bash
shred -u /run/secrets/titan-runner-registration-token
```

The persisted credentials are stored in
`titan-runner-state:/var/lib/titan-runner/state/.credentials`.
Re-issuing a token is only required when the host rotates the
registration, when the repository is transferred, when GitHub
invalidates the credentials (after 30 days of inactivity), or when
the host is rebuilt from scratch.

## 5. Start the persistent listener

The `up` action refuses to start without configured state, so the
runner never boots into a loop that asks GitHub for a fresh token.

```bash
TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest> \
TITAN_RUNNER_REPO_URL=https://github.com/PintjesB/titan-stocks \
    ./deploy.sh up
```

The container restarts on host reboot because the deployment uses
`restart: unless-stopped`. The GitHub-issued long-lived secret in
`/var/lib/titan-runner/state/.credentials` covers every restart; the
runner never asks for a new token unless an operator explicitly
re-runs `register`.

## 6. Confirm the listener

The `status` subcommand surfaces both the container state and the
IDs of the persisted volumes:

```bash
./deploy.sh status
./deploy.sh logs --tail=200 --follow
```

In the GitHub UI the runner appears under the repository's
**Settings &rarr; Actions &rarr; Runners** list with the configured
name and the
`self-hosted`, `linux`, `ARM64`, `titan-ci` labels.

## 7. Tear down (host rotation)

When a host is rotated, the state volume is the only piece that
must be preserved:

```bash
# Old host: stop the container, do NOT delete the volume.
./deploy.sh down
docker volume inspect titan-runner-state

# New host: re-create the volume from the backup, then `up` without
# re-registering.
docker volume create titan-runner-state
docker run --rm \
    -v titan-runner-state:/data \
    -v "$PWD/state-backup":/backup:ro \
    alpine:3.20 cp -a /backup/. /data/
TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest> \
TITAN_RUNNER_REPO_URL=https://github.com/PintjesB/titan-stocks \
    ./deploy.sh up
```

A token is only necessary when the state volume is empty.
