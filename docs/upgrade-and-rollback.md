# Upgrade and rollback

The runner version is tracked by the `RUNNER_VERSION`,
`RUNNER_SHA256_ARM64`, and `RUNNER_SHA256_X64` triple in
`Dockerfile`. Pin all three together &mdash; the listener
registers with `--disableupdate` so even a compromised
in-container update attempt cannot swap the binary.

GitHub ends Actions Runner support 30 days after a new release.
Plan a tested image release within that window.

## Publishing a new version

1. Update `ARG RUNNER_VERSION`, `ARG RUNNER_SHA256_ARM64`, and
   `ARG RUNNER_SHA256_X64` in `Dockerfile`. Compute each digest
   with:

   ```bash
   # ARM64 upstream tarball.
   curl --silent --show-error --location \
     "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz" \
     | sha256sum
   # x64 upstream tarball.
   curl --silent --show-error --location \
     "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
     | sha256sum
   ```

   The Dockerfile pins the upstream `x64` digest under
   `RUNNER_SHA256_X64`; `fetch-runner.sh` selects the right
   digest based on BuildKit's automatic `TARGETARCH` build
   argument and refuses every other architecture before any
   download attempt.

2. Refresh `PLAYWRIGHT_VERSION` if a Chromium update is needed.
   The capability probe only checks that the version string
   resolves; the application lockfile pins the actual binary
   used in workflow runs.

3. Push to `main`. The hosted `publish` workflow builds the
   real `linux/amd64` and `linux/arm64` images on their native
   hosted runners, gates each candidate on its native
   capability probe, merges the two exact digests into a
   commit-specific multi-platform manifest, probes the merged
   manifest on both native architectures, then promotes the
   verified digest to `:latest`. The workflow reports the
   immutable multi-platform digest in its output; copy it
   into the deployment notes.

## Updating the CI host

```bash
TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<new-digest> \
    docker compose pull
TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<new-digest> \
    docker compose up -d
```

`docker compose pull` resolves the matching native platform
from the multi-platform digest so the same `TITAN_RUNNER_IMAGE`
works on either AMD64 or ARM64 VMs.

`docker compose up -d` is idempotent: the single runner container's
startup registration sees the matching persisted identity, exits
successfully without contacting GitHub, and the listener is then
recreated with `--force-recreate`. The listener rebuilds its runtime
tree from the new image, restoring the persisted credentials from
`titan-runner-state`. No new
registration token is needed because the GitHub-issued secret
in `.credentials` is image-independent and survives a container
recreation on the same state volume.

The replacement is a bridge-network container; the listener
attaches to `titan-runner-net` and reaches host services
through `host.docker.internal:host-gateway`. Workflow service
containers that publish random ports onto the Docker host are
resolved through the same alias.

## Rolling back

Rollbacks are an image switch, not a state mutation. Re-deploy
with the previous digest:

```bash
TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<previous-digest> \
    docker compose pull
TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<previous-digest> \
    docker compose up -d
```

The `:latest` tag is a convenience pointer; operators always
deploy by digest. GHCR keeps every previously published image,
so the rollback target is still pullable as a multi-platform
manifest; the same digest works on either architecture.

The `down` action is intentionally non-destructive &mdash; it
does not delete the state, runtime, work, or browser volumes.
A red build on `main` never requires re-registering the
runner.

## When to re-register

Re-registration produces a new GitHub-issued secret. The
operator needs a fresh registration token whenever:

* The host was rebuilt from scratch (the `state` volume is
  empty).
* The runner was offline for more than 30 days &mdash; GitHub
  invalidates stale credentials.
* The repository was transferred to a new owner.
* The host changed its IP or its metadata and a stale
  registration is causing GitHub to refuse reconnection.
* The runner identity (repository URL, name, or labels) needs
  to change &mdash; this includes the documented label-list
  rotation from `self-hosted,linux,ARM64,titan-ci` to
  `titan-ci` that GitHub auto-attaches on both architectures.

Set a fresh `TITAN_RUNNER_TOKEN` in `.env` and re-run
`docker compose up -d`. The startup registration phase detects the
identity drift, takes a transactional local backup of the
existing credentials, calls `config.sh --replace` to
re-register, and restores the backup if the new local
registration fails (an ordinary `config.sh` commit error). The
local rollback is best-effort; the GitHub-side runner record is
not transactionally restored after `config.sh --replace` and
must be cleaned up manually if a partial commit leaves a stale
remote entry. After a successful re-registration, blank the
`TITAN_RUNNER_TOKEN=` line in `.env` (using an in-place edit
that leaves no `*.bak` token-bearing backup on disk) and re-run
`docker compose up -d` so the token leaves the recreated runner
metadata; the startup entrypoint reloads the persisted credentials
on the next start.

> **Note:** if the previous registration is left as an offline
> entry in the GitHub UI under **Settings &rarr; Actions
> &rarr; Runners**, remove it manually. The new registration
> re-uses the same runner name and labels and cannot unregister
> the old entry through `--replace` if the underlying accounts
> differ.

## Emergency stop

To stop the listener without losing state:

```bash
docker compose down
```

The state, work, and browser volumes remain on disk; the
runtime tree is discarded. The container will not restart
itself; an operator must explicitly re-run
`docker compose up -d` to bring it back online.

## Emergency rebuild (suspected compromise)

The VM is disposable. After a suspected compromise, revoke the
runner and discard the VM, credentials, all runner-owned volumes,
and the old host workspace directory; never copy them into the
replacement. The new VM
registers normally with fresh state and a fresh token:

```bash
# Old VM: stop the stack; the credentials on disk are
# intentionally abandoned.
docker compose down

# New VM: bring up the stack with a fresh
# TITAN_RUNNER_TOKEN. The persistent state is NOT transferred.
docker compose pull
docker compose up -d
```
