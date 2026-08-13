# Quick start

This procedure covers the first-time deployment of a persistent
`PintjesB/titan-stocks` runner on a dedicated CI VM. The **VM is
the security boundary**: the runner container has unrestricted
access to the VM's Docker daemon, while the VM is isolated from
production systems and the rest of the private network. The
VM-level network isolation contract is documented in
[vm-deployment.md](vm-deployment.md); the acceptance checks in
that document MUST pass before the listener is brought up.

The image is published as a multi-platform manifest with both
native `linux/amd64` and `linux/arm64` entries; the VM can be
either architecture. The runner listener runs once on whichever
compatible `titan-ci` runner is available. `deploy.sh` maps the
host's `uname -m` output to the matching `linux/amd64` or
`linux/arm64` platform so a build, a probe, and a `docker run
--platform` invocation always resolve to a native architecture.

The VM must already run Docker Engine with the Compose v2 plugin
and Buildx on `PATH`. The VM firewall MUST follow the inbound
and outbound rules in [vm-deployment.md](vm-deployment.md)
before the first `docker compose up -d`.

## 1. Storage tiers

The runner uses four storage tiers. The persistent state and
browser storage tiers are Docker-named volumes that Compose
creates on the first `docker compose up -d`. The work directory
is an identical host/container bind mount whose source and target
both resolve to `${TITAN_RUNNER_WORK_DIR:-/var/lib/titan-runner/work}`;
Compose creates the host path on demand (the contract forbids a
named-volume workspace and rejects a bind mount whose source and
target differ).

* **`state`** &mdash; persistent Docker-named volume. Holds the
  GitHub-issued Actions runner credentials and a sanitised
  diagnostics summary. Compose creates the `titan-runner-state`
  volume on first `up`.
* **`browser`** &mdash; persistent Docker-named volume. Holds the
  Playwright Chromium browser cache. Compose creates the
  `titan-runner-browser` volume on first `up`; `start-runner.sh`
  seeds it from the baked image cache on the first start.
* **`work`** &mdash; identical host/container bind mount. Used as
  GitHub's `_work` directory. The source and target both resolve
  to `${TITAN_RUNNER_WORK_DIR:-/var/lib/titan-runner/work}` so the
  host Docker daemon's view of the workspace matches the
  listener's view. Compose creates the host path on demand; the
  registration sidecar establishes `runner:runner` ownership
  before the listener starts. Workflow service containers
  started by the host Docker daemon attach the same absolute
  path to share the runner's checkout.
* **`runtime`** &mdash; disposable. Materialised from the image on
  every container start by `start-runner.sh`. Lives only inside
  the listener container's writable layer.

## 2. Configure the deployment env file

`docker compose` and `deploy.sh` read the deployment variables
from a gitignored `.env` file (default: the runner repository's
`.env`). The file must be mode `0600`. Copy the committed template
and edit it:

```bash
cp .env.example .env
chmod 0600 .env
```

`docker compose` only interpolates the entries explicitly
referenced by the `docker-compose.yml` contract; arbitrary `.env`
entries do not reach the running services. The documented entries
are:

* `TITAN_RUNNER_IMAGE` &mdash; pinned image digest. The image is
  a multi-platform manifest; `docker compose pull` resolves the
  matching native platform for the VM's architecture.
* `TITAN_RUNNER_REPO_URL` &mdash; repository the runner targets.
* `TITAN_RUNNER_NAME` &mdash; display name (defaults to
  `titan-ci`).
* `TITAN_RUNNER_LABELS` &mdash; custom capability labels (defaults
  to `titan-ci`). GitHub automatically attaches `self-hosted`,
  `linux`, and `X64` / `ARM64` based on the listener's actual
  platform; the custom-label list intentionally omits them so a
  future architecture migration is a GitHub-side change rather
  than a `TITAN_RUNNER_LABELS` rotation.
* `TITAN_RUNNER_TOKEN` &mdash; short-lived registration token.
  Required only on the first `docker compose up -d` (or after a
  credential rotation); blank the line after successful
  registration and re-run `docker compose up -d`.
* Optional path overrides; defaults match the documented layout.

`deploy.sh` parses only the documented keys. Arbitrary entries
in the file are silently dropped; the file is never
shell-sourced.

## 3. Bootstrap a short-lived registration token

GitHub registration tokens are valid for about an hour. The token
is read once by the `register` Compose service, exported into the
one-shot sidecar as `RUNNER_TOKEN`, unset before `config.sh`
returns, and never persisted in the image, the state volume, or
the listener environment.

```bash
gh api -X POST \
  repos/PintjesB/titan-stocks/actions/runners/registration-token \
  | jq -r .token
```

Paste the token onto the `TITAN_RUNNER_TOKEN=` line in `.env`. A
SOPS-decrypted file, an AWS Secrets Manager `get-secret-value`
output, or a HashiCorp Vault read are equally valid; the value is
forwarded by Compose to the `register` service as `RUNNER_TOKEN`
and the shell never logs the literal value.

## 4. Pull the image

The image is published as
`ghcr.io/pintjesb/titan-stocks-runner:latest`, a multi-platform
manifest with both `linux/amd64` and `linux/arm64` entries.
Resolve the immutable digest that backs the tag, then pin by
digest:

```bash
docker buildx imagetools inspect ghcr.io/pintjesb/titan-stocks-runner:latest
docker pull ghcr.io/pintjesb/titan-stocks-runner@sha256:<digest>
```

`docker compose pull` resolves the matching native platform from
this single digest so a multi-platform manifest can be deployed
on either AMD64 or ARM64 VMs without re-tagging.

## 5. Bring up the stack

`docker compose up -d` is the only command required. The
`register` service runs first and the listener only starts after
it exits successfully:

```bash
docker compose pull
docker compose up -d
```

The `register` sidecar is idempotent:

* If the persistent `state` volume already contains matching
  `.runner`, `.credentials`, and `diagnostics.txt` (matching
  repository URL, runner name, and label list), the sidecar exits
  successfully without contacting GitHub and without requiring
  `TITAN_RUNNER_TOKEN`.
* If the state is missing or has drifted, the sidecar contacts
  GitHub using `RUNNER_TOKEN` (forwarded from
  `TITAN_RUNNER_TOKEN`) and persists the new credentials into
  the same volume. A transactional local backup ensures that an
  ordinary `config.sh` commit error restores the previously
  working credentials. The local rollback is best-effort; the
  GitHub-side runner record is not transactionally restored
  after `config.sh --replace` and must be cleaned up manually
  if a partial commit leaves a stale remote entry.
* A missing `RUNNER_TOKEN` together with a missing or drifted
  state fails the sidecar with actionable guidance so the
  listener cannot come up with broken credentials.

The listener uses the image's default entrypoint
(`tini` -> `start-runner`). The token is *never* mounted on the
long-running listener; the runner authenticates with the
GitHub-issued long-lived secret in `state/.credentials`.

## 6. Confirm the listener

```bash
./deploy.sh status
./deploy.sh logs --tail=200 --follow
```

`deploy.sh status` reports the runner image digest, the host
architecture and the platform it maps to, the listener container
and process state, the Docker socket reachability, the state
volume contents, the bridge network mode, the `shm_size`, the
`host.docker.internal` alias resolution, and the absence of both
`RUNNER_TOKEN` and `TITAN_RUNNER_TOKEN` from the listener
environment.

In the GitHub UI the runner appears under **Settings &rarr;
Actions &rarr; Runners** with the configured name, the
`titan-ci` custom label, and the auto-attached `self-hosted`,
`linux`, and `X64` / `ARM64` labels.

## 7. Blank the token and re-run Compose

After successful registration the token is still visible in the
stopped registration container's metadata because Compose
interpolates it from `.env`. Blank the `TITAN_RUNNER_TOKEN=`
line and re-run `docker compose up -d` so the metadata no longer
carries the token. The in-place edit MUST leave no token-bearing
backup on disk:

```bash
sed -i '/^TITAN_RUNNER_TOKEN=/d' .env
docker compose up -d
```

The registration sidecar runs again, sees an empty
`RUNNER_TOKEN` and a matching persisted identity, exits
successfully without contacting GitHub, and the listener keeps
authenticating with the long-lived secret. The `register`
service container is recreated without the token; the previous
metadata no longer carries it.

> **Note:** the old offline GitHub runner entry may need manual
> removal from **Settings &rarr; Actions &rarr; Runners** if the
> runner was previously registered through the old
> `deploy.sh register --rm docker run` workflow or with a
> different label list. The new flow registers the same runner
> identity in place, but a prior offline entry with the same
> name is not removed automatically.

## 8. Tear down (VM rotation)

When a VM is rotated, **only the `state` named volume and the
work VM bind mount must be preserved** &mdash; the runtime
tree, the `browser` volume, and the running container are
disposable.

```bash
# Old VM: stop the container. State volume and work bind mount remain on disk.
docker compose down

# New VM: transfer the titan-runner-state volume and the work
# VM bind mount (e.g. via rsync, btrfs send, or a Docker volume
# backup plugin), then start without re-registering.
docker compose pull
docker compose up -d
```

A token is only necessary when the `state` volume is empty or
the persisted identity has drifted. The VM-level network
isolation acceptance checks in [vm-deployment.md](vm-deployment.md)
MUST also pass on the new VM before the listener starts
processing jobs.
