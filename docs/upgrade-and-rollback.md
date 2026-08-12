# Upgrade and rollback

The runner version is tracked by the `RUNNER_VERSION` and
`RUNNER_SHA256` pair in `Dockerfile`. Pin both together &mdash;
the listener registers with `--disableupdate` so even a
compromised in-container update attempt cannot swap the binary.

GitHub ends Actions Runner support 30 days after a new release.
Plan a tested image release within that window.

## Publishing a new version

1. Update both `ARG RUNNER_VERSION` and `ARG RUNNER_SHA256` in
   `Dockerfile`. Compute the digest with:

   ```bash
   curl --silent --show-error --location \
     "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz" \
     | sha256sum
   ```

2. Refresh `PLAYWRIGHT_VERSION` if a Chromium update is needed.
   The capability probe only checks that the version string
   resolves; the application lockfile pins the actual binary used
   in workflow runs.

3. Push to `main`. The hosted `publish` workflow rebuilds the real
   `linux/arm64` image, runs the capability probe against the
   built image, and pushes
   `ghcr.io/pintjesb/titan-stocks-runner:latest`. The workflow
   reports the immutable digest in its output; copy it into the
   deployment notes.

## Updating the CI host

```bash
TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<new-digest> \
TITAN_RUNNER_REPO_URL=https://github.com/PintjesB/titan-stocks \
    ./deploy.sh up
```

`deploy.sh up` is idempotent: the Compose contract replaces the
running container with `--force-recreate` and the listener rebuilds
its runtime tree from the new image, restoring the persisted
credentials from `titan-runner-state`. No new registration token is
needed because the GitHub-issued secret in `.credentials` is
image-independent and survives a container recreation on the same
state volume.

## Rolling back

Rollbacks are an image switch, not a state mutation. Re-deploy
with the previous digest:

```bash
TITAN_RUNNER_IMAGE=ghcr.io/pintjesb/titan-stocks-runner@sha256:<previous-digest> \
TITAN_RUNNER_REPO_URL=https://github.com/PintjesB/titan-stocks \
    ./deploy.sh up
```

The `:latest` tag is a convenience pointer; operators always deploy
by digest. GHCR keeps every previously published image, so the
rollback target is still pullable.

The `down` action is intentionally non-destructive &mdash; it does
not delete the state, runtime, work, or browser volumes. A red
build on `main` never requires re-registering the runner.

## When to re-register

Re-registration produces a new GitHub-issued secret. The operator
needs a fresh registration token whenever:

* The host was rebuilt from scratch (the `state` volume is empty).
* The runner was offline for more than 30 days &mdash; GitHub
  invalidates stale credentials.
* The repository was transferred to a new owner.
* The host changed its IP or its metadata and a stale registration
  is causing GitHub to refuse reconnection.

`deploy.sh register` refuses to run while a listener is online;
run `./deploy.sh down` first. The `register` action calls the
upstream `config.sh --replace`, so a stale registration is removed
before a new one is created.

## Emergency stop

To stop the listener without losing state:

```bash
./deploy.sh down
```

The state, work, and browser volumes remain on disk; the runtime
tree is discarded. The container will not restart itself; an
operator must explicitly re-run `up` to bring it back online.
